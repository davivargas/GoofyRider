import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/constants/session_constants.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/tracking_mode_profiles.dart';
import 'package:goofyrider_mobile/features/session/presentation/recording_controller.dart';

class ControlledLocationRepository implements LocationTrackingRepository {
  ControlledLocationRepository({
    this.permissionState = LocationPermissionState.granted,
    this.canOpenAppSettings = true,
    this.canOpenLocationSettings = true,
    this.readinessError,
    this.ensurePermissionsCompleter,
  });

  final StreamController<LocationSample> _controller =
      StreamController<LocationSample>.broadcast();
  LocationPermissionState permissionState;
  bool canOpenAppSettings;
  bool canOpenLocationSettings;
  String? readinessError;
  Completer<LocationPermissionState>? ensurePermissionsCompleter;
  int watchPositionCalls = 0;
  final List<TrackingMode> requestedTrackingModes = <TrackingMode>[];

  @override
  Future<LocationPermissionState> checkPermissions() async {
    return permissionState;
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    final Completer<LocationPermissionState>? completer =
        ensurePermissionsCompleter;
    if (completer != null) {
      return completer.future;
    }
    return permissionState;
  }

  @override
  Future<bool> isServiceEnabled() async {
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    return canOpenAppSettings;
  }

  @override
  Future<bool> openLocationSettings() async {
    return canOpenLocationSettings;
  }

  @override
  Future<String?> checkRecordingReadiness() async {
    return readinessError;
  }

  @override
  Future<LocationSample?> getCurrentLocationSample() async {
    return LocationSample(
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
      latitude: 49,
      longitude: -123,
      accuracyM: 6,
      altitudeM: 500,
      speedMps: 0,
      headingDeg: 0,
    );
  }

  @override
  Stream<LocationSample> watchPosition() {
    watchPositionCalls += 1;
    return _controller.stream;
  }

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {
    requestedTrackingModes.add(mode);
  }

  void emit(LocationSample sample) {
    _controller.add(sample);
  }

  void emitError(Object error, [StackTrace? stackTrace]) {
    _controller.addError(error, stackTrace);
  }

  Future<void> close() async {
    await _controller.close();
  }
}

class HangingCancelLocationRepository implements LocationTrackingRepository {
  HangingCancelLocationRepository();

  final StreamController<LocationSample> _controller =
      StreamController<LocationSample>.broadcast(
    onCancel: _neverEndingCancel,
  );

  static Future<void> _neverEndingCancel() {
    return Completer<void>().future;
  }

  @override
  Future<LocationPermissionState> checkPermissions() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<bool> isServiceEnabled() async {
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    return true;
  }

  @override
  Future<String?> checkRecordingReadiness() async {
    return null;
  }

  @override
  Future<LocationSample?> getCurrentLocationSample() async {
    return null;
  }

  @override
  Stream<LocationSample> watchPosition() {
    return _controller.stream;
  }

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {}

  void emit(LocationSample sample) {
    _controller.add(sample);
  }
}

class FakeSessionRepository implements SessionRepository {
  FakeSessionRepository({
    this.recoverySession,
    List<LocalSessionPoint>? recoveryAcceptedPoints,
    this.startLocalSessionCompleter,
    List<LocalRideSession>? pendingSyncSessions,
  })  : _recoveryAcceptedPoints =
            recoveryAcceptedPoints ?? <LocalSessionPoint>[],
        pendingSyncSessions = pendingSyncSessions ?? <LocalRideSession>[];

  final LocalRideSession? recoverySession;
  final List<LocalSessionPoint> _recoveryAcceptedPoints;
  final Completer<void>? startLocalSessionCompleter;
  final List<LocalRideSession> pendingSyncSessions;
  final List<int> syncedSessionIds = <int>[];
  final Set<int> syncSessionThrowIds = <int>{};
  final List<NewSessionPoint> appendedPoints = <NewSessionPoint>[];
  final List<TrackingDiagnosticEvent> recordedDiagnostics =
      <TrackingDiagnosticEvent>[];
  int listPendingSyncSessionsCalls = 0;
  int syncSessionCalls = 0;
  int startLocalSessionCalls = 0;
  int _nextDiagnosticId = 1;

  LocalRideSession? _activeSession;

