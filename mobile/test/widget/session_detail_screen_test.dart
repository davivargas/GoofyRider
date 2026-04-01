import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_detail_screen.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';

class FakeSessionRepository implements SessionRepository {
  FakeSessionRepository(this.detail);

  final SessionDetail detail;
  final List<int> syncedSessionIds = <int>[];

  @override
  Future<void> appendLocationPoint(
    int localSessionId,
    NewSessionPoint point,
  ) async {}

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async =>
      detail.stats;

  @override
  Future<LocalRideSession> finishLocalSession(
    int localSessionId, {
    int? activeDurationS,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SessionDetail> getSessionDetail(int localSessionId) async => detail;

  @override
  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit = 120,
  }) async {
    return const <TrackingDiagnosticEvent>[];
  }

  @override
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async =>
      const <LocalRideSession>[];

  @override
  Future<List<LocalRideSession>> listPendingSyncSessions() async =>
      const <LocalRideSession>[];

  @override
  Future<void> refreshRemoteSessionHistoryCache() async {}

  @override
  Future<LocalRideSession> pauseLocalSession(int localSessionId) async {
    throw UnimplementedError();
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
    syncedSessionIds.add(localSessionId);
    return detail.session;
  }

  @override
  Future<int> unsyncedCount() async => 0;
}

LocalRideSession _buildSession() {
  final DateTime now = DateTime.utc(2026, 1, 1, 9, 0, 0);
  return LocalRideSession(
    localId: 1,
    ownerUserId: 'user-1',
    remoteId: 'remote-1',
    resortId: 'whistler',
    startedAt: now,
    endedAt: now.add(const Duration(minutes: 10)),
    activeDurationS: 600,
    distanceM: 2000,
    maxSpeedMps: 18,
    avgSpeedMps: 11,
    elevationGainM: 0,
    elevationLossM: 0,
    state: LocalSessionState.synced,
    pointCount: 6,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: now,
    updatedAt: now,
  );
}

LocalSessionPoint _point({
  required int id,
  required int offsetS,
  required double latitude,
  required double longitude,
  required String motionState,
}) {
  final DateTime startedAt = DateTime.utc(2026, 1, 1, 9, 0, 0);
  final DateTime recordedAt = startedAt.add(Duration(seconds: offsetS));
  return LocalSessionPoint(
    id: id,
    localSessionId: 1,
    recordedAt: recordedAt,
    tOffsetMs: offsetS * 1000,
    latitude: latitude,
    longitude: longitude,
    accuracyM: 8,
    altitudeM: 1000 - (offsetS * 4).toDouble(),
    speedMps: motionState == 'lift_uphill' ? 3 : 11,
    headingDeg: 90,
    acceptedForAnalytics: true,
    qualityClass: 'accept',
    qualityScore: 0.95,
    qualityReason: 'accepted',
    filteredLatitude: latitude,
    filteredLongitude: longitude,
    filteredAltitudeM: 1000 - (offsetS * 4).toDouble(),
    fusedSpeedMps: motionState == 'lift_uphill' ? 3 : 11,
    derivedSpeedMps: motionState == 'lift_uphill' ? 3 : 11,
    distanceDeltaM: 20,
    motionState: motionState,
  );
}

SessionDetail _buildSegmentedDetail() {
  final LocalRideSession session = _buildSession();
  final List<LocalSessionPoint> points = <LocalSessionPoint>[
    _point(
      id: 1,
      offsetS: 0,
      latitude: 50.0,
      longitude: -123.0,
      motionState: 'active_descent',
    ),
    _point(
      id: 2,
      offsetS: 120,
      latitude: 50.002,
      longitude: -123.01,
      motionState: 'active_descent',
    ),
    _point(
      id: 3,
      offsetS: 240,
      latitude: 50.01,
      longitude: -123.02,
      motionState: 'lift_uphill',
    ),
    _point(
      id: 4,
      offsetS: 360,
      latitude: 50.012,
      longitude: -123.018,
      motionState: 'lift_uphill',
    ),
    _point(
      id: 5,
      offsetS: 480,
      latitude: 50.013,
      longitude: -123.017,
      motionState: 'stopped_idle',
    ),
    _point(
      id: 6,
      offsetS: 600,
      latitude: 50.0135,
      longitude: -123.017,
      motionState: 'stopped_idle',
    ),
  ];

  const SessionStats stats = SessionStats(
    durationS: 600,
    distanceM: 120,
    maxSpeedMps: 18,
    avgSpeedMps: 11,
    elevationGainM: 0,
    elevationLossM: 0,
    descentDurationS: 240,
    liftDurationS: 240,
    idleDurationS: 120,
    descentDistanceM: 60,
    liftDistanceM: 40,
    idleDistanceM: 20,
  );

  final List<SessionTimelineSegment> timeline = <SessionTimelineSegment>[
    SessionTimelineSegment(
      type: SessionActivityType.descent,
      startedAt: points[0].recordedAt,
      endedAt: points[1].recordedAt,
      startOffsetMs: points[0].tOffsetMs,
      endOffsetMs: points[1].tOffsetMs,
      durationS: 120,
      distanceM: 40,
      points: List<LocalSessionPoint>.unmodifiable(points.sublist(0, 2)),
    ),
    SessionTimelineSegment(
      type: SessionActivityType.lift,
      startedAt: points[2].recordedAt,
      endedAt: points[3].recordedAt,
      startOffsetMs: points[2].tOffsetMs,
      endOffsetMs: points[3].tOffsetMs,
      durationS: 120,
      distanceM: 40,
      points: List<LocalSessionPoint>.unmodifiable(points.sublist(2, 4)),
    ),
    SessionTimelineSegment(
      type: SessionActivityType.idle,
      startedAt: points[4].recordedAt,
      endedAt: points[5].recordedAt,
      startOffsetMs: points[4].tOffsetMs,
      endOffsetMs: points[5].tOffsetMs,
      durationS: 120,
      distanceM: 20,
      points: List<LocalSessionPoint>.unmodifiable(points.sublist(4, 6)),
    ),
  ];

  return SessionDetail(
    session: session,
    points: points,
    acceptedPoints: points,
    trackingDiagnostics: const <TrackingDiagnosticEvent>[],
    stats: stats,
    timeline: timeline,
  );
}

