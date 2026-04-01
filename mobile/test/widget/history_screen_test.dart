import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/history_screen.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';

class FakeLocationRepository implements LocationTrackingRepository {
  @override
  Future<LocationPermissionState> checkPermissions() async =>
      LocationPermissionState.granted;

  @override
  Future<LocationPermissionState> ensurePermissions() async =>
      LocationPermissionState.granted;

  @override
  Future<LocationSample?> getCurrentLocationSample() async => null;

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Stream<LocationSample> watchPosition() => const Stream<LocationSample>.empty();

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {}

  @override
  Future<String?> checkRecordingReadiness() async => null;
}

class FakeSessionRepository implements SessionRepository {
  FakeSessionRepository(this.sessions);

  final List<LocalRideSession> sessions;
  final List<int> syncedSessionIds = <int>[];

  @override
  Future<void> appendLocationPoint(int localSessionId, NewSessionPoint point) async {}

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async =>
      SessionStats.zero;

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
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async => sessions;

  @override
  Future<List<LocalRideSession>> listPendingSyncSessions() async => sessions
      .where((LocalRideSession session) => session.isUnsynced)
      .toList(growable: false);

  @override
  Future<void> recordTrackingDiagnostic(
    int localSessionId, {
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) async {}

  @override
  Future<void> refreshRemoteSessionHistoryCache() async {}

  @override
  Future<LocalRideSession?> recoverInProgressSession() async => null;

  @override
  Future<LocalRideSession> pauseLocalSession(int localSessionId) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalRideSession> resumeLocalSession(int localSessionId) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalRideSession> retryFailedSync(int localSessionId) async =>
      syncSession(localSessionId);

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
    syncedSessionIds.add(localSessionId);
    return sessions.firstWhere((LocalRideSession session) => session.localId == localSessionId);
  }

  @override
  Future<int> unsyncedCount() async =>
      sessions.where((LocalRideSession session) => session.isUnsynced).length;
}

LocalRideSession buildSession() {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: 1,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: 'Whistler',
    startedAt: now,
    endedAt: now,
    activeDurationS: 360,
    distanceM: 1234,
    maxSpeedMps: 18.5,
    avgSpeedMps: 9.1,
    elevationGainM: 10,
    elevationLossM: 200,
    state: LocalSessionState.syncPending,
    pointCount: 20,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  testWidgets('history screen renders formatted session card',
      (WidgetTester tester) async {
    final FakeSessionRepository repository =
        FakeSessionRepository(<LocalRideSession>[buildSession()]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(repository),
          locationTrackingRepositoryProvider.overrideWithValue(
            FakeLocationRepository(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: <RouteBase>[
              GoRoute(path: '/', builder: (_, __) => const HistoryScreen()),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Whistler'), findsOneWidget);
    expect(find.textContaining('00:06:00'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.byTooltip('Sync now'), findsOneWidget);
  });

  testWidgets('history screen sync action retries an unsynced session',
      (WidgetTester tester) async {
    final FakeSessionRepository repository =
        FakeSessionRepository(<LocalRideSession>[buildSession()]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(repository),
          locationTrackingRepositoryProvider.overrideWithValue(
            FakeLocationRepository(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: <RouteBase>[
              GoRoute(path: '/', builder: (_, __) => const HistoryScreen()),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sync now').first);
    await tester.pumpAndSettle();

    expect(repository.syncedSessionIds, contains(1));
  });
}