  @override
  Future<void> appendLocationPoint(
      int localSessionId, NewSessionPoint point) async {
    appendedPoints.add(point);
  }

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async {
    final int activeDescentIntervalS =
        (TrackingModeProfiles.activeDescent.intervalMs / 1000).round();
    return SessionStats(
      durationS: _recoveryAcceptedPoints.length * activeDescentIntervalS,
      distanceM: 1200,
      maxSpeedMps: 14,
      avgSpeedMps: 8,
      elevationGainM: 100,
      elevationLossM: 300,
    );
  }

  @override
  Future<LocalRideSession> finishLocalSession(
    int localSessionId, {
    int? activeDurationS,
  }) async {
    return _buildSession(
      id: localSessionId,
      state: LocalSessionState.syncPending,
      startedAt: _activeSession?.startedAt ?? DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<SessionDetail> getSessionDetail(int localSessionId) async {
    final LocalRideSession session = recoverySession!;
    return SessionDetail(
      session: session,
      points: _recoveryAcceptedPoints,
      acceptedPoints: _recoveryAcceptedPoints,
      trackingDiagnostics: List<TrackingDiagnosticEvent>.from(
        recordedDiagnostics,
      ),
    );
  }

  @override
  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit = 120,
  }) async {
    return List<TrackingDiagnosticEvent>.from(recordedDiagnostics);
  }

  @override
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async {
    return <LocalRideSession>[];
  }

  @override
  Future<List<LocalRideSession>> listPendingSyncSessions() async {
    listPendingSyncSessionsCalls += 1;
    return pendingSyncSessions;
  }

  @override
  Future<void> refreshRemoteSessionHistoryCache() async {}

  @override
  Future<DeleteSessionResult> deleteSession(LocalRideSession session) async {
    return const DeleteSessionResult(
      disposition: DeleteSessionDisposition.localOnly,
    );
  }

  @override
  Future<String> resolveSessionResortLabel(LocalRideSession session) async {
    return session.resortId ?? 'Unknown resort';
  }

  @override
  Future<LocalRideSession> pauseLocalSession(int localSessionId) async {
    _activeSession = _buildSession(
      id: localSessionId,
      state: LocalSessionState.paused,
      startedAt: _activeSession?.startedAt ?? DateTime.utc(2026, 1, 1),
    );
    return _activeSession!;
  }

  @override
  Future<LocalRideSession?> recoverInProgressSession() async {
    return recoverySession;
  }

  @override
  Future<LocalRideSession> resumeLocalSession(int localSessionId) async {
    _activeSession = _buildSession(
      id: localSessionId,
      state: LocalSessionState.recording,
      startedAt: _activeSession?.startedAt ?? DateTime.utc(2026, 1, 1),
    );
    return _activeSession!;
  }

