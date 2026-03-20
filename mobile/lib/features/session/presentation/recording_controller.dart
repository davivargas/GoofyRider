import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/session_constants.dart';
import '../domain/location_tracking_repository.dart';
import '../domain/session_models.dart';
import '../domain/session_repository.dart';
import '../domain/tracking_pipeline.dart';

enum RecordScreenPhase {
  preRecord,
  requestingPermissions,
  ready,
  recording,
  paused,
  finishing,
  syncPending,
}

const String _allTimePermissionMessage =
    'Location is set to "Allow only while using the app". '
    'Choose "Allow all the time" so tracking keeps working when the phone is locked.';
const String _locationPermissionMessage =
    'Location permission is required before recording.';
const String _locationDeniedForeverMessage =
    'Location permission is permanently denied. Open app settings to enable it.';
const String _locationServiceDisabledMessage =
    'Location services are turned off. Turn on GPS to record your session.';
const String _openSettingsFailedMessage =
    'Could not open app settings. Please open settings manually.';
const String _openLocationSettingsFailedMessage =
    'Could not open location settings. Please open settings manually.';
const Duration _sampleWatchdogCheckInterval = Duration(seconds: 10);
const Duration _sampleWatchdogStaleThreshold = Duration(seconds: 25);
const Duration _sampleWatchdogRestartCooldown = Duration(seconds: 20);
const Duration _backgroundSyncRetryInterval = Duration(minutes: 2);
const Duration _gpsSignalStaleThreshold = Duration(seconds: 15);
const Duration _streamCancelTimeout = Duration(seconds: 4);
const int _diagnosticHeartbeatEverySamples = 20;

class GpsSignalState {
  const GpsSignalState({
    required this.bars,
    required this.description,
  });

  const GpsSignalState.initial()
      : bars = 0,
        description = 'Searching';

  final int bars;
  final String description;
}

class RecordingViewState {
  const RecordingViewState({
    required this.phase,
    required this.permissionState,
    required this.liveStats,
    required this.route,
    required this.currentSpeedMps,
    required this.maxSpeedMps,
    required this.elapsed,
    required this.lowAccuracy,
    required this.historyRevision,
    required this.streamRestartCount,
    required this.gpsSignal,
    this.session,
    this.errorMessage,
    this.preselectedResortId,
    this.recoveryCandidate,
    this.lastSyncMessage,
    this.lastSampleAtUtc,
    this.lastPersistedPointAtUtc,
  });

  factory RecordingViewState.initial() => const RecordingViewState(
        phase: RecordScreenPhase.preRecord,
        permissionState: LocationPermissionState.denied,
        liveStats: SessionStats.zero,
        route: <LatLng>[],
        currentSpeedMps: 0,
        maxSpeedMps: 0,
        elapsed: Duration.zero,
        lowAccuracy: false,
        historyRevision: 0,
        streamRestartCount: 0,
        gpsSignal: GpsSignalState.initial(),
      );

  final RecordScreenPhase phase;
  final LocationPermissionState permissionState;
  final SessionStats liveStats;
  final List<LatLng> route;
  final double currentSpeedMps;
  final double maxSpeedMps;
  final Duration elapsed;
  final bool lowAccuracy;
  final int historyRevision;
  final int streamRestartCount;
  final GpsSignalState gpsSignal;
  final LocalRideSession? session;
  final String? errorMessage;
  final String? preselectedResortId;
  final LocalRideSession? recoveryCandidate;
  final String? lastSyncMessage;
  final DateTime? lastSampleAtUtc;
  final DateTime? lastPersistedPointAtUtc;

  bool get hasLocationPermission =>
      permissionState == LocationPermissionState.granted ||
      permissionState == LocationPermissionState.grantedForegroundOnly;

  bool get canStart =>
      hasConfirmedBackgroundTracking &&
      phase != RecordScreenPhase.requestingPermissions &&
      phase != RecordScreenPhase.recording &&
      phase != RecordScreenPhase.paused &&
      phase != RecordScreenPhase.finishing;

  bool get hasRecovery => recoveryCandidate != null;

  bool get hasConfirmedBackgroundTracking =>
      permissionState == LocationPermissionState.granted;

  bool get needsAlwaysOnPermission =>
      permissionState == LocationPermissionState.grantedForegroundOnly;

