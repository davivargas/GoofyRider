import 'dart:math';

import 'package:dio/dio.dart';

import '../../../core/constants/session_constants.dart';
import '../../../core/network/api_error.dart';
import '../../../core/storage/drift_local_database.dart';
import '../domain/session_models.dart';
import '../domain/session_repository.dart';
import '../domain/session_state_machine.dart';
import 'session_api.dart';

class SessionRepositoryImpl implements SessionRepository {
  SessionRepositoryImpl({
    required DriftLocalDatabase localDatabase,
    required SessionApi api,
    SessionAnalyticsEngine analyticsEngine = const SessionAnalyticsEngine(),
    SessionStateMachine stateMachine = const SessionStateMachine(),
  })  : _localDatabase = localDatabase,
        _api = api,
        _analyticsEngine = analyticsEngine,
        _stateMachine = stateMachine;

  final DriftLocalDatabase _localDatabase;
  final SessionApi _api;
  final SessionAnalyticsEngine _analyticsEngine;
  final SessionStateMachine _stateMachine;

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async {
    final int localId = await _localDatabase.insertLocalSession(
      startedAt: DateTime.now().toUtc(),
      resortId: resortId,
    );
    final LocalRideSession? created =
        await _localDatabase.getSessionById(localId);
    if (created == null) {
      throw StateError('Local session was not created.');
    }
    return created;
  }

