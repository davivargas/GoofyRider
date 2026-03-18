import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/constants/session_constants.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/recording_controller.dart';

class ControlledLocationRepository implements LocationTrackingRepository {
  ControlledLocationRepository({
    this.permissionState = LocationPermissionState.granted,
    this.canOpenAppSettings = true,
    this.canOpenLocationSettings = true,
  });

  final StreamController<LocationSample> _controller =
      StreamController<LocationSample>.broadcast();
  LocationPermissionState permissionState;
  bool canOpenAppSettings;
  bool canOpenLocationSettings;

  @override
  Future<LocationPermissionState> checkPermissions() async {
    return permissionState;
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
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
  Stream<LocationSample> watchPosition() {
    return _controller.stream;
  }

  void emit(LocationSample sample) {
    _controller.add(sample);
  }

  Future<void> close() async {
    await _controller.close();
  }
}

class FakeSessionRepository implements SessionRepository {
  FakeSessionRepository({
    this.recoverySession,
    List<LocalSessionPoint>? recoveryAcceptedPoints,
  }) : _recoveryAcceptedPoints =
            recoveryAcceptedPoints ?? <LocalSessionPoint>[];

  final LocalRideSession? recoverySession;
  final List<LocalSessionPoint> _recoveryAcceptedPoints;
  final List<NewSessionPoint> appendedPoints = <NewSessionPoint>[];

  LocalRideSession? _activeSession;

  @override
  Future<void> appendLocationPoint(
      int localSessionId, NewSessionPoint point) async {
    appendedPoints.add(point);
  }

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async {
    return SessionStats(
      durationS: _recoveryAcceptedPoints.length *
          SessionConstants.targetIntervalSeconds,
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
    );
  }

  @override
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async {
    return <LocalRideSession>[];
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
    _activeSession = _buildSession(
      id: 1,
      state: LocalSessionState.recording,
      startedAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
    );
    return _activeSession!;
  }

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
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
}

LocalRideSession _buildSession({
  required int id,
  required LocalSessionState state,
  required DateTime startedAt,
}) {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: id,
    remoteId: null,
    resortId: null,
    startedAt: startedAt,
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
    expect(controller.state.route.length, 2);

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
          timestamp: start.add(Duration(
            seconds: i * SessionConstants.targetIntervalSeconds,
          )),
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

    expect(controller.state.route.length, SessionConstants.maxLiveRoutePoints);
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
      controller.state.errorMessage,
      contains('Allow all the time'),
    );

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
        controller.state.errorMessage, contains('Could not open app settings'));

    controller.dispose();
  });
}
