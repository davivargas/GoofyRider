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
    maxSpeedMps: 10,
    avgSpeedMps: 8,
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
        _buildSession(localId: 1, state: LocalSessionState.syncPending, remoteId: 'remote-1'),
        _buildSession(localId: 1, state: LocalSessionState.syncing, remoteId: 'remote-1'),
        _buildSession(localId: 1, state: LocalSessionState.synced, remoteId: 'remote-1'),
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
    when(() => localDatabase.incrementSyncAttempt(any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(), onlyAccepted: any(named: 'onlyAccepted')))
        .thenAnswer(
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
        _buildSession(localId: 1, state: LocalSessionState.syncPending, remoteId: 'remote-1'),
        _buildSession(localId: 1, state: LocalSessionState.syncing, remoteId: 'remote-1'),
        _buildSession(localId: 1, state: LocalSessionState.syncFailed, remoteId: 'remote-1'),
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
    when(() => localDatabase.incrementSyncAttempt(any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(), onlyAccepted: any(named: 'onlyAccepted')))
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
        _buildSession(localId: 1, state: LocalSessionState.syncPending, remoteId: 'remote-1'),
        _buildSession(localId: 1, state: LocalSessionState.syncing, remoteId: 'remote-1'),
        _buildSession(localId: 1, state: LocalSessionState.syncFailed, remoteId: 'remote-1'),
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
    when(() => localDatabase.incrementSyncAttempt(any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(), onlyAccepted: any(named: 'onlyAccepted')))
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

  test('appendLocationPoint queries only latest accepted point', () async {
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
    );

    when(() => localDatabase.getSessionById(1))
        .thenAnswer((_) async => recordingSession);
    when(() => localDatabase.latestAcceptedPoint(1))
        .thenAnswer((_) async => null);
    when(
      () => localDatabase.insertPoint(
        localSessionId: any(named: 'localSessionId'),
        point: any(named: 'point'),
      ),
    ).thenAnswer((_) async {});

    await repository.appendLocationPoint(1, point);

    verify(() => localDatabase.latestAcceptedPoint(1)).called(1);
    verifyNever(() => localDatabase.listPoints(any(), onlyAccepted: true));
  });
}
