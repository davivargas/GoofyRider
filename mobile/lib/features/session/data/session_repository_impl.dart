import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../../core/constants/session_constants.dart';
import '../../../core/network/api_error.dart';
import '../../../core/storage/drift_local_database.dart';
import '../domain/session_models.dart';
import '../domain/session_repository.dart';
import '../domain/session_segmentation.dart';
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
      // Claim the sync attempt up front so a failure anywhere in the remote
      // lifecycle still leaves the local session in a consistent retry state.
      await _localDatabase.beginSyncAttempt(localSessionId);

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
      await _localDatabase.markSyncFailed(localSessionId, error: message);
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

    List<LocalRideSession> local =
        await _localDatabase.listSessions(ownerUserId: ownerUserId);
    final List<Map<String, dynamic>> cachedRemote =
        await _localDatabase.readCachedRemoteSessions(ownerUserId: ownerUserId);

    if (cachedRemote.isNotEmpty &&
        _hasUnhydratedRemoteSessions(local: local, remote: cachedRemote)) {
      await _hydrateRemoteSessionSummaries(
        ownerUserId: ownerUserId,
        remote: cachedRemote,
      );
      local = await _localDatabase.listSessions(ownerUserId: ownerUserId);
    }

    if (local.isNotEmpty || cachedRemote.isNotEmpty) {
      unawaited(refreshRemoteSessionHistoryCache());
      return _mergeHistory(
        local: local,
        remote: cachedRemote,
        ownerUserId: ownerUserId,
      );
    }

    await refreshRemoteSessionHistoryCache();
    final List<LocalRideSession> refreshedLocal =
        await _localDatabase.listSessions(ownerUserId: ownerUserId);
    final List<Map<String, dynamic>> refreshedRemote =
        await _localDatabase.readCachedRemoteSessions(ownerUserId: ownerUserId);
    return _mergeHistory(
      local: refreshedLocal,
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
      await _hydrateRemoteSessionSummaries(
        ownerUserId: ownerUserId,
        remote: remote,
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
          if (!_isHistoryVisibleRemoteSession(item)) {
            return false;
          }
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
    LocalRideSession session = await _requireSession(localSessionId);
    List<LocalSessionPoint> points = await _localDatabase.listPoints(
      localSessionId,
    );
    if (points.isEmpty && _canRestoreRemotePoints(session)) {
      points = await _restoreRemotePoints(session);
      session = await _requireSession(localSessionId);
    }
    final List<LocalSessionPoint> accepted = points
        .where((LocalSessionPoint point) => point.acceptedForAnalytics)
        .toList(growable: false);
    final List<TrackingDiagnosticEvent> diagnostics =
        await _localDatabase.listTrackingDiagnostics(localSessionId);
    final int effectiveDurationS = session.activeDurationS > 0
        ? session.activeDurationS
        : _computeActiveDurationSeconds(points);
    final SessionTimelineAnalysis analysis = analyzeSessionTimeline(
      points: points,
    );
    final SessionStats stats = _buildSessionStats(
      points: points,
      durationS: effectiveDurationS,
      analysis: analysis,
    );

    return SessionDetail(
      session: session,
      points: points,
      acceptedPoints: accepted,
      trackingDiagnostics: diagnostics,
      stats: stats,
      timeline: analysis.segments,
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

  /// Falls back to an unscoped local lookup when auth context has already been
  /// cleared, which lets sync error handling still surface the updated session.
  Future<LocalRideSession?> _tryGetScopedSession(int localSessionId) {
    final String? ownerUserId = _currentUserIdOrNull;
    if (ownerUserId == null) {
      return _localDatabase.getSessionByLocalId(localSessionId);
    }
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

  Future<void> _hydrateRemoteSessionSummaries({
    required String ownerUserId,
    required List<Map<String, dynamic>> remote,
  }) async {
    for (final Map<String, dynamic> raw in remote) {
      if (!_isHistoryVisibleRemoteSession(raw)) {
        continue;
      }
      final String? remoteId = raw['id'] as String?;
      if (remoteId == null || remoteId.isEmpty) {
        continue;
      }

      await _localDatabase.upsertRemoteSessionSummary(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
        startedAt:
            _parseRemoteDateTime(raw['started_at']) ?? DateTime.now().toUtc(),
        endedAt: _parseRemoteDateTime(raw['ended_at']),
        activeDurationS: _remoteIntOrZero(raw['duration_s']),
        distanceM: _remoteDoubleOrZero(raw['distance_m']),
        maxSpeedMps: _remoteDoubleOrZero(raw['max_speed_mps']),
        avgSpeedMps: _remoteDoubleOrZero(raw['avg_speed_mps']),
        elevationGainM: _remoteNullableInt(raw['elevation_gain_m']),
        elevationLossM: _remoteNullableInt(raw['elevation_loss_m']),
        resortId: _remoteSessionResortId(raw),
        createdAt: _parseRemoteDateTime(raw['created_at']) ??
            _parseRemoteDateTime(raw['started_at']),
      );
    }
  }

  bool _hasUnhydratedRemoteSessions({
    required List<LocalRideSession> local,
    required List<Map<String, dynamic>> remote,
  }) {
    final Set<String> localRemoteIds = local
        .map((LocalRideSession session) => session.remoteId)
        .whereType<String>()
        .toSet();
    return remote.any((Map<String, dynamic> item) {
      if (!_isHistoryVisibleRemoteSession(item)) {
        return false;
      }
      final String? remoteId = item['id'] as String?;
      return remoteId != null &&
          remoteId.isNotEmpty &&
          !localRemoteIds.contains(remoteId);
    });
  }

  bool _isHistoryVisibleRemoteSession(Map<String, dynamic> raw) {
    final String? status = (raw['status'] as String?)?.toUpperCase();
    if (status == null || status.isEmpty) {
      return true;
    }
    return status == 'COMPLETED' ||
        status == 'SYNCED' ||
        raw['ended_at'] != null;
  }

  bool _canRestoreRemotePoints(LocalRideSession session) {
    final String? remoteId = session.remoteId;
    return remoteId != null && remoteId.isNotEmpty;
  }

  Future<List<LocalSessionPoint>> _restoreRemotePoints(
    LocalRideSession session,
  ) async {
    final String remoteId = session.remoteId!;
    try {
      final List<Map<String, dynamic>> remotePoints =
          await _api.getRemoteSessionPoints(remoteId);
      await _localDatabase.replaceSessionPoints(
        localSessionId: session.localId,
        points: _mapRemotePoints(
          sessionStartedAt: session.startedAt,
          remotePoints: remotePoints,
        ),
      );
    } on DioException {
      return _localDatabase.listPoints(session.localId);
    }
    return _localDatabase.listPoints(session.localId);
  }

  List<NewSessionPoint> _mapRemotePoints({
    required DateTime sessionStartedAt,
    required List<Map<String, dynamic>> remotePoints,
  }) {
    final List<Map<String, dynamic>> sorted =
        List<Map<String, dynamic>>.from(remotePoints)
          ..sort(
            (Map<String, dynamic> a, Map<String, dynamic> b) =>
                _remoteIntOrZero(a['t_offset_ms'])
                    .compareTo(_remoteIntOrZero(b['t_offset_ms'])),
          );

    return sorted.map((Map<String, dynamic> raw) {
      final int tOffsetMs = _remoteIntOrZero(raw['t_offset_ms']);
      final String? qualityClass = raw['quality_class'] as String?;
      final String? motionState = raw['motion_state'] as String?;
      return NewSessionPoint(
        recordedAt:
            sessionStartedAt.toUtc().add(Duration(milliseconds: tOffsetMs)),
        tOffsetMs: tOffsetMs,
        latitude: _remoteDouble(raw['latitude']),
        longitude: _remoteDouble(raw['longitude']),
        accuracyM: _remoteNullableDouble(raw['accuracy_m']),
        altitudeM: _remoteNullableDouble(raw['altitude_m']),
        speedMps: _remoteNullableDouble(raw['speed_mps']),
        headingDeg: _remoteNullableDouble(raw['heading_deg']),
        acceptedForAnalytics: _remotePointAcceptedForAnalytics(
          qualityClass: qualityClass,
          motionState: motionState,
        ),
        elapsedRealtimeNs: _remoteNullableInt(raw['elapsed_realtime_ns']),
        verticalAccuracyM: _remoteNullableDouble(raw['vertical_accuracy_m']),
        speedAccuracyMps: _remoteNullableDouble(raw['speed_accuracy_mps']),
        bearingAccuracyDeg: _remoteNullableDouble(raw['bearing_accuracy_deg']),
        provider: raw['provider'] as String?,
        isMocked: _remoteNullableBool(raw['is_mocked']),
        qualityClass: qualityClass,
        qualityScore: _remoteNullableDouble(raw['quality_score']),
        qualityReason: raw['quality_reason'] as String?,
        filteredLatitude: _remoteNullableDouble(raw['filtered_latitude']),
        filteredLongitude: _remoteNullableDouble(raw['filtered_longitude']),
        filteredAltitudeM: _remoteNullableDouble(raw['filtered_altitude_m']),
        fusedSpeedMps: _remoteNullableDouble(raw['fused_speed_mps']),
        derivedSpeedMps: _remoteNullableDouble(raw['derived_speed_mps']),
        distanceDeltaM: _remoteNullableDouble(raw['distance_delta_m']),
        motionState: motionState,
      );
    }).toList(growable: false);
  }

  bool _remotePointAcceptedForAnalytics({
    required String? qualityClass,
    required String? motionState,
  }) {
    if (qualityClass != null && qualityClass.isNotEmpty) {
      return qualityClass != 'reject';
    }
    if (motionState == 'low_confidence_recovery') {
      return false;
    }
    return true;
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
    final SessionTimelineAnalysis analysis = analyzeSessionTimeline(
      points: points,
    );
    return _buildSessionStats(
      points: points,
      durationS: activeDurationS,
      analysis: analysis,
    );
  }

  SessionStats _buildSessionStats({
    required List<LocalSessionPoint> points,
    required int durationS,
    required SessionTimelineAnalysis analysis,
  }) {
    final List<LocalSessionPoint> accepted = points
        .where((LocalSessionPoint point) => point.acceptedForAnalytics)
        .toList(growable: false);
    if (accepted.isEmpty) {
      return SessionStats(
        durationS: durationS,
        distanceM: 0,
        maxSpeedMps: 0,
        avgSpeedMps: 0,
        elevationGainM: null,
        elevationLossM: null,
      );
    }

    final double robustMaxSpeedMps = _computeRobustMaxSpeed(accepted);
    final (int? gain, int? loss) = _computeElevation(accepted);
    final double avgSpeedMps =
        durationS == 0 ? 0 : analysis.distanceM / durationS;
    final double maxSpeedMps = max(robustMaxSpeedMps, avgSpeedMps);

    return SessionStats(
      durationS: durationS,
      distanceM: analysis.distanceM,
      maxSpeedMps: maxSpeedMps,
      avgSpeedMps: avgSpeedMps,
      elevationGainM: gain,
      elevationLossM: loss,
      descentDurationS: analysis.descentDurationS,
      liftDurationS: analysis.liftDurationS,
      idleDurationS: analysis.idleDurationS,
      descentDistanceM: analysis.descentDistanceM,
      liftDistanceM: analysis.liftDistanceM,
      idleDistanceM: analysis.idleDistanceM,
    );
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
    final DateTime startedAt =
        _parseRemoteDateTime(raw['started_at']) ?? DateTime.now().toUtc();

    return LocalRideSession(
      localId: -id.hashCode.abs(),
      ownerUserId: ownerUserId,
      remoteId: id,
      resortId: _remoteSessionResortId(raw),
      startedAt: startedAt,
      endedAt: _parseRemoteDateTime(raw['ended_at']),
      activeDurationS: _remoteIntOrZero(raw['duration_s']),
      distanceM: _remoteDoubleOrZero(raw['distance_m']),
      maxSpeedMps: _remoteDoubleOrZero(raw['max_speed_mps']),
      avgSpeedMps: _remoteDoubleOrZero(raw['avg_speed_mps']),
      elevationGainM: _remoteNullableInt(raw['elevation_gain_m']),
      elevationLossM: _remoteNullableInt(raw['elevation_loss_m']),
      state: LocalSessionState.synced,
      pointCount: 0,
      syncAttemptCount: 0,
      lastSyncError: null,
      createdAt: _parseRemoteDateTime(raw['created_at']) ?? startedAt,
      updatedAt: _parseRemoteDateTime(raw['ended_at']) ?? startedAt,
    );
  }

  String? _remoteSessionResortId(Map<String, dynamic> raw) {
    final Map<String, dynamic>? resortSummary =
        raw['resort'] as Map<String, dynamic>?;
    return resortSummary?['id'] as String? ?? raw['resort_id'] as String?;
  }

  DateTime? _parseRemoteDateTime(Object? value) {
    if (value == null) {
      return null;
    }
    return DateTime.parse(value.toString()).toUtc();
  }

  int _remoteIntOrZero(Object? value) {
    return _remoteNullableInt(value) ?? 0;
  }

  int? _remoteNullableInt(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }

  double _remoteDouble(Object? value) {
    final double? parsed = _remoteNullableDouble(value);
    if (parsed == null) {
      throw StateError('Expected remote numeric value, got $value');
    }
    return parsed;
  }

  double _remoteDoubleOrZero(Object? value) {
    return _remoteNullableDouble(value) ?? 0;
  }

  double? _remoteNullableDouble(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString());
  }

  bool? _remoteNullableBool(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is bool) {
      return value;
    }
    final int? integerValue = _remoteNullableInt(value);
    if (integerValue != null) {
      return integerValue == 1;
    }
    final String normalized = value.toString().trim().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
    return null;
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