  @override
  Future<LocalRideSession> pauseLocalSession(int localSessionId) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    _stateMachine.transition(session.state, LocalSessionState.paused);
    await _localDatabase.updateSessionState(
        localSessionId, LocalSessionState.paused);
    return (await _localDatabase.getSessionById(localSessionId))!;
  }

  @override
  Future<LocalRideSession> resumeLocalSession(int localSessionId) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    _stateMachine.transition(session.state, LocalSessionState.recording);
    await _localDatabase.updateSessionState(
        localSessionId, LocalSessionState.recording);
    return (await _localDatabase.getSessionById(localSessionId))!;
  }

  @override
  Future<void> appendLocationPoint(
      int localSessionId, NewSessionPoint point) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    if (session.state != LocalSessionState.recording) {
      return;
    }

    LocalSessionPoint? previousAccepted;
    final List<LocalSessionPoint> accepted = await _localDatabase.listPoints(
      localSessionId,
      onlyAccepted: true,
    );
    if (accepted.isNotEmpty) {
      previousAccepted = accepted.last;
    }

    final PointAcceptanceResult acceptance = _analyticsEngine.evaluate(
      previousAccepted,
      point,
    );

    final NewSessionPoint savedPoint = NewSessionPoint(
      recordedAt: point.recordedAt,
      tOffsetMs: point.tOffsetMs,
      latitude: point.latitude,
      longitude: point.longitude,
      accuracyM: point.accuracyM,
      altitudeM: point.altitudeM,
      speedMps: point.speedMps,
      headingDeg: point.headingDeg,
      acceptedForAnalytics: acceptance.acceptedForAnalytics,
    );

    await _localDatabase.insertPoint(
        localSessionId: localSessionId, point: savedPoint);
  }

  @override
  Future<LocalRideSession> finishLocalSession(
    int localSessionId, {
    int? activeDurationS,
  }) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    _stateMachine.transition(session.state, LocalSessionState.locallyCompleted);

    final List<LocalSessionPoint> accepted = await _localDatabase.listPoints(
      localSessionId,
      onlyAccepted: true,
    );
    final int effectiveDurationS =
        activeDurationS ?? _computeActiveDurationSeconds(accepted);
    final SessionStats stats = _analyticsEngine.computeStats(
      acceptedPoints: accepted,
      activeDurationS: effectiveDurationS,
    );

    final DateTime endedAt = DateTime.now().toUtc();

    await _localDatabase.completeLocalSession(
      localId: localSessionId,
      endedAt: endedAt,
      stats: stats,
    );

    final LocalRideSession completed =
        (await _localDatabase.getSessionById(localSessionId))!;
    return completed;
  }

  @override
  Future<LocalRideSession?> recoverInProgressSession() {
    return _localDatabase.getInProgressSession();
  }

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async {
    final List<LocalSessionPoint> accepted = await _localDatabase.listPoints(
      localSessionId,
      onlyAccepted: true,
    );
    final int activeDurationS = _computeActiveDurationSeconds(accepted);
    return _analyticsEngine.computeStats(
      acceptedPoints: accepted,
      activeDurationS: activeDurationS,
    );
  }

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
    final LocalRideSession original = await _requireSession(localSessionId);

    try {
      await _localDatabase.updateSessionState(
        localSessionId,
        LocalSessionState.syncing,
        lastSyncError: null,
      );
      await _localDatabase.incrementSyncAttempt(localSessionId);

      final LocalRideSession syncing =
          (await _localDatabase.getSessionById(localSessionId))!;

      String? remoteId = syncing.remoteId;
      if (remoteId == null || remoteId.isEmpty) {
        final Map<String, dynamic> draft = await _api.createRemoteDraft(
          resortId: syncing.resortId,
          startedAt: syncing.startedAt,
        );
        remoteId = draft['id'] as String;
        await _localDatabase.updateSessionState(
          localSessionId,
          LocalSessionState.syncing,
          remoteId: remoteId,
        );
      }

      final List<LocalSessionPoint> acceptedPoints =
          await _localDatabase.listPoints(
        localSessionId,
        onlyAccepted: true,
      );

      final Set<int> existingOffsets =
          await _fetchExistingRemoteOffsets(remoteId);
      final List<LocalSessionPoint> uploadable = acceptedPoints
          .where((LocalSessionPoint point) =>
              !existingOffsets.contains(point.tOffsetMs))
          .toList(growable: false);

      for (int index = 0;
          index < uploadable.length;
          index += SessionConstants.uploadBatchSize) {
        final int end =
            min(index + SessionConstants.uploadBatchSize, uploadable.length);
        final List<LocalSessionPoint> batch = uploadable.sublist(index, end);

        await _api.uploadPointBatch(
          remoteSessionId: remoteId,
          points: batch
              .map(
                (LocalSessionPoint point) => <String, dynamic>{
                  't_offset_ms': point.tOffsetMs,
                  'latitude': point.latitude,
                  'longitude': point.longitude,
                  'accuracy_m': point.accuracyM,
                  'altitude_m': point.altitudeM,
                  'speed_mps': point.speedMps,
                  'heading_deg': point.headingDeg,
                },
              )
              .toList(growable: false),
        );
      }

      await _api.completeRemoteSession(
        remoteSessionId: remoteId,
        endedAt: syncing.endedAt ?? DateTime.now().toUtc(),
        durationS: syncing.activeDurationS,
        distanceM: syncing.distanceM,
        maxSpeedMps: syncing.maxSpeedMps,
        avgSpeedMps: syncing.avgSpeedMps,
        elevationGainM: syncing.elevationGainM,
        elevationLossM: syncing.elevationLossM,
      );

      await _localDatabase.updateSessionState(
          localSessionId, LocalSessionState.synced);
      return (await _localDatabase.getSessionById(localSessionId))!;
    } on DioException catch (exception) {
      final String message = mapDioException(exception).message;
      await _localDatabase.updateSessionState(
        localSessionId,
        LocalSessionState.syncFailed,
        lastSyncError: message,
      );
      await _localDatabase.incrementSyncAttempt(localSessionId, error: message);
      return (await _localDatabase.getSessionById(localSessionId)) ?? original;
    }
  }

  @override
  Future<LocalRideSession> retryFailedSync(int localSessionId) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    if (session.state != LocalSessionState.syncFailed) {
      return session;
    }
    return syncSession(localSessionId);
  }

  @override
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async {
    final List<LocalRideSession> local = await _localDatabase.listSessions();
    List<Map<String, dynamic>> remote = <Map<String, dynamic>>[];
    try {
      remote = await _api.listRemoteSessions();
    } on DioException {
      remote = <Map<String, dynamic>>[];
    }

    final Set<String> localRemoteIds = local
        .where((LocalRideSession session) => session.remoteId != null)
        .map((LocalRideSession session) => session.remoteId!)
        .toSet();

    final List<LocalRideSession> remoteOnly = remote
        .where((Map<String, dynamic> item) {
          final String id = item['id'] as String;
          return !localRemoteIds.contains(id);
        })
        .map(_mapRemoteAsLocal)
        .toList(growable: false);

    final List<LocalRideSession> merged = <LocalRideSession>[
      ...local,
      ...remoteOnly
    ];
    merged.sort((LocalRideSession a, LocalRideSession b) =>
        b.startedAt.compareTo(a.startedAt));
    return merged;
  }

  @override
  Future<SessionDetail> getSessionDetail(int localSessionId) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    final List<LocalSessionPoint> points =
        await _localDatabase.listPoints(localSessionId);
    final List<LocalSessionPoint> accepted = points
        .where((LocalSessionPoint point) => point.acceptedForAnalytics)
        .toList(growable: false);

    return SessionDetail(
        session: session, points: points, acceptedPoints: accepted);
  }

  @override
  Future<int> unsyncedCount() {
    return _localDatabase.unsyncedCount();
  }

  Future<LocalRideSession> _requireSession(int localSessionId) async {
    final LocalRideSession? session =
        await _localDatabase.getSessionById(localSessionId);
    if (session == null) {
      throw StateError('Session not found: $localSessionId');
    }
    return session;
  }

  int _computeActiveDurationSeconds(List<LocalSessionPoint> accepted) {
    if (accepted.length < 2) {
      return 0;
    }

    int total = 0;
    for (int index = 1; index < accepted.length; index++) {
      final int delta = accepted[index]
          .recordedAt
          .difference(accepted[index - 1].recordedAt)
          .inSeconds;
      if (delta >= SessionConstants.minDeltaSeconds &&
          delta <= SessionConstants.maxDeltaSeconds) {
        total += delta;
      }
    }
    return total;
  }

  Future<Set<int>> _fetchExistingRemoteOffsets(String remoteId) async {
    try {
      final List<Map<String, dynamic>> remotePoints =
          await _api.getRemoteSessionPoints(remoteId);
      return remotePoints
          .map((Map<String, dynamic> point) => point['t_offset_ms'] as int)
          .toSet();
    } on DioException {
      return <int>{};
    }
  }

  LocalRideSession _mapRemoteAsLocal(Map<String, dynamic> raw) {
    final String id = raw['id'] as String;
    final Map<String, dynamic>? resortSummary =
        raw['resort'] as Map<String, dynamic>?;

    return LocalRideSession(
      localId: -id.hashCode.abs(),
      remoteId: id,
      resortId: resortSummary?['id'] as String?,
      startedAt: DateTime.parse(raw['started_at'] as String).toUtc(),
      endedAt: raw['ended_at'] == null
          ? null
          : DateTime.parse(raw['ended_at'] as String).toUtc(),
      activeDurationS: raw['duration_s'] as int? ?? 0,
      distanceM: (raw['distance_m'] as num?)?.toDouble() ?? 0,
      maxSpeedMps: (raw['max_speed_mps'] as num?)?.toDouble() ?? 0,
      avgSpeedMps: (raw['avg_speed_mps'] as num?)?.toDouble() ?? 0,
      elevationGainM: raw['elevation_gain_m'] as int?,
      elevationLossM: raw['elevation_loss_m'] as int?,
      state: LocalSessionState.synced,
      pointCount: 0,
      syncAttemptCount: 0,
      lastSyncError: null,
      createdAt: DateTime.parse(raw['started_at'] as String).toUtc(),
      updatedAt: DateTime.parse(raw['started_at'] as String).toUtc(),
    );
  }
}
