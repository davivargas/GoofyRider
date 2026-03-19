import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';
import 'package:goofyrider_mobile/features/session/data/session_api.dart';
import 'package:goofyrider_mobile/features/session/data/session_repository_impl.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';

class MockDriftLocalDatabase extends Mock implements DriftLocalDatabase {}

class MockSessionApi extends Mock implements SessionApi {}

class FakeNewSessionPoint extends Fake implements NewSessionPoint {}

LocalRideSession _buildSession({
  required int localId,
  required LocalSessionState state,
  String? remoteId,
  double maxSpeedMps = 10,
  double avgSpeedMps = 8,
}) {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: localId,
    remoteId: remoteId,
    resortId: null,
    startedAt: now,
    endedAt: now,
    activeDurationS: 120,
    distanceM: 1000,
    maxSpeedMps: maxSpeedMps,
    avgSpeedMps: avgSpeedMps,
    elevationGainM: 10,
    elevationLossM: 100,
    state: state,
    pointCount: 0,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: now,
    updatedAt: now,
  );
}

LocalSessionPoint _buildPoint({
  required int offsetMs,
}) {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return LocalSessionPoint(
    id: offsetMs,
    localSessionId: 1,
    recordedAt: now.add(Duration(milliseconds: offsetMs)),
    tOffsetMs: offsetMs,
    latitude: 49.0 + (offsetMs / 1000000),
    longitude: -123.0 - (offsetMs / 1000000),
    accuracyM: 8,
    altitudeM: 500,
    speedMps: 7,
    headingDeg: 90,
    acceptedForAnalytics: true,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeNewSessionPoint());
    registerFallbackValue(LocalSessionState.syncPending);
  });

  late MockDriftLocalDatabase localDatabase;
  late MockSessionApi api;
  late SessionRepositoryImpl repository;

  setUp(() {
    localDatabase = MockDriftLocalDatabase();
    api = MockSessionApi();
    repository = SessionRepositoryImpl(localDatabase: localDatabase, api: api);
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

    when(() => localDatabase.getSessionById(1))
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

    when(() => localDatabase.getSessionById(1))
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

    when(() => localDatabase.getSessionById(1))
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

    when(() => localDatabase.getSessionById(1))
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

    when(() => localDatabase.getSessionById(1))
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
}