  RecordingViewState copyWith({
    RecordScreenPhase? phase,
    LocationPermissionState? permissionState,
    SessionStats? liveStats,
    List<LatLng>? route,
    double? currentSpeedMps,
    double? maxSpeedMps,
    Duration? elapsed,
    bool? lowAccuracy,
    int? historyRevision,
    int? streamRestartCount,
    GpsSignalState? gpsSignal,
    LocalRideSession? session,
    bool clearSession = false,
    String? errorMessage,
    bool clearError = false,
    String? preselectedResortId,
    LocalRideSession? recoveryCandidate,
    bool clearRecovery = false,
    String? lastSyncMessage,
    bool clearSyncMessage = false,
    DateTime? lastSampleAtUtc,
    bool clearLastSampleAtUtc = false,
    DateTime? lastPersistedPointAtUtc,
    bool clearLastPersistedPointAtUtc = false,
  }) {
    return RecordingViewState(
      phase: phase ?? this.phase,
      permissionState: permissionState ?? this.permissionState,
      liveStats: liveStats ?? this.liveStats,
      route: route ?? this.route,
      currentSpeedMps: currentSpeedMps ?? this.currentSpeedMps,
      maxSpeedMps: maxSpeedMps ?? this.maxSpeedMps,
      elapsed: elapsed ?? this.elapsed,
      lowAccuracy: lowAccuracy ?? this.lowAccuracy,
      historyRevision: historyRevision ?? this.historyRevision,
      streamRestartCount: streamRestartCount ?? this.streamRestartCount,
      gpsSignal: gpsSignal ?? this.gpsSignal,
      session: clearSession ? null : (session ?? this.session),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      preselectedResortId: preselectedResortId ?? this.preselectedResortId,
      recoveryCandidate:
          clearRecovery ? null : (recoveryCandidate ?? this.recoveryCandidate),
      lastSyncMessage:
          clearSyncMessage ? null : (lastSyncMessage ?? this.lastSyncMessage),
      lastSampleAtUtc: clearLastSampleAtUtc
          ? null
          : (lastSampleAtUtc ?? this.lastSampleAtUtc),
      lastPersistedPointAtUtc: clearLastPersistedPointAtUtc
          ? null
          : (lastPersistedPointAtUtc ?? this.lastPersistedPointAtUtc),
    );
  }
}

class RecordingController extends StateNotifier<RecordingViewState> {
  RecordingController({
    required SessionRepository sessionRepository,
    required LocationTrackingRepository locationTrackingRepository,
  })  : _sessionRepository = sessionRepository,
        _locationTrackingRepository = locationTrackingRepository,
        _trackingPipeline = TrackingPipelineEngine(),
        super(RecordingViewState.initial()) {
    _startBackgroundSyncLoop();
    unawaited(_runPendingSyncPass());
  }

  final SessionRepository _sessionRepository;
  final LocationTrackingRepository _locationTrackingRepository;
  final TrackingPipelineEngine _trackingPipeline;

  StreamSubscription<void>? _locationSubscription;
  Timer? _elapsedTicker;
  Timer? _sampleWatchdogTicker;
  Timer? _backgroundSyncTicker;
  Duration _elapsedBeforeActive = Duration.zero;
  DateTime? _activeSegmentStartedAtUtc;
  bool _locationStreamStopping = false;
  bool _locationStreamRestartQueued = false;
  TrackingMode _activeTrackingMode = TrackingMode.initializingFix;
  DateTime? _lastSampleReceivedAtUtc;
  DateTime? _lastPointPersistedAtUtc;
  DateTime? _currentStreamStartedAtUtc;
  DateTime? _lastWatchdogRestartAtUtc;
  bool _backgroundSyncInFlight = false;
  bool _backgroundSyncQueued = false;
  Completer<void>? _backgroundSyncCycleCompleter;
  bool _gpsSignalRefreshInFlight = false;
  int _sampleSequence = 0;

