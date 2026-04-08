import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/history_screen.dart';
import 'package:goofyrider_mobile/features/session/presentation/history_view_models.dart';
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

  @override
  Future<void> appendLocationPoint(int localSessionId, NewSessionPoint point) async {}

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async =>
      SessionStats.zero;

  @override
  Future<DeleteSessionResult> deleteSession(LocalRideSession session) async {
    return const DeleteSessionResult(
      disposition: DeleteSessionDisposition.localOnly,
    );
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
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async => sessions;

  @override
  Future<List<LocalRideSession>> listPendingSyncSessions() async => sessions;

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
  Future<String> resolveSessionResortLabel(LocalRideSession session) async {
    return session.resortId ?? 'Unknown resort';
  }

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
  Future<LocalRideSession> retryFailedSync(int localSessionId) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
    throw UnimplementedError();
  }

  @override
  Future<int> unsyncedCount() async => 0;
}

LocalRideSession buildSession() {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: 1,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: 'resort-1',
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
  testWidgets('history screen renders season header and resolved resort label',
      (WidgetTester tester) async {
    final LocalRideSession session = buildSession();
    final FakeSessionRepository repository =
        FakeSessionRepository(<LocalRideSession>[session]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(repository),
          locationTrackingRepositoryProvider.overrideWithValue(
            FakeLocationRepository(),
          ),
          historySectionsProvider.overrideWith(
            (_) async => <SessionHistorySeasonSection>[
              SessionHistorySeasonSection(
                label: '2025/2026',
                items: <SessionHistoryEntryViewModel>[
                  SessionHistoryEntryViewModel(
                    session: session,
                    resortLabel: 'Whistler Blackcomb',
                  ),
                ],
              ),
            ],
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
    expect(find.text('2025/2026'), findsOneWidget);
    expect(find.text('Whistler Blackcomb'), findsOneWidget);
    expect(find.textContaining('00:06:00'), findsOneWidget);
    expect(find.textContaining('Pending'), findsOneWidget);
  });

  testWidgets(
      'history screen keeps sync state visible and no per-card overflow actions',
      (WidgetTester tester) async {
    final LocalRideSession session = buildSession();
    final FakeSessionRepository repository =
        FakeSessionRepository(<LocalRideSession>[session]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(repository),
          locationTrackingRepositoryProvider.overrideWithValue(
            FakeLocationRepository(),
          ),
          historySectionsProvider.overrideWith(
            (_) async => <SessionHistorySeasonSection>[
              SessionHistorySeasonSection(
                label: '2025/2026',
                items: <SessionHistoryEntryViewModel>[
                  SessionHistoryEntryViewModel(
                    session: session,
                    resortLabel: 'Whistler Blackcomb',
                  ),
                ],
              ),
            ],
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
    expect(find.textContaining('Pending'), findsOneWidget);
    expect(find.byTooltip('Sync now'), findsOneWidget);
    expect(find.byTooltip('Session actions'), findsNothing);
  });
}
