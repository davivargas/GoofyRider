import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

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
      );

  final RecordScreenPhase phase;
  final LocationPermissionState permissionState;
  final SessionStats liveStats;
  final List<LatLng> route;
  final double currentSpeedMps;
  final double maxSpeedMps;
  final Duration elapsed;
  final bool lowAccuracy;
  final LocalRideSession? session;
  final String? errorMessage;
  final String? preselectedResortId;
  final LocalRideSession? recoveryCandidate;
  final String? lastSyncMessage;

  bool get canStart =>
      permissionState == LocationPermissionState.granted &&
      phase == RecordScreenPhase.ready;

  bool get hasRecovery => recoveryCandidate != null;

  RecordingViewState copyWith({
    RecordScreenPhase? phase,
    LocationPermissionState? permissionState,
    SessionStats? liveStats,
    List<LatLng>? route,
    double? currentSpeedMps,
    double? maxSpeedMps,
    Duration? elapsed,
    bool? lowAccuracy,
    LocalRideSession? session,
    String? errorMessage,
    bool clearError = false,
    String? preselectedResortId,
    LocalRideSession? recoveryCandidate,
    bool clearRecovery = false,
    String? lastSyncMessage,
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
      session: session ?? this.session,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      preselectedResortId: preselectedResortId ?? this.preselectedResortId,
      recoveryCandidate:
          clearRecovery ? null : (recoveryCandidate ?? this.recoveryCandidate),
      lastSyncMessage: lastSyncMessage ?? this.lastSyncMessage,
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
  final List<LocalSessionPoint> _acceptedPoints = <LocalSessionPoint>[];

  Future<void> bootstrap({String? preselectedResortId}) async {
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

    final SessionStats stats =
        await _sessionRepository.computeSessionStats(recovery.localId);
    state = state.copyWith(
      liveStats: stats,
      elapsed: Duration(seconds: stats.durationS),
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
    if (state.permissionState != LocationPermissionState.granted) {
      state = state.copyWith(
        errorMessage: 'Location permission is required before recording.',
      );
      return;
    }

    final LocalRideSession session = state.session ??
        await _sessionRepository.startLocalSession(
          resortId: state.preselectedResortId,
        );

    _acceptedPoints.clear();
    state = state.copyWith(
      session: session,
      phase: RecordScreenPhase.recording,
      route: <LatLng>[],
      liveStats: SessionStats.zero,
      currentSpeedMps: 0,
      maxSpeedMps: 0,
      elapsed: Duration.zero,
      clearError: true,
    );

    await _startLocationStream();
  }

  Future<void> pause() async {
    final LocalRideSession? session = state.session;
    if (session == null) {
      return;
    }

    await _locationSubscription?.cancel();
    _locationSubscription = null;

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
    await _locationSubscription?.cancel();
    _locationSubscription = null;

    final LocalRideSession completed =
        await _sessionRepository.finishLocalSession(session.localId);

    state = state.copyWith(
      session: completed,
      phase: RecordScreenPhase.syncPending,
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
    );
  }

  Future<void> retryPendingSyncs() async {
    final List<LocalRideSession> sessions =
        await _sessionRepository.listLocalAndRemoteSessionHistory();
    final Iterable<LocalRideSession> pending = sessions.where(
      (LocalRideSession session) =>
          session.state == LocalSessionState.syncPending ||
          session.state == LocalSessionState.syncFailed,
    );

    for (final LocalRideSession session in pending) {
      await _sessionRepository.syncSession(session.localId);
    }
  }

  Future<void> _startLocationStream() async {
    await _locationSubscription?.cancel();
    _locationSubscription =
        _locationTrackingRepository.watchPosition().listen(_onLocation);
  }

  Future<void> _onLocation(LocationSample sample) async {
    final LocalRideSession? session = state.session;
    if (session == null) {
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

    final int activeDurationS =
        _calculateActiveDurationSeconds(_acceptedPoints);
    final SessionStats stats = _analyticsEngine.computeStats(
      acceptedPoints: _acceptedPoints,
      activeDurationS: activeDurationS,
    );

    state = state.copyWith(
      route: updatedRoute,
      liveStats: stats,
      currentSpeedMps: sample.speedMps ?? _estimateCurrentSpeed(),
      maxSpeedMps: stats.maxSpeedMps,
      elapsed: Duration(seconds: stats.durationS),
      lowAccuracy: (sample.accuracyM ?? 0) > 35,
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

  int _calculateActiveDurationSeconds(List<LocalSessionPoint> accepted) {
    if (accepted.length < 2) {
      return 0;
    }

    int total = 0;
    for (int index = 1; index < accepted.length; index++) {
      final int delta = accepted[index]
          .recordedAt
          .difference(accepted[index - 1].recordedAt)
          .inSeconds;
      if (delta >= 1 && delta <= 20) {
        total += delta;
      }
    }
    return total;
  }

  Future<void> _syncInBackground(int localSessionId) async {
    final LocalRideSession synced =
        await _sessionRepository.syncSession(localSessionId);
    if (state.session?.localId == localSessionId) {
      state = state.copyWith(
        session: synced,
        lastSyncMessage: synced.state == LocalSessionState.synced
            ? 'Session synced in background.'
            : synced.lastSyncError,
      );
    }
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    super.dispose();
  }
}
