import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/session_constants.dart';
import '../domain/location_tracking_repository.dart';
import '../domain/session_models.dart';
import '../domain/session_repository.dart';

enum RecordScreenPhase {
  preRecord,
  requestingPermissions,
  ready,
  recording,
  paused,
  finishing,
  syncPending,
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
    this.session,
    this.errorMessage,
    this.preselectedResortId,
    this.recoveryCandidate,
    this.lastSyncMessage,
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
  final LocalRideSession? session;
  final String? errorMessage;
  final String? preselectedResortId;
  final LocalRideSession? recoveryCandidate;
  final String? lastSyncMessage;

  bool get hasLocationPermission =>
      permissionState == LocationPermissionState.granted ||
      permissionState == LocationPermissionState.grantedForegroundOnly;

  bool get canStart =>
      hasLocationPermission &&
      phase != RecordScreenPhase.requestingPermissions &&
      phase != RecordScreenPhase.recording &&
      phase != RecordScreenPhase.paused &&
      phase != RecordScreenPhase.finishing;

  bool get hasRecovery => recoveryCandidate != null;

  bool get hasConfirmedBackgroundTracking =>
      permissionState == LocationPermissionState.granted;

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
    LocalRideSession? session,
    String? errorMessage,
    bool clearError = false,
    String? preselectedResortId,
    LocalRideSession? recoveryCandidate,
    bool clearRecovery = false,
    String? lastSyncMessage,
    bool clearSyncMessage = false,
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
      session: session ?? this.session,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      preselectedResortId: preselectedResortId ?? this.preselectedResortId,
      recoveryCandidate:
          clearRecovery ? null : (recoveryCandidate ?? this.recoveryCandidate),
      lastSyncMessage:
          clearSyncMessage ? null : (lastSyncMessage ?? this.lastSyncMessage),
    );
  }
}

class RecordingController extends StateNotifier<RecordingViewState> {
  RecordingController({
    required SessionRepository sessionRepository,
    required LocationTrackingRepository locationTrackingRepository,
  })  : _sessionRepository = sessionRepository,
        _locationTrackingRepository = locationTrackingRepository,
        _analyticsEngine = const SessionAnalyticsEngine(),
        super(RecordingViewState.initial());

  final SessionRepository _sessionRepository;
  final LocationTrackingRepository _locationTrackingRepository;
  final SessionAnalyticsEngine _analyticsEngine;

  StreamSubscription<LocationSample>? _locationSubscription;
  Timer? _elapsedTicker;
  final List<LocalSessionPoint> _acceptedPoints = <LocalSessionPoint>[];
  Duration _elapsedBeforeActive = Duration.zero;
  DateTime? _activeSegmentStartedAtUtc;
  bool _locationStreamStopping = false;
  bool _locationStreamRestartQueued = false;

  Future<void> bootstrap({String? preselectedResortId}) async {
    if (state.session?.isInProgress ?? false) {
      final LocationPermissionState permission =
          await _locationTrackingRepository.ensurePermissions();
      state = state.copyWith(
        permissionState: permission,
        preselectedResortId: preselectedResortId,
        clearError: true,
      );
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
    );
  }

  Future<void> resumeRecoveredSession() async {
    final LocalRideSession? recovery = state.recoveryCandidate;
    if (recovery == null) {
      return;
    }

    state = state.copyWith(
      session: recovery,
      clearRecovery: true,
      phase: recovery.state == LocalSessionState.paused
          ? RecordScreenPhase.paused
          : RecordScreenPhase.recording,
    );

    final SessionDetail detail =
        await _sessionRepository.getSessionDetail(recovery.localId);
    _acceptedPoints
      ..clear()
      ..addAll(detail.acceptedPoints);

    final SessionStats stats =
        await _sessionRepository.computeSessionStats(recovery.localId);
    _elapsedBeforeActive = Duration(seconds: stats.durationS);
    _activeSegmentStartedAtUtc = null;

    if (recovery.state == LocalSessionState.recording) {
      _startActiveElapsedClock();
    } else {
      _stopElapsedTicker();
    }

    state = state.copyWith(
      liveStats: stats,
      route: detail.points
          .map((LocalSessionPoint point) =>
              LatLng(point.latitude, point.longitude))
          .toList(growable: false),
      elapsed: _currentElapsedDuration(),
      maxSpeedMps: stats.maxSpeedMps,
    );

    if (state.phase == RecordScreenPhase.recording) {
      await _startLocationStream();
    }
  }