  @override
  Future<LocalRideSession> retryFailedSync(int localSessionId) async {
    return _buildSession(
      id: localSessionId,
      state: LocalSessionState.synced,
      startedAt: _activeSession?.startedAt ?? DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async {
    startLocalSessionCalls += 1;
    final Completer<void>? completer = startLocalSessionCompleter;
    if (completer != null) {
      await completer.future;
    }
    _activeSession = _buildSession(
      id: 1,
      state: LocalSessionState.recording,
      startedAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
    );
    return _activeSession!;
  }

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
    syncSessionCalls += 1;
    syncedSessionIds.add(localSessionId);
    if (syncSessionThrowIds.contains(localSessionId)) {
      throw StateError('Unexpected local sync failure.');
    }
    return _buildSession(
      id: localSessionId,
      state: LocalSessionState.synced,
      startedAt: _activeSession?.startedAt ?? DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<int> unsyncedCount() async {
    return 0;
  }

  @override
  Future<void> recordTrackingDiagnostic(
    int localSessionId, {
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) async {
    recordedDiagnostics.add(
      TrackingDiagnosticEvent(
        id: _nextDiagnosticId,
        localSessionId: localSessionId,
        occurredAt: DateTime.now().toUtc(),
        eventType: eventType,
        message: message,
        details:
            Map<String, dynamic>.from(details ?? const <String, dynamic>{}),
      ),
    );
    _nextDiagnosticId += 1;
  }
}

class FlakyPersistenceSessionRepository implements SessionRepository {
  FlakyPersistenceSessionRepository();

  final List<NewSessionPoint> appendedPoints = <NewSessionPoint>[];
  bool _failedFirstAppend = false;
  LocalRideSession? _activeSession;

  @override
  Future<void> appendLocationPoint(
    int localSessionId,
    NewSessionPoint point,
  ) async {
    if (!_failedFirstAppend) {
      _failedFirstAppend = true;
      throw StateError('Local write temporarily unavailable.');
    }
    appendedPoints.add(point);
  }

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async {
    final List<NewSessionPoint> acceptedPoints = appendedPoints
        .where((NewSessionPoint point) => point.acceptedForAnalytics)
        .toList(growable: false);
    if (acceptedPoints.isEmpty) {
      return SessionStats.zero;
    }

    double distanceM = 0;
    for (int index = 1; index < acceptedPoints.length; index += 1) {
      final NewSessionPoint previous = acceptedPoints[index - 1];
      final NewSessionPoint current = acceptedPoints[index];
      distanceM += haversineDistanceMeters(
        previous.filteredLatitude ?? previous.latitude,
        previous.filteredLongitude ?? previous.longitude,
        current.filteredLatitude ?? current.latitude,
        current.filteredLongitude ?? current.longitude,
      );
    }

    double maxSpeedMps = 0;
    for (final NewSessionPoint point in acceptedPoints) {
      final double speed =
          point.fusedSpeedMps ?? point.derivedSpeedMps ?? point.speedMps ?? 0;
      if (speed > maxSpeedMps) {
        maxSpeedMps = speed;
      }
    }

    return SessionStats(
      durationS: (acceptedPoints.last.tOffsetMs / 1000).round(),
      distanceM: distanceM,
      maxSpeedMps: maxSpeedMps,
      avgSpeedMps: 0,
      elevationGainM: null,
      elevationLossM: null,
    );
  }

  @override
  Future<LocalRideSession> finishLocalSession(
    int localSessionId, {
    int? activeDurationS,
  }) async {
    return _buildSession(
        id: localSessionId, state: LocalSessionState.syncPending);
  }

  @override
  Future<SessionDetail> getSessionDetail(int localSessionId) async {
    final List<LocalSessionPoint> points = <LocalSessionPoint>[
      for (int index = 0; index < appendedPoints.length; index += 1)
        _buildLocalPoint(
          id: index + 1,
          localSessionId: localSessionId,
          point: appendedPoints[index],
        ),
    ];
    final List<LocalSessionPoint> acceptedPoints = points
        .where((LocalSessionPoint point) => point.acceptedForAnalytics)
        .toList(growable: false);
    return SessionDetail(
      session: _activeSession ??
          _buildSession(id: localSessionId, state: LocalSessionState.recording),
      points: points,
      acceptedPoints: acceptedPoints,
      trackingDiagnostics: const <TrackingDiagnosticEvent>[],
    );
  }

  @override
  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit = 120,
  }) async {
    return const <TrackingDiagnosticEvent>[];
  }

  @override
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async {
    return <LocalRideSession>[];
  }

  @override
  Future<List<LocalRideSession>> listPendingSyncSessions() async {
    return <LocalRideSession>[];
  }

  @override
  Future<void> refreshRemoteSessionHistoryCache() async {}

  @override
  Future<DeleteSessionResult> deleteSession(LocalRideSession session) async {
    return const DeleteSessionResult(
      disposition: DeleteSessionDisposition.localOnly,
    );
  }

  @override
  Future<String> resolveSessionResortLabel(LocalRideSession session) async {
    return session.resortId ?? 'Unknown resort';
  }

  @override
  Future<LocalRideSession> pauseLocalSession(int localSessionId) async {
    _activeSession =
        _buildSession(id: localSessionId, state: LocalSessionState.paused);
    return _activeSession!;
  }

  @override
  Future<LocalRideSession?> recoverInProgressSession() async => null;

  @override
  Future<void> recordTrackingDiagnostic(
    int localSessionId, {
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) async {}

  @override
  Future<LocalRideSession> resumeLocalSession(int localSessionId) async {
    _activeSession =
        _buildSession(id: localSessionId, state: LocalSessionState.recording);
    return _activeSession!;
  }

  @override
  Future<LocalRideSession> retryFailedSync(int localSessionId) async {
    return _buildSession(id: localSessionId, state: LocalSessionState.synced);
  }

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async {
    _activeSession = _buildSession(id: 1, state: LocalSessionState.recording);
    return _activeSession!;
  }

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
    return _buildSession(id: localSessionId, state: LocalSessionState.synced);
  }

  @override
  Future<int> unsyncedCount() async {
    return 0;
  }
}

LocalSessionPoint _buildLocalPoint({
  required int id,
  required int localSessionId,
  required NewSessionPoint point,
}) {
  return LocalSessionPoint(
    id: id,
    localSessionId: localSessionId,
    recordedAt: point.recordedAt,
    tOffsetMs: point.tOffsetMs,
    latitude: point.latitude,
    longitude: point.longitude,
    accuracyM: point.accuracyM,
    altitudeM: point.altitudeM,
    speedMps: point.speedMps,
    headingDeg: point.headingDeg,
    acceptedForAnalytics: point.acceptedForAnalytics,
    elapsedRealtimeNs: point.elapsedRealtimeNs,
    verticalAccuracyM: point.verticalAccuracyM,
    speedAccuracyMps: point.speedAccuracyMps,
    bearingAccuracyDeg: point.bearingAccuracyDeg,
    provider: point.provider,
    isMocked: point.isMocked,
    qualityClass: point.qualityClass,
    qualityScore: point.qualityScore,
    qualityReason: point.qualityReason,
    filteredLatitude: point.filteredLatitude,
    filteredLongitude: point.filteredLongitude,
    filteredAltitudeM: point.filteredAltitudeM,
    fusedSpeedMps: point.fusedSpeedMps,
    derivedSpeedMps: point.derivedSpeedMps,
    distanceDeltaM: point.distanceDeltaM,
    motionState: point.motionState,
  );
}

LocalRideSession _buildSession({
  required int id,
  required LocalSessionState state,
  DateTime? startedAt,
}) {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: id,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: null,
    startedAt: startedAt ?? now,
    endedAt: null,
    activeDurationS: 0,
    distanceM: 0,
    maxSpeedMps: 0,
    avgSpeedMps: 0,
    elevationGainM: null,
    elevationLossM: null,
    state: state,
    pointCount: 0,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: now,
    updatedAt: now,
  );
}

LocalSessionPoint _buildAcceptedPoint({
  required int offsetMs,
  required DateTime sessionStart,
}) {
  return LocalSessionPoint(
    id: offsetMs,
    localSessionId: 1,
    recordedAt: sessionStart.add(Duration(milliseconds: offsetMs)),
    tOffsetMs: offsetMs,
    latitude: 49.0 + (offsetMs / 1000000),
    longitude: -123.0 - (offsetMs / 1000000),
    accuracyM: 5,
    altitudeM: 500,
    speedMps: 7,
    headingDeg: 90,
    acceptedForAnalytics: true,
  );
}

void main() {
  test('tracking mode profiles expose tuned watchdog thresholds', () {
    expect(
      TrackingModeProfiles.forMode(TrackingMode.initializingFix)
          .sampleWatchdogThreshold,
      const Duration(seconds: 5),
    );
    expect(
      TrackingModeProfiles.forMode(TrackingMode.activeDescent)
          .sampleWatchdogThreshold,
      const Duration(seconds: 9),
    );
    expect(
      TrackingModeProfiles.forMode(TrackingMode.liftUphill)
          .sampleWatchdogThreshold,
      const Duration(seconds: 10),
    );
    expect(
      TrackingModeProfiles.forMode(TrackingMode.stoppedIdle)
          .sampleWatchdogThreshold,
      const Duration(seconds: 25),
    );
    expect(
      TrackingModeProfiles.forMode(TrackingMode.lowConfidenceRecovery)
          .sampleWatchdogThreshold,
      const Duration(seconds: 11),
    );
    expect(
      TrackingModeProfiles.forMode(TrackingMode.liftUphill)
              .sampleWatchdogThreshold >
          TrackingModeProfiles.forMode(TrackingMode.activeDescent)
              .sampleWatchdogThreshold,
      isTrue,
    );
  });

  test('recovers in-progress recording after interruption', () async {
    final DateTime startedAt = DateTime.utc(2026, 1, 1, 8, 0, 0);
    final LocalRideSession recoverySession = _buildSession(
      id: 42,
      state: LocalSessionState.recording,
      startedAt: startedAt,
    );
    final FakeSessionRepository repository = FakeSessionRepository(
      recoverySession: recoverySession,
      recoveryAcceptedPoints: <LocalSessionPoint>[
        _buildAcceptedPoint(offsetMs: 0, sessionStart: startedAt),
        _buildAcceptedPoint(offsetMs: 3000, sessionStart: startedAt),
      ],
    );
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    expect(controller.state.hasRecovery, isTrue);
    expect(controller.state.phase, RecordScreenPhase.ready);

    await controller.resumeRecoveredSession();
    expect(controller.state.phase, RecordScreenPhase.recording);
    expect(controller.state.tracking.route.length, 2);

    controller.dispose();
    await locationRepository.close();
  });

  test('caps live route size during long recording sessions', () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    await controller.startRecording();

    final DateTime start = DateTime.utc(2026, 1, 1, 0, 0, 0);
    final int sampleCount = SessionConstants.maxLiveRoutePoints + 50;
    for (int i = 0; i < sampleCount; i++) {
      locationRepository.emit(
        LocationSample(
          timestamp: start.add(
            Duration(
              milliseconds: i * TrackingModeProfiles.activeDescent.intervalMs,
            ),
          ),
          latitude: 49.0 + (i / 100000),
          longitude: -123.0 - (i / 100000),
          accuracyM: 5,
          altitudeM: 500,
          speedMps: 8,
          headingDeg: 90,
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(controller.state.tracking.route.length, SessionConstants.maxLiveRoutePoints);
    expect(repository.appendedPoints.length, sampleCount);

    controller.dispose();
    await locationRepository.close();
  });

  test('blocks recording until all-time permission is granted', () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository(
      permissionState: LocationPermissionState.grantedForegroundOnly,
    );
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    await controller.startRecording();

    expect(controller.state.phase, RecordScreenPhase.ready);
    expect(controller.state.session, isNull);
    expect(
      controller.state.permission.errorMessage,
      contains('Allow all the time'),
    );

    controller.dispose();
    await locationRepository.close();
  });

  test('ignores overlapping start requests', () async {
    final Completer<void> startGate = Completer<void>();
    final FakeSessionRepository repository = FakeSessionRepository(
      startLocalSessionCompleter: startGate,
    );
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();

    final Future<void> firstStart = controller.startRecording();
    final Future<void> secondStart = controller.startRecording();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(repository.startLocalSessionCalls, 1);
    expect(controller.state.phase, RecordScreenPhase.ready);

    startGate.complete();
    await Future.wait(<Future<void>>[firstStart, secondStart]);

    expect(controller.state.phase, RecordScreenPhase.recording);
    expect(controller.state.session, isNotNull);
    expect(repository.startLocalSessionCalls, 1);

    controller.dispose();
    await locationRepository.close();
  });

  test('surfaces a clear message when app settings cannot be opened', () async {
    final RecordingController controller = RecordingController(
      sessionRepository: FakeSessionRepository(),
      locationTrackingRepository: ControlledLocationRepository(
        canOpenAppSettings: false,
      ),
    );

    await controller.openLocationPermissionSettings();
    expect(
        controller.state.permission.errorMessage, contains('Could not open app settings'));

    controller.dispose();
  });

  test('finish does not stay stuck when stream cancellation hangs', () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final HangingCancelLocationRepository locationRepository =
        HangingCancelLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    await controller.startRecording();

    locationRepository.emit(
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
        latitude: 49.0,
        longitude: -123.0,
        accuracyM: 5,
        altitudeM: 100,
        speedMps: 4,
        headingDeg: 90,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    await controller.finish().timeout(const Duration(seconds: 8));
    expect(controller.state.phase, isNot(RecordScreenPhase.finishing));
    expect(controller.state.phase, RecordScreenPhase.ready);
    expect(controller.state.session, isNull);
    expect(controller.state.tracking.route, isEmpty);
    expect(controller.state.tracking.liveStats.distanceM, 0);
    expect(controller.state.tracking.elapsed, Duration.zero);

    controller.dispose();
  });

  test('pauses recording cleanly when permission is downgraded mid-session',
      () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    await controller.startRecording();

    locationRepository.emit(
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
        latitude: 49.0,
        longitude: -123.0,
        accuracyM: 5,
        altitudeM: 100,
        speedMps: 4,
        headingDeg: 90,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(repository.appendedPoints, hasLength(1));

    locationRepository.permissionState =
        LocationPermissionState.grantedForegroundOnly;
    await controller.refreshPermissionState();

    expect(controller.state.phase, RecordScreenPhase.paused);
    expect(controller.state.session?.state, LocalSessionState.paused);
    expect(
      controller.state.permission.errorMessage,
      contains('Allow all the time'),
    );

    locationRepository.emit(
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 2),
        latitude: 49.0002,
        longitude: -123.0002,
        accuracyM: 5,
        altitudeM: 101,
        speedMps: 5,
        headingDeg: 90,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(repository.appendedPoints, hasLength(1));

    controller.dispose();
    await locationRepository.close();
  });

  test('blocks recording when device location settings are not ready',
      () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository(
      readinessError: 'Enable high-accuracy location before recording.',
    );
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    await controller.startRecording();

    expect(controller.state.phase, RecordScreenPhase.ready);
    expect(controller.state.session, isNull);
    expect(
      controller.state.permission.errorMessage,
      'Enable high-accuracy location before recording.',
    );

    controller.dispose();
    await locationRepository.close();
  });

  test('defers background sync while a ride is actively recording', () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    await controller.startRecording();

    repository.listPendingSyncSessionsCalls = 0;
    repository.syncSessionCalls = 0;

    await controller.retryPendingSyncs();

    expect(repository.listPendingSyncSessionsCalls, 0);
    expect(repository.syncSessionCalls, 0);
    expect(
      controller.state.sync.lastSyncMessage,
      'Sync deferred until recording finishes.',
    );

    controller.dispose();
    await locationRepository.close();
  });

