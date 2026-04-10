import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:goofyrider_mobile/core/errors/failures.dart';
import 'package:goofyrider_mobile/core/network/api_error.dart';
import 'package:goofyrider_mobile/core/network/auth_token_interceptor.dart';
import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';
import 'package:goofyrider_mobile/features/session/data/session_api.dart';
import 'package:goofyrider_mobile/features/session/data/session_repository_impl.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';

class MockDriftLocalDatabase extends Mock implements DriftLocalDatabase {}

class MockSessionApi extends Mock implements SessionApi {}

class _SessionSyncRetryBackendInterceptor extends Interceptor {
  int uploadAttempts = 0;
  int completeAttempts = 0;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    if (options.path == '/sessions/remote-1/points' &&
        options.method.toUpperCase() == 'GET') {
      handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: <String, dynamic>{'items': <dynamic>[]},
        ),
      );
      return;
    }

    if (options.path == '/sessions/remote-1/points:batch' &&
        options.method.toUpperCase() == 'POST') {
      uploadAttempts += 1;
      final String? authorization = options.headers['Authorization'] as String?;
      if (authorization == 'Bearer expired-access-token') {
        handler.reject(_unauthorized(options), true);
        return;
      }
      if (authorization == 'Bearer refreshed-access-token') {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
          ),
        );
        return;
      }
    }

    if (options.path == '/sessions/remote-1/complete' &&
        options.method.toUpperCase() == 'POST') {
      completeAttempts += 1;
      final String? authorization = options.headers['Authorization'] as String?;
      if (authorization == 'Bearer refreshed-access-token') {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{'id': 'remote-1'},
          ),
        );
        return;
      }
    }

    handler.reject(
      DioException(
        requestOptions: options,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: 500,
          data: <String, dynamic>{'detail': 'Unexpected test request.'},
        ),
        type: DioExceptionType.badResponse,
      ),
      true,
    );
  }

  DioException _unauthorized(RequestOptions options) {
    return DioException(
      requestOptions: options,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: 401,
        data: <String, dynamic>{'detail': 'Authentication required.'},
      ),
      type: DioExceptionType.badResponse,
    );
  }
}

class FakeNewSessionPoint extends Fake implements NewSessionPoint {}

const String _ownerUserId = 'user-1';
const String _uuidLikeRemoteSessionId = '2dc7f6ff-9ad0-4d87-b0f1-6545af670d87';

LocalRideSession _buildSession({
  required int localId,
  required LocalSessionState state,
  String? remoteId,
  String? resortId,
  int activeDurationS = 120,
  double distanceM = 1000,
  double maxSpeedMps = 10,
  double avgSpeedMps = 8,
  int? elevationGainM = 10,
  int? elevationLossM = 100,
  int syncAttemptCount = 0,
  String? lastSyncError,
  DateTime? startedAt,
  DateTime? endedAt,
}) {
  final DateTime effectiveStartedAt = startedAt ?? DateTime.utc(2026, 1, 1);
  final DateTime effectiveEndedAt = endedAt ?? effectiveStartedAt;
  return LocalRideSession(
    localId: localId,
    ownerUserId: _ownerUserId,
    remoteId: remoteId,
    resortId: resortId,
    startedAt: effectiveStartedAt,
    endedAt: effectiveEndedAt,
    activeDurationS: activeDurationS,
    distanceM: distanceM,
    maxSpeedMps: maxSpeedMps,
    avgSpeedMps: avgSpeedMps,
    elevationGainM: elevationGainM,
    elevationLossM: elevationLossM,
    state: state,
    pointCount: 0,
    syncAttemptCount: syncAttemptCount,
    lastSyncError: lastSyncError,
    createdAt: effectiveStartedAt,
    updatedAt: effectiveEndedAt,
  );
}

LocalSessionPoint _buildPoint({
  required int offsetMs,
  double speedMps = 7,
  double? headingDeg = 90,
  String qualityClass = 'accept',
  bool acceptedForAnalytics = true,
  double? speedAccuracyMps,
  double? fusedSpeedMps,
  double? derivedSpeedMps,
  double? distanceDeltaM,
  String? motionState,
  double? latitude,
  double? longitude,
  double? altitudeM = 500,
  double? filteredAltitudeM,
  double? filteredLatitude,
  double? filteredLongitude,
  double? qualityScore,
  String? provider,
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
    altitudeM: altitudeM,
    speedMps: speedMps,
    headingDeg: headingDeg,
    acceptedForAnalytics: acceptedForAnalytics,
    speedAccuracyMps: speedAccuracyMps,
    provider: provider,
    qualityClass: qualityClass,
    qualityScore: qualityScore,
    filteredAltitudeM: filteredAltitudeM,
    filteredLatitude: filteredLatitude,
    filteredLongitude: filteredLongitude,
    fusedSpeedMps: fusedSpeedMps ?? speedMps,
    derivedSpeedMps: derivedSpeedMps,
    distanceDeltaM: distanceDeltaM,
    motionState: motionState,
  );
}

LocalRideSession _copySessionWithState(
  LocalRideSession source, {
  required LocalSessionState state,
  String? lastSyncError,
}) {
  return LocalRideSession(
    localId: source.localId,
    ownerUserId: source.ownerUserId,
    remoteId: source.remoteId,
    resortId: source.resortId,
    startedAt: source.startedAt,
    endedAt: source.endedAt,
    activeDurationS: source.activeDurationS,
    distanceM: source.distanceM,
    maxSpeedMps: source.maxSpeedMps,
    avgSpeedMps: source.avgSpeedMps,
    elevationGainM: source.elevationGainM,
    elevationLossM: source.elevationLossM,
    state: state,
    pointCount: source.pointCount,
    syncAttemptCount: source.syncAttemptCount,
    lastSyncError: lastSyncError,
    createdAt: source.createdAt,
    updatedAt: source.updatedAt,
  );
}

Queue<LocalRideSession?> _buildSyncLifecycle(LocalRideSession seed) {
  return Queue<LocalRideSession?>.from(
    <LocalRideSession?>[
      _copySessionWithState(seed, state: LocalSessionState.syncPending),
      _copySessionWithState(seed, state: LocalSessionState.syncing),
      _copySessionWithState(seed, state: LocalSessionState.syncing),
      _copySessionWithState(seed, state: LocalSessionState.synced),
    ],
  );
}