  Future<void> bootstrap({String? preselectedResortId}) async {
    if (state.session?.isInProgress ?? false) {
      final LocationPermissionState permission =
          await _locationTrackingRepository.ensurePermissions();
      state = state.copyWith(
        permissionState: permission,
        preselectedResortId: preselectedResortId,
        clearError: permission == LocationPermissionState.granted,
        errorMessage: _permissionMessage(permission),
      );
      await refreshGpsSignal();
      return;
    }

    state = state.copyWith(
      phase: RecordScreenPhase.requestingPermissions,
      preselectedResortId: preselectedResortId,
      clearError: true,
    );

    final LocationPermissionState permission =
        await _locationTrackingRepository.ensurePermissions();
    final LocalRideSession? recovery =
        await _sessionRepository.recoverInProgressSession();

    final RecordScreenPhase phase = recovery != null
        ? (recovery.state == LocalSessionState.paused
            ? RecordScreenPhase.paused
            : RecordScreenPhase.ready)
        : RecordScreenPhase.ready;

    state = state.copyWith(
      phase: phase,
      permissionState: permission,
      recoveryCandidate: recovery,
      clearError: permission == LocationPermissionState.granted,
      errorMessage: _permissionMessage(permission),
    );
    await refreshGpsSignal();
  }

  Future<void> refreshPermissionState() async {
    final LocationPermissionState permission =
        await _locationTrackingRepository.checkPermissions();
    state = state.copyWith(
      permissionState: permission,
      clearError: permission == LocationPermissionState.granted,
      errorMessage: _permissionMessage(permission),
    );
    await refreshGpsSignal();
  }

  Future<void> refreshGpsSignal() async {
    if (_gpsSignalRefreshInFlight) {
      return;
    }

    _gpsSignalRefreshInFlight = true;
    try {
      final LocationPermissionState permission =
          await _locationTrackingRepository.checkPermissions();
      final GpsSignalState signal;
      if (permission == LocationPermissionState.serviceDisabled) {
        signal = const GpsSignalState(
          bars: 0,
          description: 'GPS off',
        );
      } else if (permission == LocationPermissionState.denied ||
          permission == LocationPermissionState.deniedForever) {
        signal = const GpsSignalState(
          bars: 0,
          description: 'No permission',
        );
      } else {
        final LocationSample? sample =
            await _locationTrackingRepository.getCurrentLocationSample();
        signal = _gpsSignalFromSample(
          sample,
          permissionState: permission,
        );
      }

      if (!mounted) {
        return;
      }
      state = state.copyWith(
        permissionState: permission,
        gpsSignal: signal,
      );
    } finally {
      _gpsSignalRefreshInFlight = false;
    }
  }

  Future<void> onAppResumed() async {
    await refreshPermissionState();
    await _runPendingSyncPass();
  }

  Future<void> onAuthenticatedSessionAvailable() async {
    await _runPendingSyncPass(showDebugStatus: true);
  }

  Future<void> requestRequiredLocationPermissions() async {
    final RecordScreenPhase previousPhase = state.phase;
    state = state.copyWith(
      phase: RecordScreenPhase.requestingPermissions,
      clearError: true,
    );

    final LocationPermissionState permission =
        await _locationTrackingRepository.ensurePermissions();

    final RecordScreenPhase nextPhase;
    if (previousPhase == RecordScreenPhase.preRecord ||
        previousPhase == RecordScreenPhase.requestingPermissions) {
      nextPhase = RecordScreenPhase.ready;
    } else if (previousPhase == RecordScreenPhase.recording &&
        permission != LocationPermissionState.granted) {
      nextPhase = RecordScreenPhase.paused;
    } else {
      nextPhase = previousPhase;
    }

    state = state.copyWith(
      phase: nextPhase,
      permissionState: permission,
      clearError: permission == LocationPermissionState.granted,
      errorMessage: _permissionMessage(permission),
    );
    await refreshGpsSignal();
  }

  Future<void> openLocationPermissionSettings() async {
    final bool opened = await _locationTrackingRepository.openAppSettings();
    if (!opened) {
      state = state.copyWith(errorMessage: _openSettingsFailedMessage);
    }
  }

  Future<void> openLocationServiceSettings() async {
    final bool opened =
        await _locationTrackingRepository.openLocationSettings();
    if (!opened) {
      state = state.copyWith(errorMessage: _openLocationSettingsFailedMessage);
    }
  }

