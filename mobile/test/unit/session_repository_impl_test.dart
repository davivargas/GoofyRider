import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';
import 'package:goofyrider_mobile/features/session/data/session_api.dart';
import 'package:goofyrider_mobile/features/session/data/session_repository_impl.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';

class MockDriftLocalDatabase extends Mock implements DriftLocalDatabase {}

class MockSessionApi extends Mock implements SessionApi {}

class FakeNewSessionPoint extends Fake implements NewSessionPoint {}

const String _ownerUserId = 'user-1';

LocalRideSession _buildSession({
  required int localId,
  required LocalSessionState state,
  String? remoteId,
  int activeDurationS = 120,
  double maxSpeedMps = 10,
  double avgSpeedMps = 8,
  DateTime? startedAt,
  DateTime? endedAt,
}) {
  final DateTime effectiveStartedAt = startedAt ?? DateTime.utc(2026, 1, 1);
  final DateTime effectiveEndedAt = endedAt ?? effectiveStartedAt;
  return LocalRideSession(
    localId: localId,
    ownerUserId: _ownerUserId,
    remoteId: remoteId,
    resortId: null,
    startedAt: effectiveStartedAt,
    endedAt: effectiveEndedAt,
    activeDurationS: activeDurationS,
    distanceM: 1000,
    maxSpeedMps: maxSpeedMps,
    avgSpeedMps: avgSpeedMps,
    elevationGainM: 10,
    elevationLossM: 100,
    state: state,
    pointCount: 0,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: effectiveStartedAt,
    updatedAt: effectiveEndedAt,
  );
}
LocalSessionPoint _buildPoint({
  required int offsetMs,
  double speedMps = 7,
  String qualityClass = 'accept',
  bool acceptedForAnalytics = true,
  double? fusedSpeedMps,
  double? derivedSpeedMps,
  double? distanceDeltaM,
  String? motionState,
  double? latitude,
  double? longitude,
}) {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return LocalSessionPoint(
    id: offsetMs,
    localSessionId: 1,
    recordedAt: now.add(Duration(milliseconds: offsetMs)),
    tOffsetMs: offsetMs,
    latitude: latitude ?? 49.0 + (offsetMs / 1000000),
    longitude: longitude ?? -123.0 - (offsetMs / 1000000),
    accuracyM: 8,
    altitudeM: 500,
    speedMps: speedMps,
    headingDeg: 90,
    acceptedForAnalytics: acceptedForAnalytics,
    qualityClass: qualityClass,
    fusedSpeedMps: fusedSpeedMps ?? speedMps,
    derivedSpeedMps: derivedSpeedMps,
    distanceDeltaM: distanceDeltaM,
    motionState: motionState,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeNewSessionPoint());
    registerFallbackValue(<NewSessionPoint>[FakeNewSessionPoint()]);
    registerFallbackValue(LocalSessionState.syncPending);
  });

  late MockDriftLocalDatabase localDatabase;
  late MockSessionApi api;
  late SessionRepositoryImpl repository;

  setUp(() {
    localDatabase = MockDriftLocalDatabase();
    api = MockSessionApi();
    repository = SessionRepositoryImpl(
      localDatabase: localDatabase,
      api: api,
      currentUserIdGetter: () => _ownerUserId,
    );
  });

  test('startLocalSession persists the authenticated owner id', () async {
    final LocalRideSession created = _buildSession(
      localId: 7,
      state: LocalSessionState.recording,
    );

    when(() => localDatabase.insertLocalSession(
          startedAt: any(named: 'startedAt'),
          ownerUserId: any(named: 'ownerUserId'),
          resortId: any(named: 'resortId'),
        )).thenAnswer((_) async => 7);
    when(() => localDatabase.getSessionById(7, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => created);

    final LocalRideSession result =
        await repository.startLocalSession(resortId: 'resort-1');

    expect(result.ownerUserId, _ownerUserId);
    verify(() => localDatabase.insertLocalSession(
          startedAt: any(named: 'startedAt'),
          ownerUserId: _ownerUserId,
          resortId: 'resort-1',
        )).called(1);
  });

  test('syncSession dedupes duplicate offsets before upload batches', () async {
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncPending,
            remoteId: 'remote-1'),
        _buildSession(
            localId: 1, state: LocalSessionState.syncing, remoteId: 'remote-1'),
        _buildSession(
            localId: 1, state: LocalSessionState.synced, remoteId: 'remote-1'),
      ],
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => sessions.removeFirst());
    when(
      () => localDatabase.updateSessionState(
        any(),
        any(),
        remoteId: any(named: 'remoteId'),
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.incrementSyncAttempt(any(),
        error: any(named: 'error'))).thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(),
        onlyAccepted: any(named: 'onlyAccepted'))).thenAnswer(
      (_) async => <LocalSessionPoint>[
        _buildPoint(offsetMs: 0),
        _buildPoint(offsetMs: 0),
        _buildPoint(offsetMs: 1000),
      ],
    );
    when(() => api.getRemoteSessionPoints(any()))
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => api.uploadPointBatch(
          remoteSessionId: any(named: 'remoteSessionId'),
          points: any(named: 'points'),
        )).thenAnswer((_) async {});
    when(() => api.completeRemoteSession(
          remoteSessionId: any(named: 'remoteSessionId'),
          endedAt: any(named: 'endedAt'),
          durationS: any(named: 'durationS'),
          distanceM: any(named: 'distanceM'),
          maxSpeedMps: any(named: 'maxSpeedMps'),
          avgSpeedMps: any(named: 'avgSpeedMps'),
          elevationGainM: any(named: 'elevationGainM'),
          elevationLossM: any(named: 'elevationLossM'),
        )).thenAnswer((_) async => <String, dynamic>{'id': 'remote-1'});

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<dynamic> captured = verify(
      () => api.uploadPointBatch(
        remoteSessionId: 'remote-1',
        points: captureAny(named: 'points'),
      ),
    ).captured;
    final List<Map<String, dynamic>> uploaded =
        captured.single as List<Map<String, dynamic>>;

    expect(uploaded.length, 2);
    expect(
      uploaded.map((Map<String, dynamic> p) => p['t_offset_ms'] as int).toSet(),
      <int>{0, 1000},
    );
  });

  test('syncSession marks session as syncFailed when upload fails', () async {
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncPending,
            remoteId: 'remote-1'),
        _buildSession(
            localId: 1, state: LocalSessionState.syncing, remoteId: 'remote-1'),
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncFailed,
            remoteId: 'remote-1'),
      ],
    );
    final DioException syncFailure = DioException(
      requestOptions: RequestOptions(path: '/sessions/remote-1/points:batch'),
      type: DioExceptionType.connectionError,
      message: 'Network unavailable',
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => sessions.removeFirst());
    when(
      () => localDatabase.updateSessionState(
        any(),
        any(),
        remoteId: any(named: 'remoteId'),
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.incrementSyncAttempt(any(),
        error: any(named: 'error'))).thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(),
            onlyAccepted: any(named: 'onlyAccepted')))
        .thenAnswer((_) async => <LocalSessionPoint>[_buildPoint(offsetMs: 0)]);
    when(() => api.getRemoteSessionPoints(any()))
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => api.uploadPointBatch(
          remoteSessionId: any(named: 'remoteSessionId'),
          points: any(named: 'points'),
        )).thenThrow(syncFailure);

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.syncFailed);
    verify(
      () => localDatabase.updateSessionState(
        1,
        LocalSessionState.syncFailed,
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).called(1);
  });

  test('syncSession marks session as syncFailed when upload token is expired',
      () async {
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncPending,
            remoteId: 'remote-1'),
        _buildSession(
            localId: 1, state: LocalSessionState.syncing, remoteId: 'remote-1'),
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncFailed,
            remoteId: 'remote-1'),
      ],
    );
    final RequestOptions requestOptions =
        RequestOptions(path: '/sessions/remote-1/points:batch');
    final DioException authFailure = DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 401,
        data: <String, dynamic>{'detail': 'Authentication required.'},
      ),
      type: DioExceptionType.badResponse,
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => sessions.removeFirst());
    when(
      () => localDatabase.updateSessionState(
        any(),
        any(),
        remoteId: any(named: 'remoteId'),
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.incrementSyncAttempt(any(),
        error: any(named: 'error'))).thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(),
            onlyAccepted: any(named: 'onlyAccepted')))
        .thenAnswer((_) async => <LocalSessionPoint>[_buildPoint(offsetMs: 0)]);
    when(() => api.getRemoteSessionPoints(any()))
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => api.uploadPointBatch(
          remoteSessionId: any(named: 'remoteSessionId'),
          points: any(named: 'points'),
        )).thenThrow(authFailure);

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.syncFailed);
    verify(
      () => localDatabase.updateSessionState(
        1,
        LocalSessionState.syncFailed,
        lastSyncError: 'Authentication required.',
      ),
    ).called(1);
  });

  test('appendLocationPoint persists enriched point payload as-is', () async {
    final LocalRideSession recordingSession =
        _buildSession(localId: 1, state: LocalSessionState.recording);
    final NewSessionPoint point = NewSessionPoint(
      recordedAt: DateTime.utc(2026, 1, 1, 0, 0, 5),
      tOffsetMs: 5000,
      latitude: 49.1,
      longitude: -123.1,
      accuracyM: 6,
      altitudeM: 520,
      speedMps: 8,
      headingDeg: 90,
      acceptedForAnalytics: true,
      qualityClass: 'accept',
      qualityReason: 'accepted',
      qualityScore: 0.9,
      fusedSpeedMps: 8,
      derivedSpeedMps: 7.8,
      distanceDeltaM: 22,
      motionState: 'active_descent',
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => recordingSession);
    when(
      () => localDatabase.insertPoint(
        localSessionId: any(named: 'localSessionId'),
        point: any(named: 'point'),
      ),
    ).thenAnswer((_) async {});

    await repository.appendLocationPoint(1, point);

    verify(
      () => localDatabase.insertPoint(
        localSessionId: 1,
        point: point,
      ),
    ).called(1);
  });

  test('computeSessionStats preserves duration from sub-second accepted points',
      () async {
    when(() => localDatabase.listPoints(1)).thenAnswer(
      (_) async => <LocalSessionPoint>[
        _buildPoint(offsetMs: 0),
        _buildPoint(offsetMs: 200),
        _buildPoint(offsetMs: 400),
        _buildPoint(offsetMs: 600),
        _buildPoint(offsetMs: 800),
        _buildPoint(offsetMs: 1000),
        _buildPoint(offsetMs: 1200),
        _buildPoint(offsetMs: 1400),
        _buildPoint(offsetMs: 1600),
        _buildPoint(offsetMs: 1800),
      ],
    );

    final SessionStats stats = await repository.computeSessionStats(1);

    expect(stats.durationS, 2);
    expect(stats.maxSpeedMps, greaterThan(0));
  });


  test('computeSessionStats resists single accepted max-speed spikes',
      () async {
    when(() => localDatabase.listPoints(1)).thenAnswer(
      (_) async => <LocalSessionPoint>[
        _buildPoint(offsetMs: 0, speedMps: 12, distanceDeltaM: 0),
        _buildPoint(offsetMs: 1000, speedMps: 12, distanceDeltaM: 12),
        _buildPoint(offsetMs: 2000, speedMps: 12, distanceDeltaM: 12),
        _buildPoint(offsetMs: 3000, speedMps: 32, distanceDeltaM: 12),
        _buildPoint(offsetMs: 4000, speedMps: 12, distanceDeltaM: 12),
        _buildPoint(offsetMs: 5000, speedMps: 12, distanceDeltaM: 12),
      ],
    );

    final SessionStats stats = await repository.computeSessionStats(1);

    expect(stats.maxSpeedMps, greaterThan(10));
    expect(stats.maxSpeedMps, lessThan(18));
  });

  test('syncSession clamps completion max speed to be at least average speed',
      () async {
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(
          localId: 1,
          state: LocalSessionState.syncPending,
          remoteId: 'remote-1',
          maxSpeedMps: 0,
          avgSpeedMps: 9,
        ),
        _buildSession(
          localId: 1,
          state: LocalSessionState.syncing,
          remoteId: 'remote-1',
          maxSpeedMps: 0,
          avgSpeedMps: 9,
        ),
        _buildSession(
          localId: 1,
          state: LocalSessionState.synced,
          remoteId: 'remote-1',
          maxSpeedMps: 0,
          avgSpeedMps: 9,
        ),
      ],
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => sessions.removeFirst());
    when(
      () => localDatabase.updateSessionState(
        any(),
        any(),
        remoteId: any(named: 'remoteId'),
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.incrementSyncAttempt(any(),
        error: any(named: 'error'))).thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(),
            onlyAccepted: any(named: 'onlyAccepted')))
        .thenAnswer((_) async => <LocalSessionPoint>[_buildPoint(offsetMs: 0)]);
    when(() => api.getRemoteSessionPoints(any()))
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(() => api.uploadPointBatch(
          remoteSessionId: any(named: 'remoteSessionId'),
          points: any(named: 'points'),
        )).thenAnswer((_) async {});
    when(() => api.completeRemoteSession(
          remoteSessionId: any(named: 'remoteSessionId'),
          endedAt: any(named: 'endedAt'),
          durationS: any(named: 'durationS'),
          distanceM: any(named: 'distanceM'),
          maxSpeedMps: any(named: 'maxSpeedMps'),
          avgSpeedMps: any(named: 'avgSpeedMps'),
          elevationGainM: any(named: 'elevationGainM'),
          elevationLossM: any(named: 'elevationLossM'),
        )).thenAnswer((_) async => <String, dynamic>{'id': 'remote-1'});

    await repository.syncSession(1);

    final List<dynamic> completeCaptured = verify(
      () => api.completeRemoteSession(
        remoteSessionId: 'remote-1',
        endedAt: any(named: 'endedAt'),
        durationS: any(named: 'durationS'),
        distanceM: any(named: 'distanceM'),
        maxSpeedMps: captureAny(named: 'maxSpeedMps'),
        avgSpeedMps: captureAny(named: 'avgSpeedMps'),
        elevationGainM: any(named: 'elevationGainM'),
        elevationLossM: any(named: 'elevationLossM'),
      ),
    ).captured;

    final double capturedMaxSpeed = completeCaptured[0] as double;
    final double capturedAvgSpeed = completeCaptured[1] as double;
    expect(capturedMaxSpeed, greaterThanOrEqualTo(capturedAvgSpeed));
    expect(capturedAvgSpeed, 9);
  });

  test('history uses scoped local rows and cached remote rows offline',
      () async {
    final Queue<List<LocalRideSession>> localSnapshots =
        Queue<List<LocalRideSession>>.from(
      <List<LocalRideSession>>[
        <LocalRideSession>[
          _buildSession(
            localId: 1,
            state: LocalSessionState.syncPending,
            remoteId: 'remote-1',
            startedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        <LocalRideSession>[
          _buildSession(
            localId: 2,
            state: LocalSessionState.synced,
            remoteId: 'remote-2',
            startedAt: DateTime.utc(2026, 1, 2),
          ),
          _buildSession(
            localId: 1,
            state: LocalSessionState.syncPending,
            remoteId: 'remote-1',
            startedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      ],
    );
    when(() => localDatabase.listSessions(ownerUserId: _ownerUserId))
        .thenAnswer((_) async => localSnapshots.removeFirst());
    when(() =>
            localDatabase.readCachedRemoteSessions(ownerUserId: _ownerUserId))
        .thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'remote-1',
          'started_at': '2026-01-01T00:00:00Z',
          'ended_at': '2026-01-01T00:10:00Z',
          'duration_s': 600,
          'distance_m': 1500,
          'max_speed_mps': 10,
          'avg_speed_mps': 8,
        },
        <String, dynamic>{
          'id': 'remote-2',
          'started_at': '2026-01-02T00:00:00Z',
          'ended_at': '2026-01-02T00:10:00Z',
          'duration_s': 600,
          'distance_m': 1800,
          'max_speed_mps': 12,
          'avg_speed_mps': 9,
        },
      ],
    );
    when(
      () => localDatabase.upsertRemoteSessionSummary(
        ownerUserId: any(named: 'ownerUserId'),
        remoteId: any(named: 'remoteId'),
        startedAt: any(named: 'startedAt'),
        endedAt: any(named: 'endedAt'),
        activeDurationS: any(named: 'activeDurationS'),
        distanceM: any(named: 'distanceM'),
        maxSpeedMps: any(named: 'maxSpeedMps'),
        avgSpeedMps: any(named: 'avgSpeedMps'),
        elevationGainM: any(named: 'elevationGainM'),
        elevationLossM: any(named: 'elevationLossM'),
        resortId: any(named: 'resortId'),
        createdAt: any(named: 'createdAt'),
      ),
    ).thenAnswer((Invocation invocation) async {
      final String remoteId = invocation.namedArguments[#remoteId] as String;
      return remoteId == 'remote-1' ? 1 : 2;
    });
    when(() => api.listRemoteSessions())
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(
      () => localDatabase.replaceCachedRemoteSessions(
        ownerUserId: _ownerUserId,
        sessions: any(named: 'sessions'),
      ),
    ).thenAnswer((_) async {});

    final List<LocalRideSession> history =
        await repository.listLocalAndRemoteSessionHistory();

    expect(history.map((LocalRideSession item) => item.remoteId), <String?>[
      'remote-2',
      'remote-1',
    ]);
    expect(history.every((LocalRideSession item) => item.localId > 0), isTrue);
  });

  test('history rebuild hydrates fresh-install remote sessions into local rows',
      () async {
    final Map<String, dynamic> remoteSummary = <String, dynamic>{
      'id': 'remote-7',
      'status': 'COMPLETED',
      'started_at': '2026-01-03T00:00:00Z',
      'ended_at': '2026-01-03T00:12:00Z',
      'duration_s': 720,
      'distance_m': 2100,
      'max_speed_mps': 14,
      'avg_speed_mps': 8,
      'created_at': '2026-01-03T00:12:05Z',
    };
    final Queue<List<LocalRideSession>> localSnapshots =
        Queue<List<LocalRideSession>>.from(
      <List<LocalRideSession>>[
        const <LocalRideSession>[],
        <LocalRideSession>[
          _buildSession(
            localId: 7,
            state: LocalSessionState.synced,
            remoteId: 'remote-7',
            activeDurationS: 720,
            maxSpeedMps: 14,
            avgSpeedMps: 8,
          ),
        ],
      ],
    );
    final Queue<List<Map<String, dynamic>>> remoteSnapshots =
        Queue<List<Map<String, dynamic>>>.from(
      <List<Map<String, dynamic>>>[
        const <Map<String, dynamic>>[],
        <Map<String, dynamic>>[remoteSummary],
      ],
    );

    when(() => localDatabase.listSessions(ownerUserId: _ownerUserId))
        .thenAnswer((_) async => localSnapshots.removeFirst());
    when(() =>
            localDatabase.readCachedRemoteSessions(ownerUserId: _ownerUserId))
        .thenAnswer((_) async => remoteSnapshots.removeFirst());
    when(() => api.listRemoteSessions())
        .thenAnswer((_) async => <Map<String, dynamic>>[remoteSummary]);
    when(
      () => localDatabase.replaceCachedRemoteSessions(
        ownerUserId: _ownerUserId,
        sessions: any(named: 'sessions'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.upsertRemoteSessionSummary(
        ownerUserId: any(named: 'ownerUserId'),
        remoteId: any(named: 'remoteId'),
        startedAt: any(named: 'startedAt'),
        endedAt: any(named: 'endedAt'),
        activeDurationS: any(named: 'activeDurationS'),
        distanceM: any(named: 'distanceM'),
        maxSpeedMps: any(named: 'maxSpeedMps'),
        avgSpeedMps: any(named: 'avgSpeedMps'),
        elevationGainM: any(named: 'elevationGainM'),
        elevationLossM: any(named: 'elevationLossM'),
        resortId: any(named: 'resortId'),
        createdAt: any(named: 'createdAt'),
      ),
    ).thenAnswer((_) async => 7);

    final List<LocalRideSession> history =
        await repository.listLocalAndRemoteSessionHistory();

    expect(history, hasLength(1));
    expect(history.single.localId, 7);
    expect(history.single.remoteId, 'remote-7');
    verify(
      () => localDatabase.upsertRemoteSessionSummary(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-7',
        startedAt: DateTime.utc(2026, 1, 3, 0, 0, 0),
        endedAt: DateTime.utc(2026, 1, 3, 0, 12, 0),
        activeDurationS: 720,
        distanceM: 2100,
        maxSpeedMps: 14,
        avgSpeedMps: 8,
        elevationGainM: null,
        elevationLossM: null,
        resortId: null,
        createdAt: DateTime.utc(2026, 1, 3, 0, 12, 5),
      ),
    ).called(1);
  });

}