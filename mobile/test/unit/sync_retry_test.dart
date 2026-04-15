import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/recording_controller.dart';

class FakeLocationRepository implements LocationTrackingRepository {
  @override
  Future<LocationPermissionState> checkPermissions() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<LocationPermissionState> ensureForegroundPermission() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<LocationSample?> getCurrentLocationSample() async {
    return null;
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
  Stream<LocationSample> watchPosition() {
    return const Stream<LocationSample>.empty();
  }

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {}
}

class FakeSessionRepository implements SessionRepository {
  FakeSessionRepository(this.sessions);

  final List<LocalRideSession> sessions;
  final List<int> syncedIds = <int>[];

  @override
  Future<void> appendLocationPoint(
    int localSessionId,
    NewSessionPoint point,
  ) async {}

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async {
    return SessionStats.zero;
  }

  @override
  Future<LocalRideSession> finishLocalSession(
    int localSessionId, {
    int? activeDurationS,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SessionDetail> getSessionDetail(int localSessionId) async {
    throw UnimplementedError();
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
    return sessions;
  }

  @override
  Future<List<LocalRideSession>> listPendingSyncSessions() async {
    return sessions
        .where((LocalRideSession session) =>
            session.state == LocalSessionState.syncPending ||
            session.state == LocalSessionState.syncFailed)
        .toList(growable: false);
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
    throw UnimplementedError();
  }

  @override
  Future<LocalRideSession?> recoverInProgressSession() async {
    return null;
  }

  @override
  Future<void> recordTrackingDiagnostic(
    int localSessionId, {
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) async {}

  @override
  Future<LocalRideSession> resumeLocalSession(int localSessionId) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalRideSession> retryFailedSync(int localSessionId) async {
    return syncSession(localSessionId);
  }

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
    syncedIds.add(localSessionId);
    return sessions
        .firstWhere((LocalRideSession it) => it.localId == localSessionId);
  }

  @override
  Future<int> unsyncedCount() async {
    return sessions.where((LocalRideSession it) => it.isUnsynced).length;
  }
}

LocalRideSession buildSession({
  required int id,
  required LocalSessionState state,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: id,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: null,
    startedAt: now,
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

void main() {
  test('retryPendingSyncs retries pending and failed sessions', () async {
    final repository = FakeSessionRepository(
      <LocalRideSession>[
        buildSession(id: 1, state: LocalSessionState.syncPending),
        buildSession(id: 2, state: LocalSessionState.syncFailed),
        buildSession(id: 3, state: LocalSessionState.synced),
      ],
    );

    final controller = RecordingController(
      sessionRepository: repository,
      locationTrackingRepository: FakeLocationRepository(),
    );

    await controller.retryPendingSyncs();

    expect(repository.syncedIds, containsAll(<int>[1, 2]));
    expect(repository.syncedIds, isNot(contains(3)));

    controller.dispose();
  });
}