  Future<void> resumeRecoveredSession() async {
    final LocalRideSession? recovery = state.recoveryCandidate;
    if (recovery == null) {
      return;
    }

    final LocationPermissionState permission =
        await _locationTrackingRepository.checkPermissions();
    LocalRideSession effectiveRecovery = recovery;
    if (recovery.state == LocalSessionState.recording &&
        permission != LocationPermissionState.granted) {
      effectiveRecovery = await _sessionRepository.pauseLocalSession(
        recovery.localId,
      );
    }

    state = state.copyWith(
      session: effectiveRecovery,
      clearRecovery: true,
      phase: effectiveRecovery.state == LocalSessionState.paused
          ? RecordScreenPhase.paused
          : RecordScreenPhase.recording,
      permissionState: permission,
      clearError: permission == LocationPermissionState.granted,
      errorMessage: _permissionMessage(permission),
      streamRestartCount: 0,
      clearLastSampleAtUtc: true,
      clearLastPersistedPointAtUtc: true,
    );

    final SessionDetail detail =
        await _sessionRepository.getSessionDetail(effectiveRecovery.localId);

    final SessionStats stats =
        await _sessionRepository.computeSessionStats(effectiveRecovery.localId);
    _trackingPipeline.seedFromPersistedPoints(
      points: detail.points,
      stats: stats,
    );
    _activeTrackingMode = TrackingMode.initializingFix;
    _elapsedBeforeActive = Duration(seconds: stats.durationS);
    _activeSegmentStartedAtUtc = null;

    if (effectiveRecovery.state == LocalSessionState.recording) {
      _startActiveElapsedClock();
    } else {
      _stopElapsedTicker();
    }

    state = state.copyWith(
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
      elapsed: _currentElapsedDuration(),
      maxSpeedMps: stats.maxSpeedMps,
    );

    _sampleSequence = 0;
    _lastSampleReceivedAtUtc = null;
    _lastPointPersistedAtUtc = null;
    _lastWatchdogRestartAtUtc = null;
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
      await _startLocationStream();
    }
  }

  Future<void> discardRecovery() async {
    state = state.copyWith(clearRecovery: true);
  }

  Future<void> startRecording() async {
    final LocationPermissionState permission =
        await _locationTrackingRepository.ensurePermissions();
    if (permission != LocationPermissionState.granted) {
      state = state.copyWith(
        permissionState: permission,
        clearError: false,
        errorMessage: _permissionMessage(permission),
      );
      return;
    }

    final LocalRideSession? currentSession = state.session;
    final bool hasInProgressSession = currentSession?.isInProgress ?? false;

    final LocalRideSession session = hasInProgressSession
        ? currentSession!
        : await _sessionRepository.startLocalSession(
            resortId: state.preselectedResortId,
          );

    if (!hasInProgressSession) {
      _trackingPipeline.reset();
      _elapsedBeforeActive = Duration.zero;
    }
    _activeTrackingMode = TrackingMode.initializingFix;
    _sampleSequence = 0;
    _lastSampleReceivedAtUtc = null;
    _lastPointPersistedAtUtc = null;
    _lastWatchdogRestartAtUtc = null;
    _startActiveElapsedClock();

    state = state.copyWith(
      session: session,
      phase: RecordScreenPhase.recording,
      route: hasInProgressSession ? state.route : <LatLng>[],
      liveStats: hasInProgressSession ? state.liveStats : SessionStats.zero,
      currentSpeedMps: hasInProgressSession ? state.currentSpeedMps : 0,
      maxSpeedMps: hasInProgressSession ? state.maxSpeedMps : 0,
      elapsed: _currentElapsedDuration(),
      permissionState: permission,
      clearError: true,
      clearSyncMessage: true,
      streamRestartCount: 0,
      clearLastSampleAtUtc: true,
      clearLastPersistedPointAtUtc: true,
    );

    await _recordTrackingDiagnostic(
      eventType: 'session_recording_started',
      details: <String, dynamic>{
        'reused_existing_session': hasInProgressSession,
      },
      localSessionId: session.localId,
    );
    await _startLocationStream();
  }

  Future<void> pause() async {
    final LocalRideSession? session = state.session;
    if (session == null) {
      return;
    }

    _pauseElapsedClock();
    await _stopLocationStream();

    final LocalRideSession updated =
        await _sessionRepository.pauseLocalSession(session.localId);

    state = state.copyWith(
      session: updated,
      phase: RecordScreenPhase.paused,
    );
    await _recordTrackingDiagnostic(
      eventType: 'session_paused',
      localSessionId: updated.localId,
    );
  }

  Future<void> resume() async {
    final LocalRideSession? session = state.session;
    if (session == null) {
      return;
    }

    final LocationPermissionState permission =
        await _locationTrackingRepository.ensurePermissions();
    if (permission != LocationPermissionState.granted) {
      state = state.copyWith(
        permissionState: permission,
        clearError: false,
        errorMessage: _permissionMessage(permission),
      );
      return;
    }

    _startActiveElapsedClock();
    _lastSampleReceivedAtUtc = null;
    _lastPointPersistedAtUtc = null;
    _lastWatchdogRestartAtUtc = null;
    final LocalRideSession updated =
        await _sessionRepository.resumeLocalSession(session.localId);
    state = state.copyWith(
      session: updated,
      phase: RecordScreenPhase.recording,
      permissionState: permission,
      clearError: true,
      clearLastSampleAtUtc: true,
      clearLastPersistedPointAtUtc: true,
    );

    await _recordTrackingDiagnostic(
      eventType: 'session_resumed',
      localSessionId: updated.localId,
    );
    await _startLocationStream();
  }

  Future<void> finish() async {
    final LocalRideSession? session = state.session;
    if (session == null) {
      return;
    }

    state =
        state.copyWith(phase: RecordScreenPhase.finishing, clearError: true);
    await _recordTrackingDiagnostic(
      eventType: 'session_finish_requested',
      details: <String, dynamic>{
        'sample_sequence': _sampleSequence,
      },
      localSessionId: session.localId,
    );

    try {
      _pauseElapsedClock();
      await _stopLocationStream();

      final int elapsedDurationS = _currentElapsedDuration().inSeconds;

      final LocalRideSession completed =
          await _sessionRepository.finishLocalSession(
        session.localId,
        activeDurationS: elapsedDurationS,
      );

      _resetRecordingSurface();
      state = state.copyWith(
        phase: RecordScreenPhase.ready,
        clearSession: true,
        route: const <LatLng>[],
        liveStats: SessionStats.zero,
        currentSpeedMps: 0,
        maxSpeedMps: 0,
        elapsed: Duration.zero,
        lowAccuracy: false,
        historyRevision: state.historyRevision + 1,
        clearSyncMessage: true,
        clearLastSampleAtUtc: true,
        clearLastPersistedPointAtUtc: true,
      );

      await _recordTrackingDiagnostic(
        eventType: 'session_finished_local',
        details: <String, dynamic>{
          'active_duration_s': elapsedDurationS,
          'point_count': completed.pointCount,
        },
        localSessionId: completed.localId,
      );
      unawaited(refreshGpsSignal());
      unawaited(_runPendingSyncPass(showDebugStatus: true));
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
        errorMessage: 'Could not finish session. Please try again.',
      );
    }
  }

  Future<void> retryFailedSync() async {
    final LocalRideSession? session = state.session;
    if (session == null) {
      return;
    }

    final LocalRideSession synced =
        await _sessionRepository.retryFailedSync(session.localId);
    state = state.copyWith(
      session: synced,
      lastSyncMessage: synced.state == LocalSessionState.synced
          ? 'Synced successfully.'
          : synced.lastSyncError,
      historyRevision: state.historyRevision + 1,
    );
  }

  Future<void> retryPendingSyncs() async {
    await _runPendingSyncPass(showDebugStatus: true);
  }

  Future<void> _startLocationStream() async {
    final LocalRideSession? session = state.session;
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
      _locationStreamStopping = false;
      _locationStreamRestartQueued = false;
      await _locationTrackingRepository.setTrackingMode(_activeTrackingMode);
      _locationSubscription = _locationTrackingRepository
          .watchPosition()
          .asyncMap(_onLocation)
          .listen(
            (_) {},
            onError: _onLocationStreamError,
            onDone: _onLocationStreamDone,
            cancelOnError: false,
          );
      _currentStreamStartedAtUtc = DateTime.now().toUtc();
      _startSampleWatchdog();

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
      await _recordTrackingDiagnostic(
        eventType: 'stream_start_failed',
        message: error.toString(),
        details: <String, dynamic>{
          'tracking_mode': _activeTrackingMode.wireValue,
          'stack': _firstStackLine(stackTrace),
        },
      );
      state = state.copyWith(
        errorMessage: 'Could not start location tracking. Reconnecting...',
      );
      unawaited(
        _restartLocationStreamIfNeeded(reason: 'stream_start_failed'),
      );
    }
  }

  Future<void> _stopLocationStream() async {
    _stopSampleWatchdog();
    _currentStreamStartedAtUtc = null;
    final StreamSubscription<void>? subscription = _locationSubscription;
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

  void _onLocationStreamError(Object error, StackTrace stackTrace) {
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
      errorMessage: 'Location stream interrupted. Reconnecting...',
    );
    unawaited(_restartLocationStreamIfNeeded(reason: 'stream_error'));
  }

  void _onLocationStreamDone() {
    if (_locationStreamStopping) {
      _locationStreamStopping = false;
      return;
    }
    unawaited(_recordTrackingDiagnostic(eventType: 'stream_done'));
    unawaited(_restartLocationStreamIfNeeded(reason: 'stream_done'));
  }

  Future<void> _restartLocationStreamIfNeeded({
    required String reason,
  }) async {
    if (_locationStreamRestartQueued ||
        state.phase != RecordScreenPhase.recording) {
      return;
    }

    _locationStreamRestartQueued = true;
    await Future<void>.delayed(const Duration(seconds: 1));
    _locationStreamRestartQueued = false;

    if (state.phase != RecordScreenPhase.recording) {
      return;
    }
    final int nextRestartCount = state.streamRestartCount + 1;
    state = state.copyWith(streamRestartCount: nextRestartCount);
    await _recordTrackingDiagnostic(
      eventType: 'stream_restart_attempt',
      details: <String, dynamic>{
        'reason': reason,
        'restart_count': nextRestartCount,
      },
    );
    await _startLocationStream();
  }

  Future<void> _onLocation(LocationSample sample) async {
    final LocalRideSession? session = state.session;
    if (session == null || state.phase != RecordScreenPhase.recording) {
      return;
    }

    _sampleSequence += 1;
    _lastSampleReceivedAtUtc = DateTime.now().toUtc();
    state = state.copyWith(lastSampleAtUtc: _lastSampleReceivedAtUtc);
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
        activeDurationS: _currentElapsedDuration().inSeconds,
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

    try {
      await _sessionRepository.appendLocationPoint(
          session.localId, result.point);
    } catch (error, stackTrace) {
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
      rethrow;
    }

    _lastPointPersistedAtUtc = DateTime.now().toUtc();
    if (_sampleSequence == 1 ||
        _sampleSequence % _diagnosticHeartbeatEverySamples == 0) {
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

    final List<LatLng> updatedRoute = _buildUpdatedRouteFromResult(
      currentRoute: state.route,
      result: result,
    );

    if (_activeTrackingMode != result.trackingMode) {
      final TrackingMode previousMode = _activeTrackingMode;
      _activeTrackingMode = result.trackingMode;
      try {
        await _locationTrackingRepository.setTrackingMode(_activeTrackingMode);
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
        rethrow;
      }
    }

    state = state.copyWith(
      route: updatedRoute,
      liveStats: result.stats,
      currentSpeedMps: result.liveSpeedMps,
      maxSpeedMps: result.stats.maxSpeedMps,
      elapsed: _currentElapsedDuration(),
      lowAccuracy: result.lowAccuracy,
      gpsSignal: _gpsSignalFromSample(
        sample,
        permissionState: state.permissionState,
      ),
      lastPersistedPointAtUtc: _lastPointPersistedAtUtc,
    );
  }

  void _startSampleWatchdog() {
    _sampleWatchdogTicker?.cancel();
    _sampleWatchdogTicker = Timer.periodic(_sampleWatchdogCheckInterval, (_) {
      unawaited(_checkSampleWatchdog());
    });
  }

  void _stopSampleWatchdog() {
    _sampleWatchdogTicker?.cancel();
    _sampleWatchdogTicker = null;
  }

  Future<void> _checkSampleWatchdog() async {
    if (state.phase != RecordScreenPhase.recording) {
      return;
    }
    final DateTime? referenceTime =
        _lastSampleReceivedAtUtc ?? _currentStreamStartedAtUtc;
    if (referenceTime == null) {
      return;
    }

    final DateTime now = DateTime.now().toUtc();
    final Duration staleFor = now.difference(referenceTime);
    if (staleFor < _sampleWatchdogStaleThreshold) {
      return;
    }

    final DateTime? lastRestart = _lastWatchdogRestartAtUtc;
    if (lastRestart != null &&
        now.difference(lastRestart) < _sampleWatchdogRestartCooldown) {
      return;
    }
    _lastWatchdogRestartAtUtc = now;

    state = state.copyWith(
      errorMessage:
          'No location updates for ${staleFor.inSeconds}s. Reconnecting...',
      gpsSignal: const GpsSignalState(
        bars: 0,
        description: 'Searching',
      ),
    );
    await _recordTrackingDiagnostic(
      eventType: _lastSampleReceivedAtUtc == null
          ? 'sample_watchdog_no_initial_sample'
          : 'sample_watchdog_stale',
      details: <String, dynamic>{
        'stale_for_seconds': staleFor.inSeconds,
        'restart_count': state.streamRestartCount,
      },
    );
    await _restartLocationStreamIfNeeded(reason: 'sample_watchdog_stale');
  }

  Future<void> _recordTrackingDiagnostic({
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
    int? localSessionId,
  }) async {
    final int? resolvedSessionId = localSessionId ?? state.session?.localId;
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
    final String text = stackTrace.toString();
    final int index = text.indexOf('\n');
    if (index == -1) {
      return text;
    }
    return text.substring(0, index);
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

    final List<LatLng> updatedRoute = List<LatLng>.from(currentRoute)
      ..add(LatLng(result.routeLatitude!, result.routeLongitude!));
    final int overflow =
        updatedRoute.length - SessionConstants.maxLiveRoutePoints;
    if (overflow > 0) {
      updatedRoute.removeRange(0, overflow);
    }
    return updatedRoute;
  }

  void _resetRecordingSurface() {
    _elapsedBeforeActive = Duration.zero;
    _activeSegmentStartedAtUtc = null;
    _activeTrackingMode = TrackingMode.initializingFix;
    _sampleSequence = 0;
    _lastSampleReceivedAtUtc = null;
    _lastPointPersistedAtUtc = null;
    _currentStreamStartedAtUtc = null;
    _lastWatchdogRestartAtUtc = null;
    _stopElapsedTicker();
    _stopSampleWatchdog();
  }

  void _startActiveElapsedClock() {
    _activeSegmentStartedAtUtc = DateTime.now().toUtc();
    _startElapsedTicker();
    _pushElapsedTick();
  }

  void _pauseElapsedClock() {
    final DateTime? activeStartedAt = _activeSegmentStartedAtUtc;
    if (activeStartedAt != null) {
      final Duration delta = DateTime.now().toUtc().difference(activeStartedAt);
      if (!delta.isNegative) {
        _elapsedBeforeActive += delta;
      }
    }
    _activeSegmentStartedAtUtc = null;
    _stopElapsedTicker();
    _pushElapsedTick();
  }

  void _startElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      _pushElapsedTick();
    });
  }

  void _stopElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
  }

  void _pushElapsedTick() {
    final Duration elapsed = _currentElapsedDuration();
    if (elapsed.inSeconds == state.elapsed.inSeconds) {
      return;
    }
    state = state.copyWith(elapsed: elapsed);
  }

  Duration _currentElapsedDuration() {
    final DateTime? activeStartedAt = _activeSegmentStartedAtUtc;
    if (activeStartedAt == null) {
      return _elapsedBeforeActive;
    }

    final Duration activeDelta =
        DateTime.now().toUtc().difference(activeStartedAt);
    if (activeDelta.isNegative) {
      return _elapsedBeforeActive;
    }
    return _elapsedBeforeActive + activeDelta;
  }

  void _startBackgroundSyncLoop() {
    _backgroundSyncTicker?.cancel();
    _backgroundSyncTicker = Timer.periodic(_backgroundSyncRetryInterval, (_) {
      unawaited(_runPendingSyncPass());
    });
  }

  Future<void> _runPendingSyncPass({
    bool showDebugStatus = false,
  }) async {
    if (_backgroundSyncInFlight) {
      _backgroundSyncQueued = true;
      final Completer<void>? activeCycle = _backgroundSyncCycleCompleter;
      if (activeCycle != null) {
        await activeCycle.future;
      }
      if (_backgroundSyncQueued && mounted) {
        _backgroundSyncQueued = false;
        return _runPendingSyncPass(showDebugStatus: showDebugStatus);
      }
      return;
    }

    _backgroundSyncInFlight = true;
    _backgroundSyncCycleCompleter = Completer<void>();
    try {
      final List<LocalRideSession> pending =
          await _sessionRepository.listPendingSyncSessions();

      int syncedCount = 0;
      int failedCount = 0;
      for (final LocalRideSession session in pending) {
        final LocalRideSession result =
            await _sessionRepository.syncSession(session.localId);
        if (result.state == LocalSessionState.synced) {
          syncedCount += 1;
        } else if (result.state == LocalSessionState.syncFailed) {
          failedCount += 1;
        }
      }

      await _sessionRepository.refreshRemoteSessionHistoryCache();

      if (!mounted) {
        return;
      }
      state = state.copyWith(
        historyRevision: state.historyRevision + 1,
        lastSyncMessage: showDebugStatus
            ? _syncDebugMessage(
                totalCount: pending.length,
                syncedCount: syncedCount,
                failedCount: failedCount,
              )
            : state.lastSyncMessage,
      );
    } catch (_) {
      if (showDebugStatus && mounted) {
        state = state.copyWith(
          lastSyncMessage: 'Sync pass failed.',
        );
      }
    } finally {
      _backgroundSyncInFlight = false;
      final Completer<void>? activeCycle = _backgroundSyncCycleCompleter;
      _backgroundSyncCycleCompleter = null;
      if (activeCycle != null && !activeCycle.isCompleted) {
        activeCycle.complete();
      }
    }
  }

  String _syncDebugMessage({
    required int totalCount,
    required int syncedCount,
    required int failedCount,
  }) {
    if (totalCount == 0) {
      return 'No pending sync work.';
    }
    return 'Sync pass: $syncedCount/$totalCount synced'
        '${failedCount > 0 ? ', $failedCount failed' : ''}.';
  }

  GpsSignalState _gpsSignalFromSample(
    LocationSample? sample, {
    required LocationPermissionState permissionState,
  }) {
    if (permissionState == LocationPermissionState.serviceDisabled) {
      return const GpsSignalState(
        bars: 0,
        description: 'GPS off',
      );
    }
    if (permissionState == LocationPermissionState.denied ||
        permissionState == LocationPermissionState.deniedForever) {
      return const GpsSignalState(
        bars: 0,
        description: 'No permission',
      );
    }
    if (sample == null) {
      return const GpsSignalState(
        bars: 0,
        description: 'Searching',
      );
    }

    final Duration age =
        DateTime.now().toUtc().difference(sample.timestamp.toUtc());
    if (age > _gpsSignalStaleThreshold) {
      return const GpsSignalState(
        bars: 1,
        description: 'Stale fix',
      );
    }

    final double? accuracyM = sample.accuracyM;
    if (accuracyM == null) {
      return const GpsSignalState(
        bars: 1,
        description: 'Weak fix',
      );
    }
    if (accuracyM <= 8) {
      return const GpsSignalState(
        bars: 4,
        description: 'Excellent',
      );
    }
    if (accuracyM <= 15) {
      return const GpsSignalState(
        bars: 3,
        description: 'Good',
      );
    }
    if (accuracyM <= 25) {
      return const GpsSignalState(
        bars: 2,
        description: 'Fair',
      );
    }
    return const GpsSignalState(
      bars: 1,
      description: 'Weak fix',
    );
  }

  String? _permissionMessage(LocationPermissionState permission) {
    switch (permission) {
      case LocationPermissionState.granted:
        return null;
      case LocationPermissionState.grantedForegroundOnly:
        return _allTimePermissionMessage;
      case LocationPermissionState.denied:
        return _locationPermissionMessage;
      case LocationPermissionState.deniedForever:
        return _locationDeniedForeverMessage;
      case LocationPermissionState.serviceDisabled:
        return _locationServiceDisabledMessage;
    }
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    _sampleWatchdogTicker?.cancel();
    _backgroundSyncTicker?.cancel();
    _locationSubscription?.cancel();
    super.dispose();
  }
}
