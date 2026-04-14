import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/session_constants.dart';
import '../domain/location_tracking_repository.dart';
import '../domain/session_models.dart';
import '../domain/session_repository.dart';
import '../domain/tracking_mode_profiles.dart';
import '../domain/tracking_pipeline.dart';
import 'recording/background_sync_manager.dart';
import 'recording/elapsed_timer_manager.dart';
import 'recording/gps_signal_monitor.dart';
import 'recording/permission_manager.dart';
import 'recording/sample_watchdog.dart';
import 'recording_view_state.dart';

export 'recording_view_state.dart';

const Duration _locationStreamRestartQueueDelay = Duration(seconds: 2);
const Duration _streamCancelTimeout = Duration(seconds: 4);
const int _diagnosticHeartbeatEverySamples = 20;

class RecordingController extends StateNotifier<RecordingViewState> {
  RecordingController({
    required SessionRepository sessionRepository,
    required LocationTrackingRepository locationTrackingRepository,
  })  : _sessionRepository = sessionRepository,
        _locationTrackingRepository = locationTrackingRepository,
        _trackingPipeline = TrackingPipelineEngine(),
        super(RecordingViewState.initial()) {
    _permissionManager = PermissionManager(
      locationTrackingRepository: locationTrackingRepository,
      readState: () => state,
      writeState: (RecordingViewState s) => state = s,
    );
    _gpsSignalMonitor = GpsSignalMonitor(
      locationTrackingRepository: locationTrackingRepository,
      readState: () => state,
      writeState: (RecordingViewState s) => state = s,
    );
    _backgroundSyncManager = BackgroundSyncManager(
      sessionRepository: sessionRepository,
      readState: () => state,
      writeState: (RecordingViewState s) => state = s,
    );
    _elapsedTimerManager = ElapsedTimerManager(
      readState: () => state,
      writeState: (RecordingViewState s) => state = s,
    );
    _sampleWatchdog = SampleWatchdog(
      locationTrackingRepository: locationTrackingRepository,
      readState: () => state,
      writeState: (RecordingViewState s) => state = s,
    );
    _sampleWatchdog.onWatchdogCheck = _checkSampleWatchdog;
  }

  /// Call after construction to kick off background sync and pending sync pass.
  void initialize() {
    _backgroundSyncManager.startBackgroundSyncLoop();
    unawaited(_backgroundSyncManager.runPendingSyncPass(
      isMounted: () => mounted,
    ));
  }

  final SessionRepository _sessionRepository;
  final LocationTrackingRepository _locationTrackingRepository;
  final TrackingPipelineEngine _trackingPipeline;

  late final PermissionManager _permissionManager;
  late final GpsSignalMonitor _gpsSignalMonitor;
  late final BackgroundSyncManager _backgroundSyncManager;
  late final ElapsedTimerManager _elapsedTimerManager;
  late final SampleWatchdog _sampleWatchdog;

  StreamSubscription<void>? _locationSubscription;
  bool _locationStreamStopping = false;
  bool _locationStreamRestartQueued = false;
  TrackingMode _activeTrackingMode = TrackingMode.initializingFix;
  DateTime? _lastSampleReceivedAtUtc;
  DateTime? _lastPointPersistedAtUtc;
  DateTime? _currentStreamStartedAtUtc;
  DateTime? _lastWatchdogRestartAtUtc;
  int _sampleSequence = 0;
  int _recordingEpoch = 0;
  bool _phaseTransitionInFlight = false;

  /// Forces the next location callback to rebuild live progress from durable
  /// storage after a point write fails mid-recording.
  bool _needsPersistedProgressResync = false;

  // ---------------------------------------------------------------------------
  // Bootstrap & lifecycle
  // ---------------------------------------------------------------------------

  Future<void> bootstrap({String? preselectedResortId}) async {
    if (state.session?.isInProgress ?? false) {
      final permission =
          await _locationTrackingRepository.ensurePermissions();
      state = state.copyWith(
        permission: state.permission.copyWith(
          permissionState: permission,
          clearError: permission == LocationPermissionState.granted,
          errorMessage: PermissionManager.permissionMessage(permission),
        ),
        preselectedResortId: preselectedResortId,
      );
      await _gpsSignalMonitor.refreshGpsSignal(isMounted: () => mounted);
      return;
    }

    state = state.copyWith(
      phase: RecordScreenPhase.requestingPermissions,
      permission: state.permission.copyWith(clearError: true),
      preselectedResortId: preselectedResortId,
    );

    final permission =
        await _locationTrackingRepository.ensurePermissions();
    final recovery =
        await _sessionRepository.recoverInProgressSession();

    final phase = recovery != null
        ? (recovery.state == LocalSessionState.paused
            ? RecordScreenPhase.paused
            : RecordScreenPhase.ready)
        : RecordScreenPhase.ready;

    state = state.copyWith(
      phase: phase,
      permission: state.permission.copyWith(
        permissionState: permission,
        clearError: permission == LocationPermissionState.granted,
        errorMessage: PermissionManager.permissionMessage(permission),
      ),
      recoveryCandidate: recovery,
    );
    await _gpsSignalMonitor.refreshGpsSignal(isMounted: () => mounted);
  }

  Future<void> refreshPermissionState() async {
    await _permissionManager.refreshPermissionState(
      onPermissionLoss: _pauseRecordingForPermissionLoss,
      refreshGpsSignal: () =>
          _gpsSignalMonitor.refreshGpsSignal(isMounted: () => mounted),
    );
  }

  Future<void> refreshGpsSignal() async {
    await _gpsSignalMonitor.refreshGpsSignal(isMounted: () => mounted);
  }