SessionDetail _buildLegacyDetail() {
  final LocalRideSession session = _buildSession();
  return SessionDetail(
    session: session,
    points: const <LocalSessionPoint>[],
    acceptedPoints: const <LocalSessionPoint>[],
    trackingDiagnostics: const <TrackingDiagnosticEvent>[],
    stats: SessionStats(
      durationS: session.activeDurationS,
      distanceM: session.distanceM,
      maxSpeedMps: session.maxSpeedMps,
      avgSpeedMps: session.avgSpeedMps,
      elevationGainM: session.elevationGainM,
      elevationLossM: session.elevationLossM,
    ),
    timeline: const <SessionTimelineSegment>[],
  );
}

SessionDetail _buildUnsyncedDetail() {
  final LocalRideSession session = LocalRideSession(
    localId: 1,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: 'whistler',
    startedAt: DateTime.utc(2026, 1, 1, 9, 0, 0),
    endedAt: DateTime.utc(2026, 1, 1, 9, 10, 0),
    activeDurationS: 600,
    distanceM: 2000,
    maxSpeedMps: 18,
    avgSpeedMps: 11,
    elevationGainM: 0,
    elevationLossM: 0,
    state: LocalSessionState.syncFailed,
    pointCount: 6,
    syncAttemptCount: 1,
    lastSyncError: 'network error',
    createdAt: DateTime.utc(2026, 1, 1, 9, 0, 0),
    updatedAt: DateTime.utc(2026, 1, 1, 9, 10, 0),
  );

  return SessionDetail(
    session: session,
    points: const <LocalSessionPoint>[],
    acceptedPoints: const <LocalSessionPoint>[],
    trackingDiagnostics: const <TrackingDiagnosticEvent>[],
    stats: SessionStats(
      durationS: session.activeDurationS,
      distanceM: session.distanceM,
      maxSpeedMps: session.maxSpeedMps,
      avgSpeedMps: session.avgSpeedMps,
      elevationGainM: session.elevationGainM,
      elevationLossM: session.elevationLossM,
    ),
  );
}

void main() {
  testWidgets('session detail screen renders segmented ride breakdown',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(
            FakeSessionRepository(_buildSegmentedDetail()),
          ),
        ],
        child: const MaterialApp(
          home: SessionDetailScreen(localSessionId: 1),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Session'), findsWidgets);
    expect(find.text('Ride time'), findsOneWidget);
    expect(find.text('Lift'), findsWidgets);
    expect(find.text('Idle'), findsWidgets);
    expect(find.text('Ride distance'), findsOneWidget);
    expect(find.text('Ride avg'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Timeline'),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();

    expect(find.text('Timeline'), findsOneWidget);
    expect(find.textContaining('00:02:00'), findsWidgets);
  });

  testWidgets('session detail screen falls back without timeline data',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(
            FakeSessionRepository(_buildLegacyDetail()),
          ),
        ],
        child: const MaterialApp(
          home: SessionDetailScreen(localSessionId: 1),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.text('Motion segments are not available for this session yet.'),
      findsOneWidget,
    );
    expect(find.text('Ride time'), findsOneWidget);
  });

  testWidgets('session detail screen exposes sync action for unsynced sessions',
      (WidgetTester tester) async {
    final FakeSessionRepository repository =
        FakeSessionRepository(_buildUnsyncedDetail());

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(
          home: SessionDetailScreen(localSessionId: 1),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Retry sync'),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();

    expect(find.text('Retry sync'), findsOneWidget);
    await tester.tap(find.text('Retry sync'));
    await tester.pumpAndSettle();

    expect(repository.syncedSessionIds, <int>[1]);
  });
}
