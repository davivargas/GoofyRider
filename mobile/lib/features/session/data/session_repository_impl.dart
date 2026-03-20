import 'dart:async';
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
    required String? Function() currentUserIdGetter,
    SessionStateMachine stateMachine = const SessionStateMachine(),
  })  : _localDatabase = localDatabase,
        _api = api,
        _currentUserIdGetter = currentUserIdGetter,
        _stateMachine = stateMachine;

  final DriftLocalDatabase _localDatabase;
  final SessionApi _api;
  final String? Function() _currentUserIdGetter;
  final SessionStateMachine _stateMachine;

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async {
    final String ownerUserId = _requireCurrentUserId();
    final int localId = await _localDatabase.insertLocalSession(
      startedAt: DateTime.now().toUtc(),
      ownerUserId: ownerUserId,
      resortId: resortId,
    );
    final LocalRideSession? created =
        await _localDatabase.getSessionById(localId, ownerUserId: ownerUserId);
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
    return _requireSession(localSessionId);
  }

  @override
  Future<LocalRideSession> resumeLocalSession(int localSessionId) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    _stateMachine.transition(session.state, LocalSessionState.recording);
    await _localDatabase.updateSessionState(
        localSessionId, LocalSessionState.recording);
    return _requireSession(localSessionId);
  }

  @override
  Future<void> appendLocationPoint(
      int localSessionId, NewSessionPoint point) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    if (session.state != LocalSessionState.recording) {
      return;
    }
    await _localDatabase.insertPoint(
        localSessionId: localSessionId, point: point);
  }

  @override
  Future<LocalRideSession> finishLocalSession(
    int localSessionId, {
    int? activeDurationS,
  }) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    _stateMachine.transition(session.state, LocalSessionState.locallyCompleted);

    final List<LocalSessionPoint> points =
        await _localDatabase.listPoints(localSessionId);
    final int effectiveDurationS =
        activeDurationS ?? _computeActiveDurationSeconds(points);
    final SessionStats stats = _computeStatsFromTrackedPoints(
      points: points,
      activeDurationS: effectiveDurationS,
    );

    final DateTime endedAt = DateTime.now().toUtc();

    await _localDatabase.completeLocalSession(
      localId: localSessionId,
      endedAt: endedAt,
      stats: stats,
    );

    return _requireSession(localSessionId);
  }

  @override
  Future<LocalRideSession?> recoverInProgressSession() async {
    final String? ownerUserId = _currentUserIdOrNull;
    if (ownerUserId == null || ownerUserId.isEmpty) {
      return null;
    }
    return _localDatabase.getInProgressSession(ownerUserId: ownerUserId);
  }

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async {
    final List<LocalSessionPoint> points =
        await _localDatabase.listPoints(localSessionId);
    final int activeDurationS = _computeActiveDurationSeconds(points);
    return _computeStatsFromTrackedPoints(
      points: points,
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

      final LocalRideSession syncing = await _requireSession(localSessionId);

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
      final List<LocalSessionPoint> dedupedUploadable =
          _dedupeByOffset(uploadable);

      for (int index = 0;
          index < dedupedUploadable.length;
          index += SessionConstants.uploadBatchSize) {
        final int end = min(
            index + SessionConstants.uploadBatchSize, dedupedUploadable.length);
        final List<LocalSessionPoint> batch =
            dedupedUploadable.sublist(index, end);

        await _api.uploadPointBatch(
          remoteSessionId: remoteId,
          points: batch
              .map(
                (LocalSessionPoint point) => <String, dynamic>{
                  't_offset_ms': point.tOffsetMs,
                  'latitude': point.latitude,
                  'longitude': point.longitude,
                  'accuracy_m': point.accuracyM,
                  'elapsed_realtime_ns': point.elapsedRealtimeNs,
                  'altitude_m': point.altitudeM,
                  'vertical_accuracy_m': point.verticalAccuracyM,
                  'speed_mps': point.speedMps,
                  'speed_accuracy_mps': point.speedAccuracyMps,
                  'heading_deg': point.headingDeg,
                  'bearing_accuracy_deg': point.bearingAccuracyDeg,
                  'provider': point.provider,
                  'is_mocked': point.isMocked,
                  'quality_class': point.qualityClass,
                  'quality_score': point.qualityScore,
                  'quality_reason': point.qualityReason,
                  'filtered_latitude': point.filteredLatitude,
                  'filtered_longitude': point.filteredLongitude,
                  'filtered_altitude_m': point.filteredAltitudeM,
                  'fused_speed_mps': point.fusedSpeedMps,
                  'derived_speed_mps': point.derivedSpeedMps,
                  'distance_delta_m': point.distanceDeltaM,
                  'motion_state': point.motionState,
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
        maxSpeedMps: _sanitizeMaxSpeedForRemote(syncing),
        avgSpeedMps: _sanitizeAvgSpeedForRemote(syncing),
        elevationGainM: syncing.elevationGainM,
        elevationLossM: syncing.elevationLossM,
      );

      await _localDatabase.updateSessionState(
          localSessionId, LocalSessionState.synced);
      return _requireSession(localSessionId);
    } on DioException catch (exception) {
      final String message = mapDioException(exception).message;
      await _localDatabase.updateSessionState(
        localSessionId,
        LocalSessionState.syncFailed,
        lastSyncError: message,
      );
      await _localDatabase.incrementSyncAttempt(localSessionId, error: message);
      return await _tryGetScopedSession(localSessionId) ?? original;
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
    final String? ownerUserId = _currentUserIdOrNull;
    if (ownerUserId == null || ownerUserId.isEmpty) {
      return const <LocalRideSession>[];
    }

    final List<LocalRideSession> local =
        await _localDatabase.listSessions(ownerUserId: ownerUserId);
    final List<Map<String, dynamic>> cachedRemote =
        await _localDatabase.readCachedRemoteSessions(ownerUserId: ownerUserId);

    if (local.isNotEmpty || cachedRemote.isNotEmpty) {
      unawaited(refreshRemoteSessionHistoryCache());
      return _mergeHistory(
        local: local,
        remote: cachedRemote,
        ownerUserId: ownerUserId,
      );
    }

    await refreshRemoteSessionHistoryCache();
    final List<Map<String, dynamic>> refreshedRemote =
        await _localDatabase.readCachedRemoteSessions(ownerUserId: ownerUserId);
    return _mergeHistory(
      local: local,
      remote: refreshedRemote,
      ownerUserId: ownerUserId,
    );
  }

  @override
  Future<void> refreshRemoteSessionHistoryCache() async {
    final String? ownerUserId = _currentUserIdOrNull;
    if (ownerUserId == null || ownerUserId.isEmpty) {
      return;
    }

    try {
      final List<Map<String, dynamic>> remote = await _api.listRemoteSessions();
      await _localDatabase.replaceCachedRemoteSessions(
        ownerUserId: ownerUserId,
        sessions: remote,
      );
    } on DioException {
      return;
    }
  }

  List<LocalRideSession> _mergeHistory({
    required List<LocalRideSession> local,
    required List<Map<String, dynamic>> remote,
    required String ownerUserId,
  }) {
    final Set<String> localRemoteIds = local
        .where((LocalRideSession session) => session.remoteId != null)
        .map((LocalRideSession session) => session.remoteId!)
        .toSet();

    final List<LocalRideSession> remoteOnly = remote
        .where((Map<String, dynamic> item) {
          final String id = item['id'] as String;
          return !localRemoteIds.contains(id);
        })
        .map(
          (Map<String, dynamic> item) =>
              _mapRemoteAsLocal(item, ownerUserId: ownerUserId),
        )
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
  Future<List<LocalRideSession>> listPendingSyncSessions() async {
    final String? ownerUserId = _currentUserIdOrNull;
    if (ownerUserId == null || ownerUserId.isEmpty) {
      return const <LocalRideSession>[];
    }
    return _localDatabase.listPendingSyncSessions(ownerUserId: ownerUserId);
  }

  @override
  Future<SessionDetail> getSessionDetail(int localSessionId) async {
    final LocalRideSession session = await _requireSession(localSessionId);
    final List<LocalSessionPoint> points =
        await _localDatabase.listPoints(localSessionId);
    final List<LocalSessionPoint> accepted = points
        .where((LocalSessionPoint point) => point.acceptedForAnalytics)
        .toList(growable: false);
    final List<TrackingDiagnosticEvent> diagnostics =
        await _localDatabase.listTrackingDiagnostics(localSessionId);

    return SessionDetail(
      session: session,
      points: points,
      acceptedPoints: accepted,
      trackingDiagnostics: diagnostics,
    );
  }

  @override
  Future<void> recordTrackingDiagnostic(
    int localSessionId, {
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) {
    return _localDatabase.insertTrackingDiagnostic(
      localSessionId: localSessionId,
      eventType: eventType,
      message: message,
      details: details,
    );
  }

  @override
  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit = 120,
  }) {
    return _localDatabase.listTrackingDiagnostics(
      localSessionId,
      limit: limit,
    );
  }

  @override
  Future<int> unsyncedCount() {
    final String? ownerUserId = _currentUserIdOrNull;
    if (ownerUserId == null || ownerUserId.isEmpty) {
      return Future<int>.value(0);
    }
    return _localDatabase.unsyncedCount(ownerUserId: ownerUserId);
  }

  Future<LocalRideSession> _requireSession(int localSessionId) async {
    final LocalRideSession? session =
        await _tryGetScopedSession(localSessionId);
    if (session == null) {
      throw StateError('Session not found: $localSessionId');
    }
    return session;
  }

  Future<LocalRideSession?> _tryGetScopedSession(int localSessionId) {
    final String ownerUserId = _requireCurrentUserId();
    return _localDatabase.getSessionById(
      localSessionId,
      ownerUserId: ownerUserId,
    );
  }

  String? get _currentUserIdOrNull {
    final String? currentUserId = _currentUserIdGetter();
    if (currentUserId == null || currentUserId.isEmpty) {
      return null;
    }
    return currentUserId;
  }

  String _requireCurrentUserId() {
    final String? currentUserId = _currentUserIdOrNull;
    if (currentUserId == null) {
      throw StateError('Authenticated user is required for session access.');
    }
    return currentUserId;
  }

  int _computeActiveDurationSeconds(List<LocalSessionPoint> points) {
    final List<LocalSessionPoint> accepted = points
        .where((LocalSessionPoint point) => point.acceptedForAnalytics)
        .toList(growable: false);
    if (accepted.length < 2) {
      return 0;
    }

    final int maxDeltaMilliseconds = SessionConstants.maxDeltaSeconds * 1000;
    int totalMilliseconds = 0;
    for (int index = 1; index < accepted.length; index++) {
      final int deltaMilliseconds = accepted[index]
          .recordedAt
          .difference(accepted[index - 1].recordedAt)
          .inMilliseconds;
      if (deltaMilliseconds <= 0 || deltaMilliseconds > maxDeltaMilliseconds) {
        continue;
      }
      totalMilliseconds += deltaMilliseconds;
    }
    return (totalMilliseconds / 1000).round();
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

  List<LocalSessionPoint> _dedupeByOffset(List<LocalSessionPoint> points) {
    final Set<int> seenOffsets = <int>{};
    final List<LocalSessionPoint> uniquePoints = <LocalSessionPoint>[];

    for (final LocalSessionPoint point in points) {
      if (seenOffsets.contains(point.tOffsetMs)) {
        continue;
      }
      seenOffsets.add(point.tOffsetMs);
      uniquePoints.add(point);
    }
    return uniquePoints;
  }

  SessionStats _computeStatsFromTrackedPoints({
    required List<LocalSessionPoint> points,
    required int activeDurationS,
  }) {
    final List<LocalSessionPoint> accepted = points
        .where((LocalSessionPoint point) => point.acceptedForAnalytics)
        .toList(growable: false);
    if (accepted.isEmpty) {
      return SessionStats(
        durationS: activeDurationS,
        distanceM: 0,
        maxSpeedMps: 0,
        avgSpeedMps: 0,
        elevationGainM: null,
        elevationLossM: null,
      );
    }

    final double distanceM = _computeDistance(accepted);
    final double robustMaxSpeedMps = _computeRobustMaxSpeed(accepted);
    final (int? gain, int? loss) = _computeElevation(accepted);
    final double avgSpeedMps =
        activeDurationS == 0 ? 0 : distanceM / activeDurationS;
    final double maxSpeedMps = max(robustMaxSpeedMps, avgSpeedMps);

    return SessionStats(
      durationS: activeDurationS,
      distanceM: distanceM,
      maxSpeedMps: maxSpeedMps,
      avgSpeedMps: avgSpeedMps,
      elevationGainM: gain,
      elevationLossM: loss,
    );
  }

  double _computeDistance(List<LocalSessionPoint> points) {
    double distanceM = 0;
    LocalSessionPoint? previous;
    for (final LocalSessionPoint point in points) {
      if (point.distanceDeltaM != null && point.distanceDeltaM! > 0) {
        distanceM += point.distanceDeltaM!;
        previous = point;
        continue;
      }
      if (previous == null) {
        previous = point;
        continue;
      }

      final double startLat = previous.filteredLatitude ?? previous.latitude;
      final double startLng = previous.filteredLongitude ?? previous.longitude;
      final double endLat = point.filteredLatitude ?? point.latitude;
      final double endLng = point.filteredLongitude ?? point.longitude;

      final double segmentDistance =
          haversineDistanceMeters(startLat, startLng, endLat, endLng);
      if (segmentDistance > 0) {
        distanceM += segmentDistance;
      }
      previous = point;
    }
    return distanceM;
  }

  double _computeRobustMaxSpeed(List<LocalSessionPoint> points) {
    return _computeWindowedMaxSpeed(
      points,
      highConfidenceOnly: true,
    );
  }

  double _computeWindowedMaxSpeed(
    List<LocalSessionPoint> points, {
    required bool highConfidenceOnly,
  }) {
    final List<LocalSessionPoint> sorted = List<LocalSessionPoint>.from(points)
      ..sort((LocalSessionPoint a, LocalSessionPoint b) =>
          a.recordedAt.compareTo(b.recordedAt));

    double maxSpeed = 0;
    final List<_TimedSpeed> window = <_TimedSpeed>[];
    for (final LocalSessionPoint point in sorted) {
      final double? speed =
          point.fusedSpeedMps ?? point.derivedSpeedMps ?? point.speedMps;
      if (speed == null) {
        continue;
      }
      if (speed < 0 || speed > SessionConstants.speedHardCapMetersPerSecond) {
        continue;
      }

      window.add(
        _TimedSpeed(
          time: point.recordedAt,
          speed: speed,
          highConfidence: point.qualityClass == 'accept',
        ),
      );
      window.removeWhere(
        (_TimedSpeed item) =>
            point.recordedAt.difference(item.time).inSeconds >
            SessionConstants.maxSpeedWindowSeconds,
      );

      final Iterable<_TimedSpeed> candidatesWindow = highConfidenceOnly
          ? window.where((_TimedSpeed item) => item.highConfidence)
          : window;
      final List<double> candidates = candidatesWindow
          .map((_TimedSpeed item) => item.speed)
          .toList(growable: false);
      if (candidates.length < SessionConstants.maxSpeedPersistenceSamples) {
        continue;
      }

      candidates.sort();
      final int middle = candidates.length ~/ 2;
      final double median = candidates.length.isOdd
          ? candidates[middle]
          : (candidates[middle - 1] + candidates[middle]) / 2;
      maxSpeed = max(maxSpeed, median);
    }
    return maxSpeed;
  }

  double _sanitizeAvgSpeedForRemote(LocalRideSession session) {
    final double avg = session.avgSpeedMps;
    if (!avg.isFinite || avg < 0) {
      return 0;
    }
    return avg;
  }

  double _sanitizeMaxSpeedForRemote(LocalRideSession session) {
    final double sanitizedAvg = _sanitizeAvgSpeedForRemote(session);
    final double rawMax = session.maxSpeedMps;
    final double sanitizedRawMax =
        (!rawMax.isFinite || rawMax < 0) ? 0 : rawMax;
    return max(sanitizedRawMax, sanitizedAvg);
  }

  (int?, int?) _computeElevation(List<LocalSessionPoint> points) {
    double? previousAltitude;
    int gain = 0;
    int loss = 0;
    for (final LocalSessionPoint point in points) {
      final double? altitude = point.filteredAltitudeM ?? point.altitudeM;
      if (altitude == null) {
        continue;
      }

      if (point.verticalAccuracyM != null &&
          point.verticalAccuracyM! >
              SessionConstants.verticalAccuracyWeakThresholdMeters) {
        continue;
      }

      if (previousAltitude == null) {
        previousAltitude = altitude;
        continue;
      }

      final double threshold = max(
        SessionConstants.verticalHysteresisFloorMeters,
        (point.verticalAccuracyM ??
                SessionConstants.verticalAccuracyWeakThresholdMeters) *
            SessionConstants.verticalHysteresisAccuracyFactor,
      );
      final double delta = altitude - previousAltitude;
      if (delta.abs() < threshold) {
        continue;
      }
      if (delta > 0) {
        gain += delta.round();
      } else {
        loss += delta.abs().round();
      }
      previousAltitude = altitude;
    }

    return (gain == 0 ? null : gain, loss == 0 ? null : loss);
  }

  LocalRideSession _mapRemoteAsLocal(
    Map<String, dynamic> raw, {
    required String ownerUserId,
  }) {
    final String id = raw['id'] as String;
    final Map<String, dynamic>? resortSummary =
        raw['resort'] as Map<String, dynamic>?;

    return LocalRideSession(
      localId: -id.hashCode.abs(),
      ownerUserId: ownerUserId,
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

class _TimedSpeed {
  const _TimedSpeed({
    required this.time,
    required this.speed,
    required this.highConfidence,
  });

  final DateTime time;
  final double speed;
  final bool highConfidence;
}