  test('continues pending sync pass after one session throws unexpectedly',
      () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    repository.syncSessionThrowIds.add(12);
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    repository.pendingSyncSessions.addAll(<LocalRideSession>[
      _buildSession(id: 11, state: LocalSessionState.syncPending),
      _buildSession(id: 12, state: LocalSessionState.syncPending),
      _buildSession(id: 13, state: LocalSessionState.syncPending),
    ]);
    await controller.retryPendingSyncs();

    expect(repository.listPendingSyncSessionsCalls, greaterThanOrEqualTo(1));
    expect(repository.syncSessionCalls, 3);
    expect(repository.syncedSessionIds, <int>[11, 12, 13]);
    expect(
        controller.state.sync.lastSyncMessage, 'Sync pass: 2/3 synced, 1 failed.');

    controller.dispose();
    await locationRepository.close();
  });

  test('continues recording after a transient local point persistence failure',
      () async {
    final FlakyPersistenceSessionRepository repository =
        FlakyPersistenceSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    await controller.startRecording();

    locationRepository.emit(
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
        latitude: 49.0,
        longitude: -123.0,
        accuracyM: 5,
        altitudeM: 100,
        speedMps: 4,
        headingDeg: 90,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(repository.appendedPoints, isEmpty);
    expect(controller.state.tracking.route, isEmpty);
    expect(controller.state.tracking.liveStats.distanceM, 0);
    expect(controller.state.tracking.currentSpeedMps, 0);

    locationRepository.emit(
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 2),
        latitude: 49.0002,
        longitude: -123.0002,
        accuracyM: 5,
        altitudeM: 101,
        speedMps: 5,
        headingDeg: 90,
      ),
    );

    locationRepository.emit(
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 4),
        latitude: 49.0004,
        longitude: -123.0004,
        accuracyM: 5,
        altitudeM: 102,
        speedMps: 6,
        headingDeg: 90,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final SessionStats persistedStats = await repository.computeSessionStats(1);

    expect(controller.state.phase, RecordScreenPhase.recording);
    expect(controller.state.streamRestartCount, 0);
    expect(repository.appendedPoints, hasLength(2));
    expect(controller.state.tracking.route.length, 2);
    expect(controller.state.tracking.liveStats.distanceM,
        closeTo(persistedStats.distanceM, 0.1));
    expect(persistedStats.distanceM, greaterThan(0));
    expect(controller.state.tracking.lastPersistedPointAtUtc, isNotNull);

    controller.dispose();
    await locationRepository.close();
  });

  test('watchdog waits for delayed initial sample before restarting', () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );
    addTearDown(() async {
      controller.dispose();
      await locationRepository.close();
    });

    await controller.bootstrap();
    await controller.startRecording();

    await Future<void>.delayed(const Duration(seconds: 17));

    expect(controller.state.phase, RecordScreenPhase.recording);
    expect(controller.state.streamRestartCount, 0);
    expect(locationRepository.watchPositionCalls, 1);
    expect(
      repository.recordedDiagnostics.any(
        (TrackingDiagnosticEvent event) =>
            event.eventType == 'sample_watchdog_no_initial_sample',
      ),
      isTrue,
    );
    expect(
      repository.recordedDiagnostics.any(
        (TrackingDiagnosticEvent event) =>
            event.eventType == 'sample_watchdog_waiting_initial_sample',
      ),
      isTrue,
    );
    expect(
      repository.recordedDiagnostics.any(
        (TrackingDiagnosticEvent event) =>
            event.eventType == 'sample_watchdog_restart',
      ),
      isFalse,
    );

    locationRepository.emit(
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 17),
        latitude: 49.0,
        longitude: -123.0,
        accuracyM: 6,
        altitudeM: 500,
        speedMps: 0,
        headingDeg: 0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 180));

    expect(controller.state.streamRestartCount, 0);
    expect(locationRepository.watchPositionCalls, 1);
  });

  test('watchdog enters recovery before restarting a stalled live stream',
      () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );
    addTearDown(() async {
      controller.dispose();
      await locationRepository.close();
    });

    await controller.bootstrap();
    await controller.startRecording();

    locationRepository.emit(
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
        latitude: 49.0,
        longitude: -123.0,
        accuracyM: 5,
        altitudeM: 100,
        speedMps: 4,
        headingDeg: 90,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final int diagnosticBaseline = repository.recordedDiagnostics.length;
    await Future<void>.delayed(const Duration(seconds: 22));

    final List<TrackingDiagnosticEvent> watchdogDiagnostics =
        repository.recordedDiagnostics
            .skip(diagnosticBaseline)
            .where(
              (TrackingDiagnosticEvent event) =>
                  event.eventType.startsWith('sample_watchdog_'),
            )
            .toList(growable: false);

    expect(controller.state.phase, RecordScreenPhase.recording);
    expect(controller.state.streamRestartCount, 0);
    expect(locationRepository.watchPositionCalls, 1);
    expect(
      locationRepository.requestedTrackingModes,
      contains(TrackingMode.lowConfidenceRecovery),
    );
    expect(
      watchdogDiagnostics.any(
        (TrackingDiagnosticEvent event) =>
            event.eventType == 'sample_watchdog_recovery_mode',
      ),
      isTrue,
    );
    expect(
      watchdogDiagnostics.any(
        (TrackingDiagnosticEvent event) =>
            event.eventType == 'sample_watchdog_recovery_wait',
      ),
      isTrue,
    );
    expect(
      watchdogDiagnostics.any(
        (TrackingDiagnosticEvent event) =>
            event.eventType == 'sample_watchdog_restart',
      ),
      isFalse,
    );
  });

  test(
      'ignores a queued reconnect from a finished session after a new recording starts',
      () async {
    final FakeSessionRepository repository = FakeSessionRepository();
    final ControlledLocationRepository locationRepository =
        ControlledLocationRepository();
    final RecordingController controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: locationRepository,
    );

    await controller.bootstrap();
    await controller.startRecording();
    expect(locationRepository.watchPositionCalls, 1);

    locationRepository.emitError(StateError('stream dropped'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await controller.finish();
    await controller.startRecording();

    expect(controller.state.phase, RecordScreenPhase.recording);
    expect(controller.state.streamRestartCount, 0);
    expect(locationRepository.watchPositionCalls, 2);

    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(controller.state.phase, RecordScreenPhase.recording);
    expect(controller.state.streamRestartCount, 0);
    expect(locationRepository.watchPositionCalls, 2);

    controller.dispose();
    await locationRepository.close();
  });
}