  Future<void> discardRecovery() async {
    state = state.copyWith(clearRecovery: true);
  }

  Future<void> startRecording() async {
    if (!state.hasLocationPermission) {
      state = state.copyWith(
        errorMessage: 'Location permission is required before recording.',
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
      _acceptedPoints.clear();
      _elapsedBeforeActive = Duration.zero;
    }
    _startActiveElapsedClock();

    state = state.copyWith(
      session: session,
      phase: RecordScreenPhase.recording,
      route: hasInProgressSession ? state.route : <LatLng>[],
      liveStats: hasInProgressSession ? state.liveStats : SessionStats.zero,
      currentSpeedMps: hasInProgressSession ? state.currentSpeedMps : 0,
      maxSpeedMps: hasInProgressSession ? state.maxSpeedMps : 0,
      elapsed: _currentElapsedDuration(),
      clearError: true,
      clearSyncMessage: true,
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
  }

  Future<void> resume() async {
    final LocalRideSession? session = state.session;
    if (session == null) {
      return;
    }

    _startActiveElapsedClock();
    final LocalRideSession updated =
        await _sessionRepository.resumeLocalSession(session.localId);
    state = state.copyWith(
      session: updated,
      phase: RecordScreenPhase.recording,
    );

    await _startLocationStream();
  }

  Future<void> finish() async {
    final LocalRideSession? session = state.session;
    if (session == null) {
      return;
    }

    state = state.copyWith(phase: RecordScreenPhase.finishing);
    _pauseElapsedClock();
    await _stopLocationStream();

    final int elapsedDurationS = _currentElapsedDuration().inSeconds;

    final LocalRideSession completed =
        await _sessionRepository.finishLocalSession(
      session.localId,
      activeDurationS: elapsedDurationS,
    );

    state = state.copyWith(
      session: completed,
      phase: RecordScreenPhase.syncPending,
      elapsed: Duration(seconds: elapsedDurationS),
      liveStats: _toSessionStats(completed),
      historyRevision: state.historyRevision + 1,
    );

    unawaited(_syncInBackground(completed.localId));
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
    final List<LocalRideSession> sessions =
        await _sessionRepository.listLocalAndRemoteSessionHistory();
    final Iterable<LocalRideSession> pending = sessions.where(
      (LocalRideSession session) =>
          session.localId > 0 &&
          (session.state == LocalSessionState.syncPending ||
              session.state == LocalSessionState.syncFailed),
    );

    bool syncedAny = false;
    for (final LocalRideSession session in pending) {
      await _sessionRepository.syncSession(session.localId);
      syncedAny = true;
    }

    if (syncedAny) {
      state = state.copyWith(historyRevision: state.historyRevision + 1);
    }
  }

  Future<void> _startLocationStream() async {
    await _stopLocationStream();
    _locationStreamStopping = false;
    _locationStreamRestartQueued = false;
    _locationSubscription = _locationTrackingRepository.watchPosition().listen(
      (LocationSample sample) {
        unawaited(_onLocation(sample));
      },
      onError: _onLocationStreamError,
      onDone: _onLocationStreamDone,
      cancelOnError: false,
    );
  }

  Future<void> _stopLocationStream() async {
    final StreamSubscription<LocationSample>? subscription =
        _locationSubscription;
    if (subscription == null) {
      return;
    }

    _locationStreamStopping = true;
    await subscription.cancel();
    _locationSubscription = null;
  }

  void _onLocationStreamError(Object error, StackTrace stackTrace) {
    state = state.copyWith(
      errorMessage: 'Location stream interrupted. Reconnecting...',
    );
    unawaited(_restartLocationStreamIfNeeded());
  }

  void _onLocationStreamDone() {
    if (_locationStreamStopping) {
      _locationStreamStopping = false;
      return;
    }
    unawaited(_restartLocationStreamIfNeeded());
  }

  Future<void> _restartLocationStreamIfNeeded() async {
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
    await _startLocationStream();
  }

  Future<void> _onLocation(LocationSample sample) async {
    final LocalRideSession? session = state.session;
    if (session == null || state.phase != RecordScreenPhase.recording) {
      return;
    }

    final int tOffsetMs = sample.timestamp
        .toUtc()
        .difference(session.startedAt.toUtc())
        .inMilliseconds;

    final NewSessionPoint incomingPoint = NewSessionPoint(
      recordedAt: sample.timestamp.toUtc(),
      tOffsetMs: tOffsetMs,
      latitude: sample.latitude,
      longitude: sample.longitude,
      accuracyM: sample.accuracyM,
      altitudeM: sample.altitudeM,
      speedMps: sample.speedMps,
      headingDeg: sample.headingDeg,
      acceptedForAnalytics: false,
    );

    final LocalSessionPoint? previousAccepted =
        _acceptedPoints.isEmpty ? null : _acceptedPoints.last;
    final PointAcceptanceResult acceptance = _analyticsEngine.evaluate(
      previousAccepted,
      incomingPoint,
    );

    final NewSessionPoint persisted = NewSessionPoint(
      recordedAt: incomingPoint.recordedAt,
      tOffsetMs: incomingPoint.tOffsetMs,
      latitude: incomingPoint.latitude,
      longitude: incomingPoint.longitude,
      accuracyM: incomingPoint.accuracyM,
      altitudeM: incomingPoint.altitudeM,
      speedMps: incomingPoint.speedMps,
      headingDeg: incomingPoint.headingDeg,
      acceptedForAnalytics: acceptance.acceptedForAnalytics,
    );

    await _sessionRepository.appendLocationPoint(session.localId, persisted);

    final List<LatLng> updatedRoute = List<LatLng>.from(state.route);
    if (acceptance.acceptedForReplay) {
      updatedRoute.add(LatLng(sample.latitude, sample.longitude));
    }

    if (acceptance.acceptedForAnalytics) {
      _acceptedPoints.add(
        LocalSessionPoint(
          id: 0,
          localSessionId: session.localId,
          recordedAt: incomingPoint.recordedAt,
          tOffsetMs: incomingPoint.tOffsetMs,
          latitude: incomingPoint.latitude,
          longitude: incomingPoint.longitude,
          accuracyM: incomingPoint.accuracyM,
          altitudeM: incomingPoint.altitudeM,
          speedMps: incomingPoint.speedMps,
          headingDeg: incomingPoint.headingDeg,
          acceptedForAnalytics: true,
        ),
      );
    }

    final int activeDurationS = _currentElapsedDuration().inSeconds;
    final SessionStats stats = _analyticsEngine.computeStats(
      acceptedPoints: _acceptedPoints,
      activeDurationS: activeDurationS,
    );

    state = state.copyWith(
      route: updatedRoute,
      liveStats: stats,
      currentSpeedMps: sample.speedMps ?? _estimateCurrentSpeed(),
      maxSpeedMps: stats.maxSpeedMps,
      elapsed: _currentElapsedDuration(),
      lowAccuracy: (sample.accuracyM ?? 0) >
          SessionConstants.analyticsAccuracyThresholdMeters,
    );
  }

  double _estimateCurrentSpeed() {
    if (_acceptedPoints.length < 2) {
      return 0;
    }

    final LocalSessionPoint previous =
        _acceptedPoints[_acceptedPoints.length - 2];
    final LocalSessionPoint current = _acceptedPoints.last;

    final int delta =
        current.recordedAt.difference(previous.recordedAt).inSeconds;
    if (delta <= 0) {
      return 0;
    }

    final double distance = haversineDistanceMeters(
      previous.latitude,
      previous.longitude,
      current.latitude,
      current.longitude,
    );
    return distance / delta;
  }

  SessionStats _toSessionStats(LocalRideSession session) {
    return SessionStats(
      durationS: session.activeDurationS,
      distanceM: session.distanceM,
      maxSpeedMps: session.maxSpeedMps,
      avgSpeedMps: session.avgSpeedMps,
      elevationGainM: session.elevationGainM,
      elevationLossM: session.elevationLossM,
    );
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

  Future<void> _syncInBackground(int localSessionId) async {
    final LocalRideSession synced =
        await _sessionRepository.syncSession(localSessionId);
    if (state.session?.localId == localSessionId) {
      state = state.copyWith(
        session: synced,
        phase: state.phase == RecordScreenPhase.syncPending
            ? RecordScreenPhase.ready
            : state.phase,
        lastSyncMessage: synced.state == LocalSessionState.synced
            ? 'Session synced in background.'
            : synced.lastSyncError,
        historyRevision: state.historyRevision + 1,
      );
      return;
    }

    state = state.copyWith(historyRevision: state.historyRevision + 1);
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    _locationSubscription?.cancel();
    super.dispose();
  }
}