  Future<void> onAppResumed() async {
    await refreshPermissionState();
    await _backgroundSyncManager.runPendingSyncPass(
      isMounted: () => mounted,
    );
  }

  Future<void> onAuthenticatedSessionAvailable() async {
    await _backgroundSyncManager.runPendingSyncPass(
      showDebugStatus: true,
      isMounted: () => mounted,
    );
  }

  Future<void> requestRequiredLocationPermissions() async {
    await _permissionManager.requestRequiredLocationPermissions(
      phaseTransitionInFlight: _phaseTransitionInFlight,
      onPermissionLoss: _pauseRecordingForPermissionLoss,
      refreshGpsSignal: () =>
          _gpsSignalMonitor.refreshGpsSignal(isMounted: () => mounted),
      setPhaseTransitionInFlight: (bool value) =>
          _phaseTransitionInFlight = value,
    );
  }

  Future<void> openLocationPermissionSettings() async {
    await _permissionManager.openLocationPermissionSettings();
  }

  Future<void> openLocationServiceSettings() async {
    await _permissionManager.openLocationServiceSettings();
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------------

  Future<void> resumeRecoveredSession() async {
    if (_phaseTransitionInFlight || state.recoveryCandidate == null) {
      return;
    }

    _phaseTransitionInFlight = true;
    final recovery = state.recoveryCandidate;
    if (recovery == null) {
      _phaseTransitionInFlight = false;
      return;
    }

    try {
      final permission =
          await _locationTrackingRepository.checkPermissions();
      var effectiveRecovery = recovery;
      if (recovery.state == LocalSessionState.recording &&
          permission != LocationPermissionState.granted) {
        effectiveRecovery = await _sessionRepository.pauseLocalSession(
          recovery.localId,
        );
      }

      if (effectiveRecovery.state == LocalSessionState.recording) {
        _beginNewRecordingEpoch();
      } else {
        _invalidateRecordingEpoch();
      }

      state = state.copyWith(
        session: effectiveRecovery,
        clearRecovery: true,
        phase: effectiveRecovery.state == LocalSessionState.paused
            ? RecordScreenPhase.paused
            : RecordScreenPhase.recording,
        permission: state.permission.copyWith(
          permissionState: permission,
          clearError: permission == LocationPermissionState.granted,
          errorMessage: PermissionManager.permissionMessage(permission),
        ),
        streamRestartCount: 0,
        tracking: state.tracking.copyWith(
          clearLastSampleAtUtc: true,
          clearLastPersistedPointAtUtc: true,
        ),
      );

      final detail =
          await _sessionRepository.getSessionDetail(effectiveRecovery.localId);

      final stats = await _sessionRepository.computeSessionStats(
        effectiveRecovery.localId,
      );
      _trackingPipeline.seedFromPersistedPoints(
        points: detail.points,
        stats: stats,
      );
      _activeTrackingMode = TrackingMode.initializingFix;
      _elapsedTimerManager.elapsedBeforeActive =
          Duration(seconds: stats.durationS);
      _elapsedTimerManager.activeSegmentStartedAtUtc = null;

      if (effectiveRecovery.state == LocalSessionState.recording) {
        _elapsedTimerManager.startActiveElapsedClock();
      } else {
        _elapsedTimerManager.stopElapsedTicker();
      }

      state = state.copyWith(
        tracking: state.tracking.copyWith(
          liveStats: stats,
          route: detail.points
              .where((LocalSessionPoint point) => point.acceptedForAnalytics)
              .map(
                (LocalSessionPoint point) => LatLng(
                  point.filteredLatitude ?? point.latitude,
                  point.filteredLongitude ?? point.longitude,
                ),
              )
              .toList(growable: false),
          elapsed: _elapsedTimerManager.currentElapsedDuration(),
          currentAltitudeM: _currentAltitudeFromPersistedPoints(detail.points),
          maxSpeedMps: stats.maxSpeedMps,
        ),
      );

      _sampleSequence = 0;
      _lastSampleReceivedAtUtc = null;
      _lastPointPersistedAtUtc = null;
      _lastWatchdogRestartAtUtc = null;
      _sampleWatchdog.consecutiveWatchdogStaleEvents = 0;
      await _recordTrackingDiagnostic(
        eventType: 'session_recovery_applied',
        details: <String, dynamic>{
          'phase': state.phase.name,
          'permission': permission.name,
          'accepted_points': detail.acceptedPoints.length,
        },
        localSessionId: effectiveRecovery.localId,
      );

      if (state.phase == RecordScreenPhase.recording &&
          permission == LocationPermissionState.granted) {
        final readinessError =
            await _locationTrackingRepository.checkRecordingReadiness();
        if (readinessError != null) {
          _invalidateRecordingEpoch();
          _elapsedTimerManager.pauseElapsedClock();
          final paused =
              await _sessionRepository.pauseLocalSession(
            effectiveRecovery.localId,
          );
          state = state.copyWith(
            session: paused,
            phase: RecordScreenPhase.paused,
            permission: state.permission.copyWith(
              errorMessage: readinessError,
            ),
          );
          await _recordTrackingDiagnostic(
            eventType: 'recording_readiness_failed',
            message: readinessError,
            localSessionId: effectiveRecovery.localId,
          );
          return;
        }
        await _startLocationStream();
      }
    } finally {
      _phaseTransitionInFlight = false;
    }
  }

  Future<void> discardRecovery() async {
    state = state.copyWith(clearRecovery: true);
  }

  Future<void> startRecording() async {
    if (_phaseTransitionInFlight ||
        (state.phase != RecordScreenPhase.preRecord &&
            state.phase != RecordScreenPhase.ready)) {
      return;
    }

    _phaseTransitionInFlight = true;
    try {
      final permission =
          await _locationTrackingRepository.ensurePermissions();
      if (permission != LocationPermissionState.granted) {
        state = state.copyWith(
          permission: state.permission.copyWith(
            permissionState: permission,
            errorMessage: PermissionManager.permissionMessage(permission),
          ),
        );
        return;
      }

      final readinessError =
          await _locationTrackingRepository.checkRecordingReadiness();
      if (readinessError != null) {
        state = state.copyWith(
          permission: state.permission.copyWith(errorMessage: readinessError),
        );
        await _recordTrackingDiagnostic(
          eventType: 'recording_readiness_failed',
          message: readinessError,
        );
        return;
      }

      final currentSession = state.session;
      final hasInProgressSession = currentSession?.isInProgress ?? false;

      final session = hasInProgressSession
          ? currentSession!
          : await _sessionRepository.startLocalSession(
              resortId: state.preselectedResortId,
            );

      _beginNewRecordingEpoch();
      if (!hasInProgressSession) {
        _trackingPipeline.reset();
        _elapsedTimerManager.elapsedBeforeActive = Duration.zero;
      }
      _activeTrackingMode = TrackingMode.initializingFix;
      _sampleSequence = 0;
      _lastSampleReceivedAtUtc = null;
      _lastPointPersistedAtUtc = null;
      _lastWatchdogRestartAtUtc = null;
      _sampleWatchdog.consecutiveWatchdogStaleEvents = 0;
      _elapsedTimerManager.startActiveElapsedClock();

      state = state.copyWith(
        session: session,
        phase: RecordScreenPhase.recording,
        tracking: state.tracking.copyWith(
          route: hasInProgressSession ? state.tracking.route : <LatLng>[],
          liveStats: hasInProgressSession
              ? state.tracking.liveStats
              : SessionStats.zero,
          currentSpeedMps:
              hasInProgressSession ? state.tracking.currentSpeedMps : 0,
          currentAltitudeM: hasInProgressSession
              ? state.tracking.currentAltitudeM
              : null,
          clearCurrentAltitudeM: !hasInProgressSession,
          maxSpeedMps:
              hasInProgressSession ? state.tracking.maxSpeedMps : 0,
          elapsed: _elapsedTimerManager.currentElapsedDuration(),
          clearLastSampleAtUtc: true,
          clearLastPersistedPointAtUtc: true,
        ),
        permission: state.permission.copyWith(
          permissionState: permission,
          clearError: true,
        ),
        sync: state.sync.copyWith(clearSyncMessage: true),
        streamRestartCount: 0,
      );

      await _recordTrackingDiagnostic(
        eventType: 'session_recording_started',
        details: <String, dynamic>{
          'reused_existing_session': hasInProgressSession,
        },
        localSessionId: session.localId,
      );
      await _startLocationStream();
    } finally {
      _phaseTransitionInFlight = false;
    }
  }

  Future<void> pause() async {
    if (_phaseTransitionInFlight ||
        state.phase != RecordScreenPhase.recording) {
      return;
    }

    _phaseTransitionInFlight = true;
    final session = state.session;
    if (session == null) {
      _phaseTransitionInFlight = false;
      return;
    }

    try {
      _invalidateRecordingEpoch();
      _elapsedTimerManager.pauseElapsedClock();
      await _stopLocationStream();

      final updated =
          await _sessionRepository.pauseLocalSession(session.localId);

      state = state.copyWith(
        session: updated,
        phase: RecordScreenPhase.paused,
      );
      await _recordTrackingDiagnostic(
        eventType: 'session_paused',
        localSessionId: updated.localId,
      );
    } finally {
      _phaseTransitionInFlight = false;
    }
  }

  Future<void> resume() async {
    if (_phaseTransitionInFlight || state.phase != RecordScreenPhase.paused) {
      return;
    }

    _phaseTransitionInFlight = true;
    final session = state.session;
    if (session == null) {
      _phaseTransitionInFlight = false;
      return;
    }

    try {
      final permission =
          await _locationTrackingRepository.ensurePermissions();
      if (permission != LocationPermissionState.granted) {
        state = state.copyWith(
          permission: state.permission.copyWith(
            permissionState: permission,
            errorMessage: PermissionManager.permissionMessage(permission),
          ),
        );
        return;
      }

      final readinessError =
          await _locationTrackingRepository.checkRecordingReadiness();
      if (readinessError != null) {
        state = state.copyWith(
          permission: state.permission.copyWith(errorMessage: readinessError),
        );
        await _recordTrackingDiagnostic(
          eventType: 'recording_readiness_failed',
          message: readinessError,
          localSessionId: session.localId,
        );
        return;
      }

      _beginNewRecordingEpoch();
      _elapsedTimerManager.startActiveElapsedClock();
      _lastSampleReceivedAtUtc = null;
      _lastPointPersistedAtUtc = null;
      _lastWatchdogRestartAtUtc = null;
      _sampleWatchdog.consecutiveWatchdogStaleEvents = 0;
      final updated =
          await _sessionRepository.resumeLocalSession(session.localId);
      state = state.copyWith(
        session: updated,
        phase: RecordScreenPhase.recording,
        permission: state.permission.copyWith(
          permissionState: permission,
          clearError: true,
        ),
        tracking: state.tracking.copyWith(
          clearLastSampleAtUtc: true,
          clearLastPersistedPointAtUtc: true,
        ),
      );

      await _recordTrackingDiagnostic(
        eventType: 'session_resumed',
        localSessionId: updated.localId,
      );
      await _startLocationStream();
    } finally {
      _phaseTransitionInFlight = false;
    }
  }

  Future<void> finish() async {
    if (_phaseTransitionInFlight ||
        (state.phase != RecordScreenPhase.recording &&
            state.phase != RecordScreenPhase.paused)) {
      return;
    }

    _phaseTransitionInFlight = true;
    final session = state.session;
    if (session == null) {
      _phaseTransitionInFlight = false;
      return;
    }

    state = state.copyWith(
      phase: RecordScreenPhase.finishing,
      permission: state.permission.copyWith(clearError: true),
    );
    await _recordTrackingDiagnostic(
      eventType: 'session_finish_requested',
      details: <String, dynamic>{
        'sample_sequence': _sampleSequence,
      },
      localSessionId: session.localId,
    );

    try {
      _invalidateRecordingEpoch();
      _elapsedTimerManager.pauseElapsedClock();
      await _stopLocationStream();

      final elapsedDurationS =
          _elapsedTimerManager.currentElapsedDuration().inSeconds;

      final completed =
          await _sessionRepository.finishLocalSession(
        session.localId,
        activeDurationS: elapsedDurationS,
      );

      _resetRecordingSurface();
      state = state.copyWith(
        phase: RecordScreenPhase.ready,
        clearSession: true,
        tracking: const TrackingViewState.initial(),
        sync: state.sync.copyWith(
          clearSyncMessage: true,
          historyRevision: state.sync.historyRevision + 1,
        ),
      );

      await _recordTrackingDiagnostic(
        eventType: 'session_finished_local',
        details: <String, dynamic>{
          'active_duration_s': elapsedDurationS,
          'point_count': completed.pointCount,
        },
        localSessionId: completed.localId,
      );
      unawaited(
        _gpsSignalMonitor.refreshGpsSignal(isMounted: () => mounted),
      );
      unawaited(_backgroundSyncManager.runPendingSyncPass(
        showDebugStatus: true,
        isMounted: () => mounted,
      ));
    } catch (error, stackTrace) {
      await _recordTrackingDiagnostic(
        eventType: 'session_finish_failed',
        message: error.toString(),
        details: <String, dynamic>{
          'stack': _firstStackLine(stackTrace),
        },
        localSessionId: session.localId,
      );
      state = state.copyWith(
        phase: RecordScreenPhase.paused,
        permission: state.permission.copyWith(
          errorMessage: 'Could not finish session. Please try again.',
        ),
      );
    } finally {
      _phaseTransitionInFlight = false;
    }
  }

  Future<void> retryFailedSync() async {
    final session = state.session;
    if (session == null) {
      return;
    }

    final synced =
        await _sessionRepository.retryFailedSync(session.localId);
    state = state.copyWith(
      session: synced,
      sync: state.sync.copyWith(
        lastSyncMessage: synced.state == LocalSessionState.synced
            ? 'Synced successfully.'
            : synced.lastSyncError,
        historyRevision: state.sync.historyRevision + 1,
      ),
    );
  }

  Future<void> retryPendingSyncs() async {
    await _backgroundSyncManager.runPendingSyncPass(
      showDebugStatus: true,
      isMounted: () => mounted,
    );
  }

  // ---------------------------------------------------------------------------
  // Location stream management
  // ---------------------------------------------------------------------------

  Future<void> _startLocationStream() async {
    final session = state.session;
    final recordingEpoch = _recordingEpoch;
    final sessionId = session?.localId;
    if (session != null) {
      await _recordTrackingDiagnostic(
        eventType: 'stream_start_requested',
        details: <String, dynamic>{
          'tracking_mode': _activeTrackingMode.wireValue,
          'restart_count': state.streamRestartCount,
        },
        localSessionId: session.localId,
      );
    }

    try {
      await _stopLocationStream();
      if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
        return;
      }
      _locationStreamStopping = false;
      _locationStreamRestartQueued = false;
      await _locationTrackingRepository.setTrackingMode(_activeTrackingMode);
      if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
        return;
      }
      _locationSubscription = _locationTrackingRepository
          .watchPosition()
          .asyncMap(
            (LocationSample sample) => _onLocation(
              sample,
              recordingEpoch: recordingEpoch,
              sessionId: sessionId,
            ),
          )
          .listen(
            (_) {},
            onError: (Object error, StackTrace stackTrace) =>
                _onLocationStreamError(
              error,
              stackTrace,
              recordingEpoch: recordingEpoch,
              sessionId: sessionId,
            ),
            onDone: () => _onLocationStreamDone(
              recordingEpoch: recordingEpoch,
              sessionId: sessionId,
            ),
            cancelOnError: false,
          );
      _currentStreamStartedAtUtc = DateTime.now().toUtc();
      _sampleWatchdog.consecutiveWatchdogStaleEvents = 0;
      _sampleWatchdog.startSampleWatchdog(
        activeTrackingMode: _activeTrackingMode,
        lastSampleReceivedAtUtc: _lastSampleReceivedAtUtc,
        currentStreamStartedAtUtc: _currentStreamStartedAtUtc,
      );

      if (session != null) {
        await _recordTrackingDiagnostic(
          eventType: 'stream_started',
          details: <String, dynamic>{
            'tracking_mode': _activeTrackingMode.wireValue,
          },
          localSessionId: session.localId,
        );
      }
    } catch (error, stackTrace) {
      if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
        return;
      }
      await _recordTrackingDiagnostic(
        eventType: 'stream_start_failed',
        message: error.toString(),
        details: <String, dynamic>{
          'tracking_mode': _activeTrackingMode.wireValue,
          'stack': _firstStackLine(stackTrace),
        },
      );
      state = state.copyWith(
        permission: state.permission.copyWith(
          errorMessage: 'Could not start location tracking. Reconnecting...',
        ),
      );
      unawaited(
        _queueLocationStreamRestart(
          reason: 'stream_start_failed',
          recordingEpoch: recordingEpoch,
          sessionId: sessionId,
        ),
      );
    }
  }

  Future<void> _stopLocationStream() async {
    _sampleWatchdog.stopSampleWatchdog();
    _currentStreamStartedAtUtc = null;
    final subscription = _locationSubscription;
    if (subscription == null) {
      return;
    }

    _locationStreamStopping = true;
    try {
      await subscription.cancel().timeout(_streamCancelTimeout);
      await _recordTrackingDiagnostic(eventType: 'stream_stopped');
    } on TimeoutException {
      await _recordTrackingDiagnostic(
        eventType: 'stream_stop_timeout',
        details: <String, dynamic>{
          'timeout_seconds': _streamCancelTimeout.inSeconds,
        },
      );
    } catch (error, stackTrace) {
      await _recordTrackingDiagnostic(
        eventType: 'stream_stop_failed',
        message: error.toString(),
        details: <String, dynamic>{
          'stack': _firstStackLine(stackTrace),
        },
      );
    } finally {
      _locationSubscription = null;
      _locationStreamStopping = false;
    }
  }

  void _onLocationStreamError(
    Object error,
    StackTrace stackTrace, {
    required int recordingEpoch,
    required int? sessionId,
  }) {
    if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
      return;
    }
    unawaited(
      _recordTrackingDiagnostic(
        eventType: 'stream_error',
        message: error.toString(),
        details: <String, dynamic>{
          'stack': _firstStackLine(stackTrace),
        },
      ),
    );
    state = state.copyWith(
      permission: state.permission.copyWith(
        errorMessage: 'Location stream interrupted. Reconnecting...',
      ),
    );
    unawaited(
      _queueLocationStreamRestart(
        reason: 'stream_error',
        recordingEpoch: recordingEpoch,
        sessionId: sessionId,
      ),
    );
  }

  void _onLocationStreamDone({
    required int recordingEpoch,
    required int? sessionId,
  }) {
    if (_locationStreamStopping) {
      _locationStreamStopping = false;
      return;
    }
    if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
      return;
    }
    unawaited(_recordTrackingDiagnostic(eventType: 'stream_done'));
    unawaited(
      _queueLocationStreamRestart(
        reason: 'stream_done',
        recordingEpoch: recordingEpoch,
        sessionId: sessionId,
      ),
    );
  }

  Future<void> _queueLocationStreamRestart({
    required String reason,
    required int recordingEpoch,
    required int? sessionId,
  }) async {
    if (_locationStreamRestartQueued ||
        !_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
      return;
    }

    _locationStreamRestartQueued = true;
    try {
      await Future<void>.delayed(_locationStreamRestartQueueDelay);

      if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
        return;
      }

      final lastSampleAtUtc = _lastSampleReceivedAtUtc;
      final staleThreshold =
          TrackingModeProfiles.forMode(_activeTrackingMode)
              .sampleWatchdogThreshold;

      if (lastSampleAtUtc != null &&
          DateTime.now().toUtc().difference(lastSampleAtUtc) <
              staleThreshold) {
        return;
      }

      final nextRestartCount = state.streamRestartCount + 1;
      state = state.copyWith(streamRestartCount: nextRestartCount);
      try {
        await _recordTrackingDiagnostic(
          eventType: 'stream_restart_attempt',
          details: <String, dynamic>{
            'reason': reason,
            'restart_count': nextRestartCount,
          },
        );
      } catch (_) {
        // Swallow diagnostic failure so recovery can continue.
      }
      await _startLocationStream();
    } finally {
      _locationStreamRestartQueued = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Sample processing callback
  // ---------------------------------------------------------------------------

  Future<void> _onLocation(
    LocationSample sample, {
    required int recordingEpoch,
    required int? sessionId,
  }) async {
    if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
      return;
    }

    final session = state.session;
    if (session == null || session.localId != sessionId) {
      return;
    }

    if (_needsPersistedProgressResync) {
      final restored = await _restorePersistedProgress(
        session: session,
        recordingEpoch: recordingEpoch,
        sessionId: sessionId,
      );
      if (!restored) {
        return;
      }
    }

    _sampleSequence += 1;
    _lastSampleReceivedAtUtc = DateTime.now().toUtc();
    _sampleWatchdog.consecutiveWatchdogStaleEvents = 0;
    _sampleWatchdog.rescheduleSampleWatchdog(
      activeTrackingMode: _activeTrackingMode,
      lastSampleReceivedAtUtc: _lastSampleReceivedAtUtc,
      currentStreamStartedAtUtc: _currentStreamStartedAtUtc,
    );
    state = state.copyWith(
      tracking: state.tracking.copyWith(
        lastSampleAtUtc: _lastSampleReceivedAtUtc,
      ),
    );
    if (_sampleSequence == 1 ||
        _sampleSequence % _diagnosticHeartbeatEverySamples == 0) {
      unawaited(
        _recordTrackingDiagnostic(
          eventType: 'sample_heartbeat',
          details: <String, dynamic>{
            'sample_sequence': _sampleSequence,
            'sample_time': sample.timestamp.toUtc().toIso8601String(),
            'tracking_mode': _activeTrackingMode.wireValue,
          },
          localSessionId: session.localId,
        ),
      );
    }

    TrackingProcessResult result;
    try {
      result = _trackingPipeline.processSample(
        sample: sample,
        sessionStartedAtUtc: session.startedAt,
        activeDurationS:
            _elapsedTimerManager.currentElapsedDuration().inSeconds,
      );
    } catch (error, stackTrace) {
      await _recordTrackingDiagnostic(
        eventType: 'pipeline_process_failed',
        message: error.toString(),
        details: <String, dynamic>{
          'sample_sequence': _sampleSequence,
          'stack': _firstStackLine(stackTrace),
        },
        localSessionId: session.localId,
      );
      rethrow;
    }

    var persisted = false;
    try {
      if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
        return;
      }
      await _sessionRepository.appendLocationPoint(
          session.localId, result.point);
      persisted = true;
    } catch (error, stackTrace) {
      _needsPersistedProgressResync = true;
      await _recordTrackingDiagnostic(
        eventType: 'point_persist_failed',
        message: error.toString(),
        details: <String, dynamic>{
          'sample_sequence': _sampleSequence,
          'point_offset_ms': result.point.tOffsetMs,
          'stack': _firstStackLine(stackTrace),
        },
        localSessionId: session.localId,
      );
    }

    if (persisted) {
      _needsPersistedProgressResync = false;
      _lastPointPersistedAtUtc = DateTime.now().toUtc();
    }
    if (persisted &&
        (_sampleSequence == 1 ||
            _sampleSequence % _diagnosticHeartbeatEverySamples == 0)) {
      unawaited(
        _recordTrackingDiagnostic(
          eventType: 'point_persist_heartbeat',
          details: <String, dynamic>{
            'sample_sequence': _sampleSequence,
            'point_offset_ms': result.point.tOffsetMs,
            'quality_reason': result.point.qualityReason,
            'motion_state': result.point.motionState,
          },
          localSessionId: session.localId,
        ),
      );
    }

    if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
      return;
    }
    if (!persisted) {
      state = state.copyWith(
        tracking: state.tracking.copyWith(
          elapsed: _elapsedTimerManager.currentElapsedDuration(),
          currentAltitudeM: _currentAltitudeFromTrackedPoint(result.point),
          lowAccuracy: result.lowAccuracy,
          gpsSignal: _gpsSignalMonitor.gpsSignalFromSample(
            sample,
            permissionState: state.permission.permissionState,
          ),
          lastPersistedPointAtUtc: _lastPointPersistedAtUtc,
        ),
      );
      return;
    }
    final updatedRoute = _buildUpdatedRouteFromResult(
      currentRoute: state.tracking.route,
      result: result,
    );

    if (_activeTrackingMode != result.trackingMode) {
      final previousMode = _activeTrackingMode;
      _activeTrackingMode = result.trackingMode;
      try {
        await _locationTrackingRepository.setTrackingMode(_activeTrackingMode);
        _sampleWatchdog.rescheduleSampleWatchdog(
          activeTrackingMode: _activeTrackingMode,
          lastSampleReceivedAtUtc: _lastSampleReceivedAtUtc,
          currentStreamStartedAtUtc: _currentStreamStartedAtUtc,
        );
        if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
          return;
        }
        unawaited(
          _recordTrackingDiagnostic(
            eventType: 'tracking_mode_changed',
            details: <String, dynamic>{
              'from_mode': previousMode.wireValue,
              'to_mode': _activeTrackingMode.wireValue,
              'sample_sequence': _sampleSequence,
            },
            localSessionId: session.localId,
          ),
        );
      } catch (error, stackTrace) {
        await _recordTrackingDiagnostic(
          eventType: 'tracking_mode_apply_failed',
          message: error.toString(),
          details: <String, dynamic>{
            'from_mode': previousMode.wireValue,
            'to_mode': _activeTrackingMode.wireValue,
            'stack': _firstStackLine(stackTrace),
          },
          localSessionId: session.localId,
        );
      }
    }

    state = state.copyWith(
      tracking: state.tracking.copyWith(
        route: updatedRoute,
        liveStats: result.stats,
        currentSpeedMps: result.liveSpeedMps,
        currentAltitudeM: _currentAltitudeFromTrackedPoint(result.point),
        maxSpeedMps: result.stats.maxSpeedMps,
        elapsed: _elapsedTimerManager.currentElapsedDuration(),
        lowAccuracy: result.lowAccuracy,
        gpsSignal: _gpsSignalMonitor.gpsSignalFromSample(
          sample,
          permissionState: state.permission.permissionState,
        ),
        lastPersistedPointAtUtc: _lastPointPersistedAtUtc,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Epoch management
  // ---------------------------------------------------------------------------

  bool _isActiveRecordingEpoch(
    int recordingEpoch, {
    required int? sessionId,
  }) {
    if (!mounted || recordingEpoch != _recordingEpoch) {
      return false;
    }
    final session = state.session;
    return state.phase == RecordScreenPhase.recording &&
        session != null &&
        session.localId == sessionId;
  }

  int _beginNewRecordingEpoch() {
    _locationStreamRestartQueued = false;
    _needsPersistedProgressResync = false;
    _recordingEpoch += 1;
    return _recordingEpoch;
  }

  void _invalidateRecordingEpoch() {
    _locationStreamRestartQueued = false;
    _needsPersistedProgressResync = false;
    _recordingEpoch += 1;
  }

  // ---------------------------------------------------------------------------
  // Permission-loss handling
  // ---------------------------------------------------------------------------

  Future<void> _pauseRecordingForPermissionLoss(
    LocationPermissionState permission,
  ) async {
    final session = state.session;
    if (state.phase != RecordScreenPhase.recording || session == null) {
      state = state.copyWith(
        permission: state.permission.copyWith(
          permissionState: permission,
          clearError: permission == LocationPermissionState.granted,
          errorMessage: PermissionManager.permissionMessage(permission),
        ),
      );
      return;
    }

    _invalidateRecordingEpoch();
    _elapsedTimerManager.pauseElapsedClock();
    await _stopLocationStream();
    final paused =
        await _sessionRepository.pauseLocalSession(session.localId);
    state = state.copyWith(
      session: paused,
      phase: RecordScreenPhase.paused,
      permission: state.permission.copyWith(
        permissionState: permission,
        errorMessage: PermissionManager.permissionMessage(permission),
      ),
      tracking: state.tracking.copyWith(
        clearLastSampleAtUtc: true,
        clearLastPersistedPointAtUtc: true,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sample watchdog check (coordinator-level, delegates to SampleWatchdog)
  // ---------------------------------------------------------------------------

  Future<void> _checkSampleWatchdog() async {
    final action = await _sampleWatchdog.checkSampleWatchdog(
      activeTrackingMode: _activeTrackingMode,
      lastSampleReceivedAtUtc: _lastSampleReceivedAtUtc,
      currentStreamStartedAtUtc: _currentStreamStartedAtUtc,
      lastWatchdogRestartAtUtc: _lastWatchdogRestartAtUtc,
      recordingEpoch: _recordingEpoch,
      isActiveRecordingEpoch: _isActiveRecordingEpoch,
    );

    final session = state.session;

    switch (action.kind) {
      case WatchdogActionKind.none:
        return;

      case WatchdogActionKind.reschedule:
        _sampleWatchdog.rescheduleSampleWatchdog(
          activeTrackingMode: _activeTrackingMode,
          lastSampleReceivedAtUtc: _lastSampleReceivedAtUtc,
          currentStreamStartedAtUtc: _currentStreamStartedAtUtc,
        );
        return;

      case WatchdogActionKind.switchedToRecoveryMode:
        final data = action.data!;
        final staleFor = data['stale_for'] as Duration;
        final staleThreshold = data['stale_threshold'] as Duration;
        final hasReceivedSample = data['has_received_sample'] as bool;
        final recoveryThreshold =
            data['recovery_threshold'] as Duration;

        _activeTrackingMode = TrackingMode.lowConfidenceRecovery;

        await _recordTrackingDiagnostic(
          eventType: hasReceivedSample
              ? 'sample_watchdog_recovery_mode'
              : 'sample_watchdog_no_initial_sample',
          details: <String, dynamic>{
            'watchdog_phase':
                hasReceivedSample ? 'mid_session' : 'initial_fix',
            'stale_for_seconds': staleFor.inSeconds,
            'stale_threshold_seconds': staleThreshold.inSeconds,
            'from_mode': _activeTrackingMode.wireValue,
            'to_mode': TrackingMode.lowConfidenceRecovery.wireValue,
            'restart_count': state.streamRestartCount,
          },
        );

        _sampleWatchdog.scheduleAfter(recoveryThreshold);
        return;

      case WatchdogActionKind.waitingForInitialSample:
        final data = action.data!;
        final staleFor = data['stale_for'] as Duration;
        final staleThreshold = data['stale_threshold'] as Duration;
        final activeMode =
            data['active_tracking_mode'] as TrackingMode;

        await _recordTrackingDiagnostic(
          eventType: 'sample_watchdog_waiting_initial_sample',
          details: <String, dynamic>{
            'stale_for_seconds': staleFor.inSeconds,
            'stale_threshold_seconds': staleThreshold.inSeconds,
            'initial_sample_grace_seconds': 12,
            'tracking_mode': activeMode.wireValue,
            'restart_count': state.streamRestartCount,
          },
        );
        _sampleWatchdog.scheduleAfter(staleThreshold);
        return;

      case WatchdogActionKind.recoveryWait:
        final data = action.data!;
        final staleFor = data['stale_for'] as Duration;
        final staleThreshold = data['stale_threshold'] as Duration;
        final activeMode =
            data['active_tracking_mode'] as TrackingMode;

        await _recordTrackingDiagnostic(
          eventType: 'sample_watchdog_recovery_wait',
          details: <String, dynamic>{
            'stale_for_seconds': staleFor.inSeconds,
            'stale_threshold_seconds': staleThreshold.inSeconds,
            'consecutive_stale_events':
                _sampleWatchdog.consecutiveWatchdogStaleEvents,
            'required_stale_events_for_restart': 3,
            'tracking_mode': activeMode.wireValue,
          },
        );
        _sampleWatchdog.scheduleAfter(staleThreshold);
        return;

      case WatchdogActionKind.restartCooldown:
        final data = action.data!;
        final staleFor = data['stale_for'] as Duration;
        final staleThreshold = data['stale_threshold'] as Duration;
        final cooldownRemainingSeconds =
            data['cooldown_remaining_seconds'] as int;
        final activeMode =
            data['active_tracking_mode'] as TrackingMode;

        await _recordTrackingDiagnostic(
          eventType: 'sample_watchdog_restart_cooldown',
          details: <String, dynamic>{
            'stale_for_seconds': staleFor.inSeconds,
            'stale_threshold_seconds': staleThreshold.inSeconds,
            'cooldown_remaining_seconds': cooldownRemainingSeconds,
            'tracking_mode': activeMode.wireValue,
            'consecutive_stale_events':
                _sampleWatchdog.consecutiveWatchdogStaleEvents,
          },
          localSessionId: session?.localId,
        );
        _sampleWatchdog.scheduleAfter(staleThreshold);
        return;

      case WatchdogActionKind.restart:
        final data = action.data!;
        final staleFor = data['stale_for'] as Duration;
        final staleThreshold = data['stale_threshold'] as Duration;
        final hasReceivedSample = data['has_received_sample'] as bool;
        final activeMode =
            data['active_tracking_mode'] as TrackingMode;

        _lastWatchdogRestartAtUtc = DateTime.now().toUtc();

        await _recordTrackingDiagnostic(
          eventType: hasReceivedSample
              ? 'sample_watchdog_restart'
              : 'sample_watchdog_no_initial_sample',
          details: <String, dynamic>{
            'watchdog_phase':
                hasReceivedSample ? 'mid_session' : 'initial_fix',
            'stale_for_seconds': staleFor.inSeconds,
            'stale_threshold_seconds': staleThreshold.inSeconds,
            'tracking_mode': activeMode.wireValue,
            'restart_count': state.streamRestartCount,
            'consecutive_stale_events':
                _sampleWatchdog.consecutiveWatchdogStaleEvents,
          },
          localSessionId: session?.localId,
        );

        await _queueLocationStreamRestart(
          reason: 'sample_watchdog_stale',
          recordingEpoch: _recordingEpoch,
          sessionId: session?.localId,
        );
        return;
    }
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  Future<void> _recordTrackingDiagnostic({
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
    int? localSessionId,
  }) async {
    final resolvedSessionId = localSessionId ?? state.session?.localId;
    if (resolvedSessionId == null || resolvedSessionId <= 0) {
      return;
    }
    try {
      await _sessionRepository.recordTrackingDiagnostic(
        resolvedSessionId,
        eventType: eventType,
        message: message,
        details: details,
      );
    } catch (_) {}
  }

  String _firstStackLine(StackTrace stackTrace) {
    final text = stackTrace.toString();
    final index = text.indexOf('\n');
    if (index == -1) {
      return text;
    }
    return text.substring(0, index);
  }

  Future<bool> _restorePersistedProgress({
    required LocalRideSession session,
    required int recordingEpoch,
    required int? sessionId,
  }) async {
    try {
      final detail =
          await _sessionRepository.getSessionDetail(session.localId);
      final stats =
          await _sessionRepository.computeSessionStats(session.localId);
      if (!_isActiveRecordingEpoch(recordingEpoch, sessionId: sessionId)) {
        return false;
      }
      _trackingPipeline.seedFromPersistedPoints(
        points: detail.points,
        stats: stats,
      );
      state = state.copyWith(
        tracking: state.tracking.copyWith(
          liveStats: stats,
          route: _buildPersistedRoute(detail.points),
          currentSpeedMps: _currentSpeedFromPersistedPoints(detail.points),
          currentAltitudeM: _currentAltitudeFromPersistedPoints(detail.points),
          maxSpeedMps: stats.maxSpeedMps,
        ),
      );
      _needsPersistedProgressResync = false;
      return true;
    } catch (error, stackTrace) {
      await _recordTrackingDiagnostic(
        eventType: 'persisted_progress_resync_failed',
        message: error.toString(),
        details: <String, dynamic>{
          'stack': _firstStackLine(stackTrace),
        },
        localSessionId: session.localId,
      );
      return false;
    }
  }

  List<LatLng> _buildPersistedRoute(List<LocalSessionPoint> points) {
    final route = points
        .where((LocalSessionPoint point) => point.acceptedForAnalytics)
        .map(
          (LocalSessionPoint point) => LatLng(
            point.filteredLatitude ?? point.latitude,
            point.filteredLongitude ?? point.longitude,
          ),
        )
        .toList(growable: false);
    if (route.length <= SessionConstants.maxLiveRoutePoints) {
      return route;
    }
    return route.sublist(
      route.length - SessionConstants.maxLiveRoutePoints,
    );
  }

  double _currentSpeedFromPersistedPoints(List<LocalSessionPoint> points) {
    for (var index = points.length - 1; index >= 0; index -= 1) {
      final point = points[index];
      if (!point.acceptedForAnalytics) {
        continue;
      }
      return point.fusedSpeedMps ??
          point.derivedSpeedMps ??
          point.speedMps ??
          0;
    }
    return 0;
  }

  double? _currentAltitudeFromPersistedPoints(List<LocalSessionPoint> points) {
    for (var index = points.length - 1; index >= 0; index -= 1) {
      final point = points[index];
      final altitude = point.filteredAltitudeM ?? point.altitudeM;
      if (altitude != null) {
        return altitude;
      }
    }
    return null;
  }

  double? _currentAltitudeFromTrackedPoint(NewSessionPoint point) {
    return point.filteredAltitudeM ?? point.altitudeM;
  }

  List<LatLng> _buildUpdatedRouteFromResult({
    required List<LatLng> currentRoute,
    required TrackingProcessResult result,
  }) {
    if (!result.acceptedForReplay ||
        result.routeLatitude == null ||
        result.routeLongitude == null) {
      return currentRoute;
    }

    final updatedRoute = List<LatLng>.from(currentRoute)
      ..add(LatLng(result.routeLatitude!, result.routeLongitude!));
    final overflow =
        updatedRoute.length - SessionConstants.maxLiveRoutePoints;
    if (overflow > 0) {
      updatedRoute.removeRange(0, overflow);
    }
    return updatedRoute;
  }

  void _resetRecordingSurface() {
    _invalidateRecordingEpoch();
    _elapsedTimerManager.reset();
    _activeTrackingMode = TrackingMode.initializingFix;
    _sampleSequence = 0;
    _lastSampleReceivedAtUtc = null;
    _lastPointPersistedAtUtc = null;
    _currentStreamStartedAtUtc = null;
    _lastWatchdogRestartAtUtc = null;
    _sampleWatchdog.consecutiveWatchdogStaleEvents = 0;
    _sampleWatchdog.stopSampleWatchdog();
  }

  @override
  void dispose() {
    _permissionManager.dispose();
    _gpsSignalMonitor.dispose();
    _backgroundSyncManager.dispose();
    _elapsedTimerManager.dispose();
    _sampleWatchdog.dispose();
    _locationSubscription?.cancel();
    super.dispose();
  }
}