T _popOrPeekLast<T>(Queue<T> queue) {
  if (queue.isEmpty) {
    throw StateError('Test queue exhausted.');
  }
  if (queue.length == 1) {
    return queue.first;
  }
  return queue.removeFirst();
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeNewSessionPoint());
    registerFallbackValue(<NewSessionPoint>[FakeNewSessionPoint()]);
    registerFallbackValue(LocalSessionState.syncPending);
    registerFallbackValue(SessionStats.zero);
  });

  late MockDriftLocalDatabase localDatabase;
  late MockSessionApi api;
  late SessionRepositoryImpl repository;

  setUp(() {
    localDatabase = MockDriftLocalDatabase();
    api = MockSessionApi();
    when(() => localDatabase.beginSyncAttempt(any())).thenAnswer((_) async {});
    when(() => localDatabase.readCachedResorts())
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(
      () => localDatabase.listPendingRemoteSessionDeleteIds(
        ownerUserId: any(named: 'ownerUserId'),
      ),
    ).thenAnswer((_) async => <String>{});
    when(
      () => localDatabase.listPendingRemoteDeleteIds(
        ownerUserId: any(named: 'ownerUserId'),
      ),
    ).thenAnswer((_) async => <String>[]);
    when(
      () => localDatabase.listRetryablePendingRemoteDeletes(
        ownerUserId: any(named: 'ownerUserId'),
      ),
    ).thenAnswer((_) async => const <PendingRemoteSessionDeleteEntry>[]);
    when(
      () => localDatabase.enqueuePendingRemoteSessionDelete(
        ownerUserId: any(named: 'ownerUserId'),
        remoteId: any(named: 'remoteId'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.recordPendingRemoteSessionDeleteAttempt(
        ownerUserId: any(named: 'ownerUserId'),
        remoteId: any(named: 'remoteId'),
        lastError: any(named: 'lastError'),
        nextAttemptAt: any(named: 'nextAttemptAt'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.markPendingRemoteSessionDeleteFailed(
        ownerUserId: any(named: 'ownerUserId'),
        remoteId: any(named: 'remoteId'),
        lastError: any(named: 'lastError'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.clearPendingRemoteSessionDelete(
        ownerUserId: any(named: 'ownerUserId'),
        remoteId: any(named: 'remoteId'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.incrementSyncAttempt(any(),
        error: any(named: 'error'))).thenAnswer((_) async {});
    when(() => localDatabase.markSyncFailed(any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
    repository = SessionRepositoryImpl(
      localDatabase: localDatabase,
      api: api,
      currentUserIdGetter: () => _ownerUserId,
    );
  });

  void stubSyncHappyPath({
    required Queue<LocalRideSession?> sessions,
    required List<LocalSessionPoint> points,
    Future<void> Function(List<Map<String, dynamic>> batch)? onUploadBatch,
  }) {
    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => _popOrPeekLast(sessions));
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
        .thenAnswer((_) async => points);
    when(
      () => localDatabase.insertTrackingDiagnostic(
        localSessionId: any(named: 'localSessionId'),
        eventType: any(named: 'eventType'),
        message: any(named: 'message'),
        details: any(named: 'details'),
      ),
    ).thenAnswer((_) async {});
    when(() => api.uploadPointBatch(
          remoteSessionId: any(named: 'remoteSessionId'),
          points: any(named: 'points'),
        )).thenAnswer((Invocation invocation) async {
      if (onUploadBatch == null) {
        return;
      }
      final List<Map<String, dynamic>> batch =
          (invocation.namedArguments[#points] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      await onUploadBatch(batch);
    });
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
  }

  List<Map<String, dynamic>> captureUploadedPoints() {
    final List<dynamic> captured = verify(
      () => api.uploadPointBatch(
        remoteSessionId: any(named: 'remoteSessionId'),
        points: captureAny(named: 'points'),
      ),
    ).captured;
    final List<Map<String, dynamic>> uploaded = <Map<String, dynamic>>[];
    for (final dynamic batch in captured) {
      uploaded.addAll((batch as List<dynamic>).cast<Map<String, dynamic>>());
    }
    return uploaded;
  }

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

  test('finishLocalSession transitions directly to syncPending from recording',
      () async {
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(localId: 1, state: LocalSessionState.recording),
        _buildSession(localId: 1, state: LocalSessionState.syncPending),
      ],
    );
    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => sessions.removeFirst());
    when(() => localDatabase.listPoints(1))
        .thenAnswer((_) async => const <LocalSessionPoint>[]);
    when(
      () => localDatabase.completeLocalSession(
        localId: any(named: 'localId'),
        endedAt: any(named: 'endedAt'),
        stats: any(named: 'stats'),
        resortId: any(named: 'resortId'),
      ),
    ).thenAnswer((_) async {});

    final LocalRideSession finished =
        await repository.finishLocalSession(1, activeDurationS: 42);

    expect(finished.state, LocalSessionState.syncPending);
    final List<dynamic> captured = verify(
      () => localDatabase.completeLocalSession(
        localId: 1,
        endedAt: any(named: 'endedAt'),
        stats: captureAny(named: 'stats'),
        resortId: any(named: 'resortId'),
      ),
    ).captured;
    final SessionStats stats = captured.single as SessionStats;
    expect(stats.durationS, 42);
  });

  test('finishLocalSession transitions directly to syncPending from paused',
      () async {
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(localId: 1, state: LocalSessionState.paused),
        _buildSession(localId: 1, state: LocalSessionState.syncPending),
      ],
    );
    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => sessions.removeFirst());
    when(() => localDatabase.listPoints(1))
        .thenAnswer((_) async => const <LocalSessionPoint>[]);
    when(
      () => localDatabase.completeLocalSession(
        localId: any(named: 'localId'),
        endedAt: any(named: 'endedAt'),
        stats: any(named: 'stats'),
        resortId: any(named: 'resortId'),
      ),
    ).thenAnswer((_) async {});

    final LocalRideSession finished = await repository.finishLocalSession(1);

    expect(finished.state, LocalSessionState.syncPending);
  });

  test('legacy locallyCompleted wire value maps into syncPending', () {
    expect(
      LocalSessionStateCodec.fromWire('locallyCompleted'),
      LocalSessionState.syncPending,
    );
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
        .thenAnswer((_) async => _popOrPeekLast(sessions));
    when(
      () => localDatabase.beginSyncAttempt(any()),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.updateSessionState(
        any(),
        any(),
        remoteId: any(named: 'remoteId'),
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(),
        onlyAccepted: any(named: 'onlyAccepted'))).thenAnswer(
      (_) async => <LocalSessionPoint>[
        _buildPoint(offsetMs: 0),
        _buildPoint(offsetMs: 0),
        _buildPoint(offsetMs: 1000),
      ],
    );
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
    expect(
      uploaded.every(
          (Map<String, dynamic> point) => point['recorded_at'] is String),
      isTrue,
    );
    expect(
      uploaded.every((Map<String, dynamic> point) =>
          point['accepted_for_analytics'] == true),
      isTrue,
    );
    verifyNever(() => api.getRemoteSessionPoints(any()));
  });

  test('syncSession sanitizes negative heading_deg and still syncs', () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(offsetMs: 0, headingDeg: -15),
      ],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(uploaded, hasLength(1));
    final Object? heading = uploaded.single['heading_deg'];
    expect(
      heading == null || (heading is num && heading >= 0),
      isTrue,
    );
  });

  test('syncSession sanitizes negative speed_accuracy_mps and still syncs',
      () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(offsetMs: 0, speedAccuracyMps: -3),
      ],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(uploaded, hasLength(1));
    final Object? speedAccuracy = uploaded.single['speed_accuracy_mps'];
    expect(
      speedAccuracy == null || (speedAccuracy is num && speedAccuracy >= 0),
      isTrue,
    );
  });

  test('syncSession drops quality_score values outside backend range',
      () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(offsetMs: 0, qualityScore: 1.1),
        _buildPoint(offsetMs: 1000, qualityScore: -0.1),
        _buildPoint(offsetMs: 2000, qualityScore: 0.75),
      ],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(uploaded, hasLength(3));
    expect(uploaded[0]['quality_score'], isNull);
    expect(uploaded[1]['quality_score'], isNull);
    expect(uploaded[2]['quality_score'], 0.75);
  });

  test('syncSession drops filtered coordinates outside backend ranges',
      () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(
          offsetMs: 0,
          filteredLatitude: 91,
          filteredLongitude: -181,
        ),
        _buildPoint(
          offsetMs: 1000,
          filteredLatitude: 49.0001,
          filteredLongitude: -123.0001,
        ),
      ],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(uploaded, hasLength(2));
    expect(uploaded[0]['filtered_latitude'], isNull);
    expect(uploaded[0]['filtered_longitude'], isNull);
    expect(uploaded[1]['filtered_latitude'], 49.0001);
    expect(uploaded[1]['filtered_longitude'], -123.0001);
  });

  test('syncSession preserves negative altitude fields allowed by backend',
      () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(
          offsetMs: 0,
          altitudeM: -12.5,
          filteredAltitudeM: -13.2,
        ),
      ],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(uploaded, hasLength(1));
    expect(uploaded.single['altitude_m'], -12.5);
    expect(uploaded.single['filtered_altitude_m'], -13.2);
  });

  test('syncSession sends null resort_id when local resort id is not UUID-like',
      () async {
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(
          localId: 1,
          state: LocalSessionState.syncPending,
          remoteId: null,
          resortId: 'resort-whistler',
        ),
        _buildSession(
          localId: 1,
          state: LocalSessionState.syncing,
          remoteId: null,
          resortId: 'resort-whistler',
        ),
        _buildSession(
          localId: 1,
          state: LocalSessionState.syncing,
          remoteId: _uuidLikeRemoteSessionId,
          resortId: 'resort-whistler',
        ),
        _buildSession(
          localId: 1,
          state: LocalSessionState.synced,
          remoteId: _uuidLikeRemoteSessionId,
          resortId: 'resort-whistler',
        ),
      ],
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[_buildPoint(offsetMs: 0)],
    );
    when(() => api.createRemoteDraft(
          resortId: any(named: 'resortId'),
          startedAt: any(named: 'startedAt'),
        )).thenAnswer(
      (_) async => <String, dynamic>{'id': _uuidLikeRemoteSessionId},
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    verify(
      () => api.createRemoteDraft(
        resortId: null,
        startedAt: any(named: 'startedAt'),
      ),
    ).called(1);
  });

  test('syncSession canonicalizes vocabulary fields before upload', () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(
          offsetMs: 0,
          provider: 'FusedLocationProvider',
          qualityClass: 'ACCEPT-LOW-CONFIDENCE',
          motionState: 'ACTIVE DESCENT',
        ),
        _buildPoint(
          offsetMs: 1000,
          provider: 'satellite',
          qualityClass: 'good',
          motionState: 'moving',
        ),
      ],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(uploaded, hasLength(2));
    expect(uploaded[0]['provider'], 'fused');
    expect(uploaded[0]['quality_class'], 'accept_low_confidence');
    expect(uploaded[0]['motion_state'], 'active_descent');
    expect(uploaded[1]['provider'], 'unknown');
    expect(uploaded[1]['quality_class'], isNull);
    expect(uploaded[1]['motion_state'], isNull);
  });

  test('syncSession sanitizes negative completion metrics before complete call',
      () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
        activeDurationS: -120,
        distanceM: -900,
        maxSpeedMps: -12,
        avgSpeedMps: -6,
        elevationGainM: -15,
        elevationLossM: -35,
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[_buildPoint(offsetMs: 0)],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<dynamic> captured = verify(
      () => api.completeRemoteSession(
        remoteSessionId: 'remote-1',
        endedAt: any(named: 'endedAt'),
        durationS: captureAny(named: 'durationS'),
        distanceM: captureAny(named: 'distanceM'),
        maxSpeedMps: captureAny(named: 'maxSpeedMps'),
        avgSpeedMps: captureAny(named: 'avgSpeedMps'),
        elevationGainM: captureAny(named: 'elevationGainM'),
        elevationLossM: captureAny(named: 'elevationLossM'),
      ),
    ).captured;
    final int durationS = captured[0] as int;
    final double distanceM = (captured[1] as num).toDouble();
    final double maxSpeedMps = (captured[2] as num).toDouble();
    final double avgSpeedMps = (captured[3] as num).toDouble();
    final int? elevationGainM = captured[4] as int?;
    final int? elevationLossM = captured[5] as int?;

    expect(durationS, greaterThanOrEqualTo(0));
    expect(distanceM, greaterThanOrEqualTo(0));
    expect(avgSpeedMps, greaterThanOrEqualTo(0));
    expect(maxSpeedMps, greaterThanOrEqualTo(avgSpeedMps));
    expect(elevationGainM == null || elevationGainM >= 0, isTrue);
    expect(elevationLossM == null || elevationLossM >= 0, isTrue);
  });

  test(
      'syncSession isolates malformed point batch so valid sibling still syncs',
      () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(offsetMs: 0, latitude: double.nan),
        _buildPoint(offsetMs: 1000),
      ],
      onUploadBatch: (List<Map<String, dynamic>> batch) async {
        final bool hasMalformedRequiredCoordinates =
            batch.any((Map<String, dynamic> point) {
          final Object? latitude = point['latitude'];
          final Object? longitude = point['longitude'];
          final bool invalidLatitude = latitude is! num ||
              !latitude.toDouble().isFinite ||
              latitude < -90 ||
              latitude > 90;
          final bool invalidLongitude = longitude is! num ||
              !longitude.toDouble().isFinite ||
              longitude < -180 ||
              longitude > 180;
          return invalidLatitude || invalidLongitude;
        });
        if (!hasMalformedRequiredCoordinates) {
          return;
        }
        throw DioException(
          requestOptions:
              RequestOptions(path: '/sessions/remote-1/points:batch'),
          type: DioExceptionType.badResponse,
          message: 'Malformed point in batch payload',
        );
      },
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(
      uploaded
          .any((Map<String, dynamic> point) => point['t_offset_ms'] == 1000),
      isTrue,
    );
  });

  test('syncSession succeeds in degraded mode with invalid points dropped',
      () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(offsetMs: 0, latitude: double.nan),
        _buildPoint(offsetMs: 500, latitude: 190),
        _buildPoint(offsetMs: 1000),
      ],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(uploaded, hasLength(1));
    expect(uploaded.single['t_offset_ms'], 1000);
  });

  test('syncSession keeps saved state synced after partial point salvage',
      () async {
    final Queue<LocalRideSession?> sessions = _buildSyncLifecycle(
      _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        remoteId: 'remote-1',
      ),
    );
    stubSyncHappyPath(
      sessions: sessions,
      points: <LocalSessionPoint>[
        _buildPoint(offsetMs: 0, latitude: double.nan),
        _buildPoint(offsetMs: 1000),
      ],
    );

    final LocalRideSession result = await repository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    expect(result.lastSyncError, isNull);
    verifyNever(
      () => localDatabase.updateSessionState(
        1,
        LocalSessionState.syncFailed,
        lastSyncError: any(named: 'lastSyncError'),
      ),
    );
    final List<Map<String, dynamic>> uploaded = captureUploadedPoints();
    expect(uploaded, hasLength(1));
  });

  test('syncSession marks session as syncFailed when upload fails', () async {
    final DioException syncFailure = DioException(
      requestOptions: RequestOptions(path: '/sessions/remote-1/points:batch'),
      type: DioExceptionType.connectionError,
      message: 'Network unavailable',
    );
    final String expectedMessage = mapDioException(syncFailure).message;
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncPending,
            remoteId: 'remote-1',
            syncAttemptCount: 0),
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncing,
            remoteId: 'remote-1',
            syncAttemptCount: 1),
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncFailed,
            remoteId: 'remote-1',
            syncAttemptCount: 1,
            lastSyncError: expectedMessage),
      ],
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => _popOrPeekLast(sessions));
    when(
      () => localDatabase.beginSyncAttempt(any()),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.updateSessionState(
        any(),
        any(),
        remoteId: any(named: 'remoteId'),
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.markSyncFailed(any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
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
    expect(result.syncAttemptCount, 1);
    expect(result.lastSyncError, expectedMessage);
    verify(() => localDatabase.beginSyncAttempt(1)).called(1);
    verify(() => localDatabase.markSyncFailed(
          1,
          error: expectedMessage,
        )).called(1);
  });

  test('syncSession refreshes and retries preserved upload auth failures',
      () async {
    String currentAccessToken = 'expired-access-token';
    int refreshCallCount = 0;
    final Dio dio = Dio();
    final _SessionSyncRetryBackendInterceptor backend =
        _SessionSyncRetryBackendInterceptor();
    dio.interceptors.add(
      AuthTokenInterceptor(
        dio: dio,
        accessTokenGetter: () async => currentAccessToken,
        refreshTokenGetter: () async => 'refresh-token',
        refreshCallback: (_) async {
          refreshCallCount += 1;
          currentAccessToken = 'refreshed-access-token';
          return currentAccessToken;
        },
        onAuthReset: () async {
          fail('Session sync should not reset auth for a recoverable 401.');
        },
      ),
    );
    dio.interceptors.add(backend);
    final SessionRepositoryImpl retryingRepository = SessionRepositoryImpl(
      localDatabase: localDatabase,
      api: SessionApi(dio),
      currentUserIdGetter: () => _ownerUserId,
    );
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncPending,
            remoteId: 'remote-1',
            syncAttemptCount: 0),
        _buildSession(
            localId: 1,
            state: LocalSessionState.syncing,
            remoteId: 'remote-1',
            syncAttemptCount: 1),
        _buildSession(
          localId: 1,
          state: LocalSessionState.synced,
          remoteId: 'remote-1',
          syncAttemptCount: 1,
        ),
      ],
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => _popOrPeekLast(sessions));
    when(
      () => localDatabase.beginSyncAttempt(any()),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.updateSessionState(
        any(),
        any(),
        remoteId: any(named: 'remoteId'),
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.markSyncFailed(any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
    when(() => localDatabase.listPoints(any(),
            onlyAccepted: any(named: 'onlyAccepted')))
        .thenAnswer((_) async => <LocalSessionPoint>[_buildPoint(offsetMs: 0)]);

    final LocalRideSession result = await retryingRepository.syncSession(1);

    expect(result.state, LocalSessionState.synced);
    expect(result.syncAttemptCount, 1);
    expect(result.lastSyncError, isNull);
    expect(refreshCallCount, 1);
    expect(backend.uploadAttempts, 2);
    expect(backend.completeAttempts, 1);
    verifyNever(
      () => localDatabase.markSyncFailed(
        any(),
        error: any(named: 'error'),
      ),
    );
  });

  test('syncSession returns explicit failed snapshot when auth context drops',
      () async {
    final String currentUserId = _ownerUserId;
    final SessionRepositoryImpl authDroppingRepository = SessionRepositoryImpl(
      localDatabase: localDatabase,
      api: api,
      currentUserIdGetter: () => currentUserId,
    );
    final Queue<LocalRideSession?> scopedSessions =
        Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        _buildSession(
          localId: 1,
          state: LocalSessionState.syncPending,
          remoteId: 'remote-1',
        ),
        _buildSession(
          localId: 1,
          state: LocalSessionState.syncing,
          remoteId: 'remote-1',
          syncAttemptCount: 1,
        ),
        _buildSession(
          localId: 1,
          state: LocalSessionState.syncFailed,
          remoteId: 'remote-1',
          syncAttemptCount: 1,
          lastSyncError: 'Authentication required.',
        ),
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
        .thenAnswer((_) async => _popOrPeekLast(scopedSessions));
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

    final LocalRideSession result = await authDroppingRepository.syncSession(1);

    expect(result.state, LocalSessionState.syncFailed);
    expect(result.syncAttemptCount, 1);
    expect(result.lastSyncError, 'Authentication required.');
    verifyNever(() => localDatabase.getSessionByLocalId(any()));
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

  test('appendLocationPoint rejects access when auth context is missing',
      () async {
    final SessionRepositoryImpl offlineRepository = SessionRepositoryImpl(
      localDatabase: localDatabase,
      api: api,
      currentUserIdGetter: () => null,
    );
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

    expect(
      () => offlineRepository.appendLocationPoint(1, point),
      throwsA(isA<StateError>()),
    );
    verifyNever(() => localDatabase.getSessionByLocalId(any()));
    verifyNever(
      () => localDatabase.insertPoint(
        localSessionId: any(named: 'localSessionId'),
        point: any(named: 'point'),
      ),
    );
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

  test('getSessionDetail derives timeline segments and ride-only stats',
      () async {
    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer(
      (_) async => _buildSession(
        localId: 1,
        state: LocalSessionState.syncPending,
        activeDurationS: 30,
      ),
    );
    when(() => localDatabase.listPoints(1)).thenAnswer(
      (_) async => <LocalSessionPoint>[
        _buildPoint(
          offsetMs: 0,
          distanceDeltaM: 0,
          motionState: 'active_descent',
          latitude: 49.0,
          longitude: -123.0,
        ),
        _buildPoint(
          offsetMs: 5000,
          distanceDeltaM: 40,
          motionState: 'active_descent',
          latitude: 49.0004,
          longitude: -123.0002,
        ),
        _buildPoint(
          offsetMs: 10000,
          distanceDeltaM: 50,
          motionState: 'active_descent',
          latitude: 49.0008,
          longitude: -123.0004,
        ),
        _buildPoint(
          offsetMs: 15000,
          distanceDeltaM: 20,
          motionState: 'lift_uphill',
          latitude: 49.0010,
          longitude: -123.0002,
        ),
        _buildPoint(
          offsetMs: 20000,
          distanceDeltaM: 20,
          motionState: 'lift_uphill',
          latitude: 49.0012,
          longitude: -123.0,
        ),
        _buildPoint(
          offsetMs: 25000,
          distanceDeltaM: 0,
          speedMps: 0.1,
          motionState: 'stopped_idle',
          latitude: 49.0012,
          longitude: -123.0,
        ),
        _buildPoint(
          offsetMs: 30000,
          distanceDeltaM: 0,
          speedMps: 0.1,
          motionState: 'stopped_idle',
          latitude: 49.0012,
          longitude: -123.0,
        ),
      ],
    );
    when(() => localDatabase.listTrackingDiagnostics(1, limit: 120))
        .thenAnswer((_) async => const <TrackingDiagnosticEvent>[]);

    final SessionDetail detail = await repository.getSessionDetail(1);

    expect(detail.stats.descentDurationS, 10);
    expect(detail.stats.liftDurationS, 10);
    expect(detail.stats.idleDurationS, 10);
    expect(detail.stats.descentDistanceM, 90);
    expect(
      detail.timeline
          .map((SessionTimelineSegment segment) => segment.type)
          .toList(growable: false),
      <SessionActivityType>[
        SessionActivityType.descent,
        SessionActivityType.lift,
        SessionActivityType.idle,
      ],
    );
    expect(detail.stats.rideAvgSpeedMps, greaterThan(detail.stats.avgSpeedMps));
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
        .thenAnswer((_) async => _popOrPeekLast(sessions));
    when(
      () => localDatabase.beginSyncAttempt(any()),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.updateSessionState(
        any(),
        any(),
        remoteId: any(named: 'remoteId'),
        lastSyncError: any(named: 'lastSyncError'),
      ),
    ).thenAnswer((_) async {});
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

  test('getSessionDetail restores remote points for hydrated sessions',
      () async {
    final LocalRideSession hydrated = _buildSession(
      localId: 1,
      state: LocalSessionState.synced,
      remoteId: 'remote-restore',
      activeDurationS: 20,
    );
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        hydrated,
        hydrated,
      ],
    );
    final Queue<List<LocalSessionPoint>> pointSnapshots =
        Queue<List<LocalSessionPoint>>.from(
      <List<LocalSessionPoint>>[
        const <LocalSessionPoint>[],
        <LocalSessionPoint>[
          _buildPoint(
            offsetMs: 0,
            distanceDeltaM: 0,
            motionState: 'active_descent',
            latitude: 49.0,
            longitude: -123.0,
          ),
          _buildPoint(
            offsetMs: 10000,
            distanceDeltaM: 30,
            motionState: 'active_descent',
            latitude: 49.0003,
            longitude: -123.0002,
          ),
          _buildPoint(
            offsetMs: 20000,
            acceptedForAnalytics: false,
            qualityClass: 'reject',
            distanceDeltaM: 0,
            motionState: 'low_confidence_recovery',
            latitude: 49.0003,
            longitude: -123.0002,
          ),
        ],
      ],
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => _popOrPeekLast(sessions));
    when(() => localDatabase.listPoints(1)).thenAnswer(
      (_) async => pointSnapshots.removeFirst(),
    );
    when(
      () => localDatabase.replaceSessionPoints(
        localSessionId: any(named: 'localSessionId'),
        points: any(named: 'points'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.listTrackingDiagnostics(1, limit: 120))
        .thenAnswer((_) async => const <TrackingDiagnosticEvent>[]);
    when(() => api.getRemoteSessionPoints('remote-restore')).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          't_offset_ms': 0,
          'latitude': 49.0,
          'longitude': -123.0,
          'quality_class': 'accept_low_confidence',
          'motion_state': 'active_descent',
          'distance_delta_m': 0,
        },
        <String, dynamic>{
          't_offset_ms': 10000,
          'latitude': 49.0003,
          'longitude': -123.0002,
          'quality_class': 'accept',
          'motion_state': 'active_descent',
          'distance_delta_m': 30,
        },
        <String, dynamic>{
          't_offset_ms': 20000,
          'latitude': 49.0003,
          'longitude': -123.0002,
          'motion_state': 'low_confidence_recovery',
          'distance_delta_m': 0,
        },
      ],
    );

    final SessionDetail detail = await repository.getSessionDetail(1);

    expect(detail.points, hasLength(3));
    expect(detail.acceptedPoints, hasLength(2));
    final List<dynamic> captured = verify(
      () => localDatabase.replaceSessionPoints(
        localSessionId: 1,
        points: captureAny(named: 'points'),
      ),
    ).captured;
    final List<NewSessionPoint> restored =
        captured.single as List<NewSessionPoint>;
    expect(restored, hasLength(3));
    expect(restored[0].acceptedForAnalytics, isTrue);
    expect(restored[1].acceptedForAnalytics, isTrue);
    expect(restored[2].acceptedForAnalytics, isFalse);
    expect(restored[2].recordedAt, DateTime.utc(2026, 1, 1, 0, 0, 20));
  });

  test(
      'getSessionDetail prefers canonical acceptance and recorded_at fields when available',
      () async {
    final LocalRideSession hydrated = _buildSession(
      localId: 1,
      state: LocalSessionState.synced,
      remoteId: 'remote-restore',
      activeDurationS: 20,
    );
    final Queue<LocalRideSession?> sessions = Queue<LocalRideSession?>.from(
      <LocalRideSession?>[
        hydrated,
        hydrated,
      ],
    );
    final Queue<List<LocalSessionPoint>> pointSnapshots =
        Queue<List<LocalSessionPoint>>.from(
      <List<LocalSessionPoint>>[
        const <LocalSessionPoint>[],
        <LocalSessionPoint>[
          _buildPoint(
            offsetMs: 5000,
            acceptedForAnalytics: false,
            qualityClass: 'accept',
            motionState: 'active_descent',
            distanceDeltaM: 0,
            latitude: 49.0,
            longitude: -123.0,
          ),
          _buildPoint(
            offsetMs: 10000,
            acceptedForAnalytics: true,
            qualityClass: 'accept',
            motionState: 'active_descent',
            distanceDeltaM: 30,
            latitude: 49.0003,
            longitude: -123.0002,
          ),
          _buildPoint(
            offsetMs: 20000,
            acceptedForAnalytics: false,
            qualityClass: 'reject',
            motionState: 'low_confidence_recovery',
            distanceDeltaM: 0,
            latitude: 49.0003,
            longitude: -123.0002,
          ),
        ],
      ],
    );

    when(() => localDatabase.getSessionById(1, ownerUserId: _ownerUserId))
        .thenAnswer((_) async => _popOrPeekLast(sessions));
    when(() => localDatabase.listPoints(1)).thenAnswer(
      (_) async => pointSnapshots.removeFirst(),
    );
    when(
      () => localDatabase.replaceSessionPoints(
        localSessionId: any(named: 'localSessionId'),
        points: any(named: 'points'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDatabase.listTrackingDiagnostics(1, limit: 120))
        .thenAnswer((_) async => const <TrackingDiagnosticEvent>[]);
    when(() => api.getRemoteSessionPoints('remote-restore')).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          't_offset_ms': 0,
          'recorded_at': '2026-01-01T00:00:05Z',
          'latitude': 49.0,
          'longitude': -123.0,
          'quality_class': 'accept',
          'motion_state': 'active_descent',
          'accepted_for_analytics': false,
          'distance_delta_m': 0,
        },
        <String, dynamic>{
          't_offset_ms': 10000,
          'latitude': 49.0003,
          'longitude': -123.0002,
          'quality_class': 'accept',
          'motion_state': 'active_descent',
          'accepted_for_analytics': true,
          'distance_delta_m': 30,
        },
        <String, dynamic>{
          't_offset_ms': 20000,
          'latitude': 49.0003,
          'longitude': -123.0002,
          'motion_state': 'low_confidence_recovery',
          'distance_delta_m': 0,
        },
      ],
    );

    final SessionDetail detail = await repository.getSessionDetail(1);

    expect(detail.points, hasLength(3));
    expect(detail.acceptedPoints, hasLength(1));
    final List<dynamic> captured = verify(
      () => localDatabase.replaceSessionPoints(
        localSessionId: 1,
        points: captureAny(named: 'points'),
      ),
    ).captured;
    final List<NewSessionPoint> restored =
        captured.single as List<NewSessionPoint>;
    expect(restored, hasLength(3));
    expect(restored[0].acceptedForAnalytics, isFalse);
    expect(restored[0].recordedAt, DateTime.utc(2026, 1, 1, 0, 0, 5));
    expect(restored[1].acceptedForAnalytics, isTrue);
    expect(restored[1].recordedAt, DateTime.utc(2026, 1, 1, 0, 0, 10));
    expect(restored[2].acceptedForAnalytics, isFalse);
    expect(restored[2].recordedAt, DateTime.utc(2026, 1, 1, 0, 0, 20));
  });

  test('deleteSession removes a local-only session without remote API call',
      () async {
    final LocalRideSession session = _buildSession(
      localId: 1,
      state: LocalSessionState.syncPending,
    );
    when(
      () => localDatabase.deleteSessionCascade(
        localSessionId: 1,
        ownerUserId: _ownerUserId,
        remoteId: null,
        clearPendingRemoteSessionDelete:
            any(named: 'clearPendingRemoteSessionDelete'),
      ),
    ).thenAnswer((_) async => true);

    final DeleteSessionResult result = await repository.deleteSession(session);

    expect(result.disposition, DeleteSessionDisposition.localOnly);
    verify(
      () => localDatabase.deleteSessionCascade(
        localSessionId: 1,
        ownerUserId: _ownerUserId,
        remoteId: null,
        clearPendingRemoteSessionDelete: true,
      ),
    ).called(1);
    verifyNever(() => api.deleteRemoteSession(any()));
    verifyNever(
      () => localDatabase.enqueuePendingRemoteSessionDelete(
        ownerUserId: any(named: 'ownerUserId'),
        remoteId: any(named: 'remoteId'),
      ),
    );
  });

  test('deleteSession deletes remote-backed local session via API then cascade',
      () async {
    final LocalRideSession session = _buildSession(
      localId: 4,
      state: LocalSessionState.synced,
      remoteId: 'remote-4',
    );
    when(() => api.deleteRemoteSession('remote-4')).thenAnswer((_) async {});
    when(
      () => localDatabase.deleteSessionCascade(
        localSessionId: 4,
        ownerUserId: _ownerUserId,
        remoteId: 'remote-4',
        clearPendingRemoteSessionDelete:
            any(named: 'clearPendingRemoteSessionDelete'),
      ),
    ).thenAnswer((_) async => true);

    final DeleteSessionResult result = await repository.deleteSession(session);

    expect(result.disposition, DeleteSessionDisposition.deletedRemotely);
    verify(
      () => localDatabase.enqueuePendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-4',
      ),
    ).called(1);
    verify(() => api.deleteRemoteSession('remote-4')).called(1);
    verify(
      () => localDatabase.clearPendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-4',
      ),
    ).called(1);
    verify(
      () => localDatabase.deleteSessionCascade(
        localSessionId: 4,
        ownerUserId: _ownerUserId,
        remoteId: 'remote-4',
        clearPendingRemoteSessionDelete: true,
      ),
    ).called(1);
    verifyNever(
      () => localDatabase.deleteCachedRemoteSessionSummary(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-4',
      ),
    );
  });

  test(
      'history hides persisted pending-delete remote sessions across repository reloads',
      () async {
    when(() => localDatabase.listSessions(ownerUserId: _ownerUserId))
        .thenAnswer((_) async => const <LocalRideSession>[]);
    when(() =>
            localDatabase.readCachedRemoteSessions(ownerUserId: _ownerUserId))
        .thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'remote-queued',
          'status': 'COMPLETED',
          'started_at': '2026-01-04T00:00:00Z',
          'ended_at': '2026-01-04T00:10:00Z',
          'duration_s': 600,
          'distance_m': 1500,
          'max_speed_mps': 10,
          'avg_speed_mps': 8,
        },
      ],
    );
    when(() => api.listRemoteSessions()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'remote-queued',
          'status': 'COMPLETED',
          'started_at': '2026-01-04T00:00:00Z',
          'ended_at': '2026-01-04T00:10:00Z',
          'duration_s': 600,
          'distance_m': 1500,
          'max_speed_mps': 10,
          'avg_speed_mps': 8,
        },
      ],
    );
    when(
      () => localDatabase.replaceCachedRemoteSessions(
        ownerUserId: _ownerUserId,
        sessions: any(named: 'sessions'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => localDatabase.listPendingRemoteSessionDeleteIds(
        ownerUserId: _ownerUserId,
      ),
    ).thenAnswer((_) async => <String>{'remote-queued'});

    final List<LocalRideSession> history =
        await repository.listLocalAndRemoteSessionHistory();

    expect(history, isEmpty);
  });

  test(
      'deleteSession queues remote delete on NetworkFailure and removes local copy',
      () async {
    final LocalRideSession session = _buildSession(
      localId: 5,
      state: LocalSessionState.synced,
      remoteId: 'remote-5',
    );
    final DioException connectionError = DioException(
      requestOptions: RequestOptions(path: '/sessions/remote-5'),
      type: DioExceptionType.connectionError,
      error: const SocketException('No route to host'),
    );

    when(() => api.deleteRemoteSession('remote-5')).thenThrow(connectionError);
    when(
      () => localDatabase.deleteSessionCascade(
        localSessionId: 5,
        ownerUserId: _ownerUserId,
        remoteId: 'remote-5',
        clearPendingRemoteSessionDelete:
            any(named: 'clearPendingRemoteSessionDelete'),
      ),
    ).thenAnswer((_) async => true);

    final DeleteSessionResult result = await repository.deleteSession(session);

    expect(result.queuedRemoteDelete, isTrue);
    verify(
      () => localDatabase.enqueuePendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-5',
      ),
    ).called(1);
    verify(() => api.deleteRemoteSession('remote-5')).called(1);
    verify(
      () => localDatabase.recordPendingRemoteSessionDeleteAttempt(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-5',
        lastError: any(named: 'lastError'),
        nextAttemptAt: any(named: 'nextAttemptAt'),
      ),
    ).called(1);
    verify(
      () => localDatabase.deleteSessionCascade(
        localSessionId: 5,
        ownerUserId: _ownerUserId,
        remoteId: 'remote-5',
        clearPendingRemoteSessionDelete: false,
      ),
    ).called(1);
    verifyNever(
      () => localDatabase.clearPendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-5',
      ),
    );
  });

  test(
      'deleteSession marks durable failed delete state and throws for hard remote delete failures',
      () async {
    final LocalRideSession session = _buildSession(
      localId: 6,
      state: LocalSessionState.synced,
      remoteId: 'remote-6',
    );
    final RequestOptions requestOptions =
        RequestOptions(path: '/sessions/remote-6');
    final DioException unauthorized = DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 401,
        data: <String, dynamic>{'detail': 'Authentication required.'},
      ),
      type: DioExceptionType.badResponse,
    );
    when(() => api.deleteRemoteSession('remote-6')).thenThrow(unauthorized);

    await expectLater(
      repository.deleteSession(session),
      throwsA(isA<AuthFailure>()),
    );

    verify(
      () => localDatabase.enqueuePendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-6',
      ),
    ).called(1);
    verify(() => api.deleteRemoteSession('remote-6')).called(1);
    verify(
      () => localDatabase.markPendingRemoteSessionDeleteFailed(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-6',
        lastError: any(named: 'lastError'),
      ),
    ).called(1);
    verifyNever(
      () => localDatabase.clearPendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-6',
      ),
    );
    verifyNever(
      () => localDatabase.deleteSessionCascade(
        localSessionId: 6,
        ownerUserId: _ownerUserId,
        remoteId: 'remote-6',
        clearPendingRemoteSessionDelete:
            any(named: 'clearPendingRemoteSessionDelete'),
      ),
    );
  });

  test(
      'refreshRemoteSessionHistoryCache reconciles queued deletes and clears queue on success',
      () async {
    when(
      () => localDatabase.listRetryablePendingRemoteDeletes(
        ownerUserId: _ownerUserId,
      ),
    ).thenAnswer(
      (_) async => const <PendingRemoteSessionDeleteEntry>[
        PendingRemoteSessionDeleteEntry(
          ownerUserId: _ownerUserId,
          remoteId: 'remote-10',
          attemptCount: 0,
        ),
      ],
    );
    when(() => api.deleteRemoteSession('remote-10')).thenAnswer((_) async {});
    when(
      () => localDatabase.listPendingRemoteSessionDeleteIds(
        ownerUserId: _ownerUserId,
      ),
    ).thenAnswer((_) async => <String>{});
    when(() => api.listRemoteSessions())
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(
      () => localDatabase.replaceCachedRemoteSessions(
        ownerUserId: _ownerUserId,
        sessions: any(named: 'sessions'),
      ),
    ).thenAnswer((_) async {});

    await repository.refreshRemoteSessionHistoryCache();

    verify(
      () => localDatabase.clearPendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-10',
      ),
    ).called(1);
  });

  test(
      'refreshRemoteSessionHistoryCache clears queued delete when reconciliation returns 404',
      () async {
    when(
      () => localDatabase.listRetryablePendingRemoteDeletes(
        ownerUserId: _ownerUserId,
      ),
    ).thenAnswer(
      (_) async => const <PendingRemoteSessionDeleteEntry>[
        PendingRemoteSessionDeleteEntry(
          ownerUserId: _ownerUserId,
          remoteId: 'remote-11',
          attemptCount: 1,
        ),
      ],
    );
    final RequestOptions requestOptions =
        RequestOptions(path: '/sessions/remote-11');
    final DioException notFound = DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 404,
      ),
      type: DioExceptionType.badResponse,
    );
    when(() => api.deleteRemoteSession('remote-11')).thenThrow(notFound);
    when(
      () => localDatabase.listPendingRemoteSessionDeleteIds(
        ownerUserId: _ownerUserId,
      ),
    ).thenAnswer((_) async => <String>{});
    when(() => api.listRemoteSessions())
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(
      () => localDatabase.replaceCachedRemoteSessions(
        ownerUserId: _ownerUserId,
        sessions: any(named: 'sessions'),
      ),
    ).thenAnswer((_) async {});

    await repository.refreshRemoteSessionHistoryCache();

    verify(
      () => localDatabase.clearPendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-11',
      ),
    ).called(1);
  });

  test(
      'refreshRemoteSessionHistoryCache marks queued delete as failed on hard reconciliation error',
      () async {
    when(
      () => localDatabase.listRetryablePendingRemoteDeletes(
        ownerUserId: _ownerUserId,
      ),
    ).thenAnswer(
      (_) async => const <PendingRemoteSessionDeleteEntry>[
        PendingRemoteSessionDeleteEntry(
          ownerUserId: _ownerUserId,
          remoteId: 'remote-12',
          attemptCount: 2,
        ),
      ],
    );
    final RequestOptions requestOptions =
        RequestOptions(path: '/sessions/remote-12');
    final DioException unauthorized = DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 401,
        data: <String, dynamic>{'detail': 'Authentication required.'},
      ),
      type: DioExceptionType.badResponse,
    );
    when(() => api.deleteRemoteSession('remote-12')).thenThrow(unauthorized);
    when(
      () => localDatabase.listPendingRemoteSessionDeleteIds(
        ownerUserId: _ownerUserId,
      ),
    ).thenAnswer((_) async => <String>{});
    when(() => api.listRemoteSessions())
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
    when(
      () => localDatabase.replaceCachedRemoteSessions(
        ownerUserId: _ownerUserId,
        sessions: any(named: 'sessions'),
      ),
    ).thenAnswer((_) async {});

    await repository.refreshRemoteSessionHistoryCache();

    verify(
      () => localDatabase.markPendingRemoteSessionDeleteFailed(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-12',
        lastError: any(named: 'lastError'),
      ),
    ).called(1);
    verifyNever(
      () => localDatabase.clearPendingRemoteSessionDelete(
        ownerUserId: _ownerUserId,
        remoteId: 'remote-12',
      ),
    );
  });

  test('resolveSessionResortLabel prefers explicit resort id mapped from cache',
      () async {
    final LocalRideSession session = _buildSession(
      localId: 12,
      state: LocalSessionState.synced,
    );
    final LocalRideSession explicit = LocalRideSession(
      localId: session.localId,
      ownerUserId: session.ownerUserId,
      remoteId: session.remoteId,
      resortId: 'resort-whistler',
      startedAt: session.startedAt,
      endedAt: session.endedAt,
      activeDurationS: session.activeDurationS,
      distanceM: session.distanceM,
      maxSpeedMps: session.maxSpeedMps,
      avgSpeedMps: session.avgSpeedMps,
      elevationGainM: session.elevationGainM,
      elevationLossM: session.elevationLossM,
      state: session.state,
      pointCount: session.pointCount,
      syncAttemptCount: session.syncAttemptCount,
      lastSyncError: session.lastSyncError,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
    );

    when(() => localDatabase.readCachedResorts()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'resort-whistler',
          'name': 'Whistler Blackcomb',
          'country': 'CA',
          'region': 'BC',
          'latitude': 50.1,
          'longitude': -122.9,
        },
      ],
    );

    final String label = await repository.resolveSessionResortLabel(explicit);

    expect(label, 'Whistler Blackcomb');
    verifyNever(() => localDatabase.latestAcceptedPoint(any()));
  });

  test(
      'resolveSessionResortLabel falls back to nearest cached resort from points',
      () async {
    final LocalRideSession session = _buildSession(
      localId: 21,
      state: LocalSessionState.synced,
    );
    when(() => localDatabase.readCachedResorts()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'resort-near',
          'name': 'Near Resort',
          'country': 'CA',
          'region': 'BC',
          'latitude': 49.0002,
          'longitude': -123.0002,
        },
        <String, dynamic>{
          'id': 'resort-far',
          'name': 'Far Resort',
          'country': 'CA',
          'region': 'AB',
          'latitude': 52.0,
          'longitude': -114.0,
        },
      ],
    );
    when(() => localDatabase.latestAcceptedPoint(21)).thenAnswer(
      (_) async => _buildPoint(
        offsetMs: 0,
        latitude: 49.0001,
        longitude: -123.0001,
      ),
    );

    final String label = await repository.resolveSessionResortLabel(session);

    expect(label, 'Near Resort');
  });

  test('resolveSessionResortLabel returns Unknown resort when no match',
      () async {
    final LocalRideSession session = _buildSession(
      localId: 31,
      state: LocalSessionState.synced,
    );
    when(() => localDatabase.readCachedResorts()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'resort-far',
          'name': 'Far Resort',
          'country': 'CA',
          'region': 'AB',
          'latitude': 10.0,
          'longitude': 10.0,
        },
      ],
    );
    when(() => localDatabase.latestAcceptedPoint(31)).thenAnswer(
      (_) async => _buildPoint(
        offsetMs: 0,
        latitude: 49.0,
        longitude: -123.0,
      ),
    );

    final String label = await repository.resolveSessionResortLabel(session);

    expect(label, 'Unknown resort');
  });
}
