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
    _stateMachine.transition(session.state, LocalSessionState.syncPending);

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
    LocalRideSession? syncingSnapshot;

    try {
      await _prepareSyncAttempt(localSessionId);

      final LocalRideSession syncing = await _requireSession(localSessionId);
      final String remoteId =
          await _ensureRemoteSessionId(localSessionId, syncing);
      await _syncPointsForSession(
        localSessionId: localSessionId,
        remoteSessionId: remoteId,
      );
      await _completeSessionSync(
        localSessionId: localSessionId,
        remoteSessionId: remoteId,
      );

      await _localDatabase.updateSessionState(
          localSessionId, LocalSessionState.synced);
      return _requireSession(localSessionId);
    } on DioException catch (exception) {
      final String message = mapDioException(exception).message;
      await _localDatabase.markSyncFailed(localSessionId, error: message);
      final LocalRideSession? failed =
          await _tryGetScopedSession(localSessionId);
      if (failed != null) {
        return failed;
      }
      return _buildSyncFailedSnapshot(syncingSnapshot ?? original, message);
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

  Future<void> _prepareSyncAttempt(int localSessionId) async {
    await _localDatabase.updateSessionState(
      localSessionId,
      LocalSessionState.syncing,
      lastSyncError: null,
    );
    await _localDatabase.incrementSyncAttempt(localSessionId);
  }

  Future<String> _ensureRemoteSessionId(
    int localSessionId,
    LocalRideSession session,
  ) async {
    String? remoteId = session.remoteId;
    if (remoteId != null && remoteId.isNotEmpty) {
      return remoteId;
    }

    final Map<String, dynamic> draft = await _api.createRemoteDraft(
      resortId: session.resortId,
      startedAt: session.startedAt,
    );
    remoteId = draft['id'] as String;
    await _localDatabase.updateSessionState(
      localSessionId,
      LocalSessionState.syncing,
      remoteId: remoteId,
    );
    return remoteId;
  }

  Future<void> _syncPointsForSession({
    required int localSessionId,
    required String remoteSessionId,
  }) async {
    final List<LocalSessionPoint> acceptedPoints =
        await _localDatabase.listPoints(localSessionId, onlyAccepted: true);
    final Set<int> existingOffsets =
        await _fetchExistingRemoteOffsets(remoteSessionId);
    final List<LocalSessionPoint> uploadable = acceptedPoints
        .where((LocalSessionPoint point) =>
            !existingOffsets.contains(point.tOffsetMs))
        .toList(growable: false);
    final List<LocalSessionPoint> dedupedUploadable = _dedupeByOffset(
      uploadable,
    );
    final _PointSanitizationResult sanitizedResult = _sanitizePointsForSync(
      dedupedUploadable,
    );
    await _recordPointSanitizationDiagnostics(
      localSessionId: localSessionId,
      result: sanitizedResult,
    );

    int isolationFallbackBatches = 0;
    final List<_DroppedSyncPoint> droppedDuringIsolation =
        <_DroppedSyncPoint>[];
    for (int index = 0;
        index < sanitizedResult.uploadablePoints.length;
        index += SessionConstants.uploadBatchSize) {
      final int end = min(
        index + SessionConstants.uploadBatchSize,
        sanitizedResult.uploadablePoints.length,
      );
      final List<_SanitizedSyncPoint> batch =
          sanitizedResult.uploadablePoints.sublist(index, end);
      final _PointUploadResult uploadResult =
          await _uploadPointBatchWithFallback(
        localSessionId: localSessionId,
        remoteSessionId: remoteSessionId,
        batch: batch,
        batchIndex: (index ~/ SessionConstants.uploadBatchSize) + 1,
      );
      if (uploadResult.usedIsolationFallback) {
        isolationFallbackBatches += 1;
      }
      droppedDuringIsolation.addAll(uploadResult.droppedPoints);
    }

    if (isolationFallbackBatches > 0 || droppedDuringIsolation.isNotEmpty) {
      final Map<String, int> dropReasonCounts =
          _collectDropReasonCounts(droppedDuringIsolation);
      await _recordSyncDiagnosticBestEffort(
        localSessionId,
        eventType: 'sync_points_partial_drop',
        message: 'Point batch isolation applied during sync upload.',
        details: <String, dynamic>{
          'isolation_batches': isolationFallbackBatches,
          'dropped_points': droppedDuringIsolation.length,
          'drop_reasons': dropReasonCounts,
          'dropped_offsets_sample': droppedDuringIsolation
              .take(5)
              .map((_DroppedSyncPoint dropped) => dropped.point.tOffsetMs)
              .toList(growable: false),
        },
      );
    }
  }

  Future<_PointUploadResult> _uploadPointBatchWithFallback({
    required int localSessionId,
    required String remoteSessionId,
    required List<_SanitizedSyncPoint> batch,
    required int batchIndex,
  }) async {
    if (batch.isEmpty) {
      return const _PointUploadResult(
        usedIsolationFallback: false,
        droppedPoints: <_DroppedSyncPoint>[],
      );
    }

    try {
      await _uploadSanitizedPoints(
        remoteSessionId: remoteSessionId,
        points: batch,
      );
      return const _PointUploadResult(
        usedIsolationFallback: false,
        droppedPoints: <_DroppedSyncPoint>[],
      );
    } on DioException catch (exception) {
      if (!_isLikelyValidationFailure(exception)) {
        rethrow;
      }
      await _recordSyncDiagnosticBestEffort(
        localSessionId,
        eventType: 'sync_points_batch_isolation_retry',
        message: 'Validation-style error detected while uploading batch.',
        details: <String, dynamic>{
          'batch_index': batchIndex,
          'batch_size': batch.length,
          'error': mapDioException(exception).message,
        },
      );

      final _PointUploadResult isolationResult = await _uploadBatchByIsolation(
        remoteSessionId: remoteSessionId,
        points: batch,
      );
      return _PointUploadResult(
        usedIsolationFallback: true,
        droppedPoints: isolationResult.droppedPoints,
      );
    }
  }

  Future<void> _uploadSanitizedPoints({
    required String remoteSessionId,
    required List<_SanitizedSyncPoint> points,
  }) {
    return _api.uploadPointBatch(
      remoteSessionId: remoteSessionId,
      points: points
          .map((_SanitizedSyncPoint point) => point.payload)
          .toList(growable: false),
    );
  }

  Future<_PointUploadResult> _uploadBatchByIsolation({
    required String remoteSessionId,
    required List<_SanitizedSyncPoint> points,
  }) async {
    if (points.isEmpty) {
      return const _PointUploadResult(
        usedIsolationFallback: true,
        droppedPoints: <_DroppedSyncPoint>[],
      );
    }

    try {
      await _uploadSanitizedPoints(
        remoteSessionId: remoteSessionId,
        points: points,
      );
      return const _PointUploadResult(
        usedIsolationFallback: true,
        droppedPoints: <_DroppedSyncPoint>[],
      );
    } on DioException catch (exception) {
      if (!_isLikelyValidationFailure(exception)) {
        rethrow;
      }

      if (points.length == 1) {
        return _PointUploadResult(
          usedIsolationFallback: true,
          droppedPoints: <_DroppedSyncPoint>[
            _DroppedSyncPoint(
              point: points.first.original,
              reason: 'remote_validation_rejected_point',
            ),
          ],
        );
      }

      final int midpoint = points.length ~/ 2;
      final _PointUploadResult left = await _uploadBatchByIsolation(
        remoteSessionId: remoteSessionId,
        points: points.sublist(0, midpoint),
      );
      final _PointUploadResult right = await _uploadBatchByIsolation(
        remoteSessionId: remoteSessionId,
        points: points.sublist(midpoint),
      );
      return _PointUploadResult(
        usedIsolationFallback: true,
        droppedPoints: <_DroppedSyncPoint>[
          ...left.droppedPoints,
          ...right.droppedPoints,
        ],
      );
    }
  }

  _PointSanitizationResult _sanitizePointsForSync(
    List<LocalSessionPoint> points,
  ) {
    final List<_SanitizedSyncPoint> uploadable = <_SanitizedSyncPoint>[];
    final List<_DroppedSyncPoint> droppedPoints = <_DroppedSyncPoint>[];
    final Map<String, int> sanitizedFieldCounts = <String, int>{};
    int sanitizedPointCount = 0;

    for (final LocalSessionPoint point in points) {
      final _SinglePointSanitizationResult pointResult =
          _sanitizeSinglePointForSync(point);
      if (pointResult.dropped != null) {
        droppedPoints.add(pointResult.dropped!);
        continue;
      }
      final _SanitizedSyncPoint sanitized = pointResult.sanitized!;
      uploadable.add(sanitized);

      if (sanitized.sanitizedFields.isEmpty) {
        continue;
      }
      sanitizedPointCount += 1;
      for (final String field in sanitized.sanitizedFields) {
        sanitizedFieldCounts[field] = (sanitizedFieldCounts[field] ?? 0) + 1;
      }
    }

    return _PointSanitizationResult(
      candidateCount: points.length,
      uploadablePoints: uploadable,
      droppedPoints: droppedPoints,
      sanitizedPointCount: sanitizedPointCount,
      sanitizedFieldCounts: sanitizedFieldCounts,
    );
  }

  _SinglePointSanitizationResult _sanitizeSinglePointForSync(
    LocalSessionPoint point,
  ) {
    if (!point.latitude.isFinite || !point.longitude.isFinite) {
      return _SinglePointSanitizationResult.drop(
        point,
        reason: 'invalid_required_coordinates',
      );
    }
    if (point.latitude < -90 || point.latitude > 90) {
      return _SinglePointSanitizationResult.drop(
        point,
        reason: 'latitude_out_of_range',
      );
    }
    if (point.longitude < -180 || point.longitude > 180) {
      return _SinglePointSanitizationResult.drop(
        point,
        reason: 'longitude_out_of_range',
      );
    }

    final List<String> sanitizedFields = <String>[];
    final Map<String, dynamic> payload = <String, dynamic>{
      't_offset_ms': _sanitizeNonNegativeIntForSync(
        point.tOffsetMs,
        fieldName: 't_offset_ms',
        sanitizedFields: sanitizedFields,
      ),
      'latitude': point.latitude,
      'longitude': point.longitude,
      'accuracy_m': _sanitizeNullableNonNegativeDoubleForSync(
        point.accuracyM,
        fieldName: 'accuracy_m',
        sanitizedFields: sanitizedFields,
      ),
      'elapsed_realtime_ns': _sanitizeNullableNonNegativeIntForSync(
        point.elapsedRealtimeNs,
        fieldName: 'elapsed_realtime_ns',
        sanitizedFields: sanitizedFields,
      ),
      'altitude_m': _sanitizeNullableNonNegativeDoubleForSync(
        point.altitudeM,
        fieldName: 'altitude_m',
        sanitizedFields: sanitizedFields,
      ),
      'vertical_accuracy_m': _sanitizeNullableNonNegativeDoubleForSync(
        point.verticalAccuracyM,
        fieldName: 'vertical_accuracy_m',
        sanitizedFields: sanitizedFields,
      ),
      'speed_mps': _sanitizeNullableNonNegativeDoubleForSync(
        point.speedMps,
        fieldName: 'speed_mps',
        sanitizedFields: sanitizedFields,
      ),
      'speed_accuracy_mps': _sanitizeNullableNonNegativeDoubleForSync(
        point.speedAccuracyMps,
        fieldName: 'speed_accuracy_mps',
        sanitizedFields: sanitizedFields,
      ),
      'heading_deg': _normalizeHeadingForSync(
        point.headingDeg,
        fieldName: 'heading_deg',
        sanitizedFields: sanitizedFields,
      ),
      'bearing_accuracy_deg': _sanitizeNullableNonNegativeDoubleForSync(
        point.bearingAccuracyDeg,
        fieldName: 'bearing_accuracy_deg',
        sanitizedFields: sanitizedFields,
      ),
      'provider': point.provider,
      'is_mocked': point.isMocked,
      'quality_class': point.qualityClass,
      'quality_score': _sanitizeNullableNonNegativeDoubleForSync(
        point.qualityScore,
        fieldName: 'quality_score',
        sanitizedFields: sanitizedFields,
      ),
      'quality_reason': point.qualityReason,
      'filtered_latitude': _sanitizeNullableFiniteDoubleForSync(
        point.filteredLatitude,
        fieldName: 'filtered_latitude',
        sanitizedFields: sanitizedFields,
      ),
      'filtered_longitude': _sanitizeNullableFiniteDoubleForSync(
        point.filteredLongitude,
        fieldName: 'filtered_longitude',
        sanitizedFields: sanitizedFields,
      ),
      'filtered_altitude_m': _sanitizeNullableNonNegativeDoubleForSync(
        point.filteredAltitudeM,
        fieldName: 'filtered_altitude_m',
        sanitizedFields: sanitizedFields,
      ),
      'fused_speed_mps': _sanitizeNullableNonNegativeDoubleForSync(
        point.fusedSpeedMps,
        fieldName: 'fused_speed_mps',
        sanitizedFields: sanitizedFields,
      ),
      'derived_speed_mps': _sanitizeNullableNonNegativeDoubleForSync(
        point.derivedSpeedMps,
        fieldName: 'derived_speed_mps',
        sanitizedFields: sanitizedFields,
      ),
      'distance_delta_m': _sanitizeNullableNonNegativeDoubleForSync(
        point.distanceDeltaM,
        fieldName: 'distance_delta_m',
        sanitizedFields: sanitizedFields,
      ),
      'motion_state': point.motionState,
    };

    return _SinglePointSanitizationResult.keep(
      _SanitizedSyncPoint(
        original: point,
        payload: payload,
        sanitizedFields: _dedupeSanitizedFields(sanitizedFields),
      ),
    );
  }

  Future<void> _recordPointSanitizationDiagnostics({
    required int localSessionId,
    required _PointSanitizationResult result,
  }) async {
    if (result.sanitizedPointCount == 0 && result.droppedPoints.isEmpty) {
      return;
    }
    await _recordSyncDiagnosticBestEffort(
      localSessionId,
      eventType: 'sync_points_sanitized',
      message: 'Sanitized sync-only point payload before upload.',
      details: <String, dynamic>{
        'candidate_points': result.candidateCount,
        'uploadable_points': result.uploadablePoints.length,
        'sanitized_points': result.sanitizedPointCount,
        'sanitized_fields': result.sanitizedFieldCounts,
        'dropped_points': result.droppedPoints.length,
        'drop_reasons': _collectDropReasonCounts(result.droppedPoints),
        'dropped_offsets_sample': result.droppedPoints
            .take(5)
            .map((_DroppedSyncPoint dropped) => dropped.point.tOffsetMs)
            .toList(growable: false),
      },
    );
  }

  Map<String, int> _collectDropReasonCounts(List<_DroppedSyncPoint> dropped) {
    final Map<String, int> reasonCounts = <String, int>{};
    for (final _DroppedSyncPoint point in dropped) {
      reasonCounts[point.reason] = (reasonCounts[point.reason] ?? 0) + 1;
    }
    return reasonCounts;
  }

  Future<void> _completeSessionSync({
    required int localSessionId,
    required String remoteSessionId,
  }) async {
    final LocalRideSession syncing = await _requireSession(localSessionId);
    final _SanitizedCompletionPayload payload =
        _sanitizeCompletionPayloadForSync(syncing);
    if (payload.sanitizedFields.isNotEmpty) {
      await _recordSyncDiagnosticBestEffort(
        localSessionId,
        eventType: 'sync_completion_sanitized',
        message: 'Sanitized completion payload before remote completion.',
        details: <String, dynamic>{
          'sanitized_fields': payload.sanitizedFields,
        },
      );
    }

    await _api.completeRemoteSession(
      remoteSessionId: remoteSessionId,
      endedAt: payload.endedAt,
      durationS: payload.durationS,
      distanceM: payload.distanceM,
      maxSpeedMps: payload.maxSpeedMps,
      avgSpeedMps: payload.avgSpeedMps,
      elevationGainM: payload.elevationGainM,
      elevationLossM: payload.elevationLossM,
    );
  }

  _SanitizedCompletionPayload _sanitizeCompletionPayloadForSync(
    LocalRideSession session,
  ) {
    final List<String> sanitizedFields = <String>[];
    final int durationS = _sanitizeNonNegativeIntForSync(
      session.activeDurationS,
      fieldName: 'duration_s',
      sanitizedFields: sanitizedFields,
    );
    final double distanceM = _sanitizeNonNegativeDoubleForSync(
      session.distanceM,
      fieldName: 'distance_m',
      sanitizedFields: sanitizedFields,
    );
    final double avgSpeedMps = _sanitizeNonNegativeDoubleForSync(
      session.avgSpeedMps,
      fieldName: 'avg_speed_mps',
      sanitizedFields: sanitizedFields,
    );
    final double rawMaxSpeedMps = _sanitizeNonNegativeDoubleForSync(
      session.maxSpeedMps,
      fieldName: 'max_speed_mps',
      sanitizedFields: sanitizedFields,
    );
    final double maxSpeedMps = max(rawMaxSpeedMps, avgSpeedMps);
    if (maxSpeedMps != rawMaxSpeedMps) {
      sanitizedFields.add('max_speed_mps_adjusted_to_avg');
    }

    return _SanitizedCompletionPayload(
      endedAt: session.endedAt ?? DateTime.now().toUtc(),
      durationS: durationS,
      distanceM: distanceM,
      avgSpeedMps: avgSpeedMps,
      maxSpeedMps: maxSpeedMps,
      elevationGainM: _sanitizeNullableNonNegativeIntForSync(
        session.elevationGainM,
        fieldName: 'elevation_gain_m',
        sanitizedFields: sanitizedFields,
      ),
      elevationLossM: _sanitizeNullableNonNegativeIntForSync(
        session.elevationLossM,
        fieldName: 'elevation_loss_m',
        sanitizedFields: sanitizedFields,
      ),
      sanitizedFields: _dedupeSanitizedFields(sanitizedFields),
    );
  }

  int _sanitizeNonNegativeIntForSync(
    int value, {
    required String fieldName,
    required List<String> sanitizedFields,
  }) {
    if (value >= 0) {
      return value;
    }
    sanitizedFields.add(fieldName);
    return 0;
  }

  int? _sanitizeNullableNonNegativeIntForSync(
    int? value, {
    required String fieldName,
    required List<String> sanitizedFields,
  }) {
    if (value == null) {
      return null;
    }
    if (value >= 0) {
      return value;
    }
    sanitizedFields.add(fieldName);
    return null;
  }

  double _sanitizeNonNegativeDoubleForSync(
    double value, {
    required String fieldName,
    required List<String> sanitizedFields,
  }) {
    if (value.isFinite && value >= 0) {
      return value;
    }
    sanitizedFields.add(fieldName);
    return 0;
  }

  double? _sanitizeNullableFiniteDoubleForSync(
    double? value, {
    required String fieldName,
    required List<String> sanitizedFields,
  }) {
    if (value == null) {
      return null;
    }
    if (value.isFinite) {
      return value;
    }
    sanitizedFields.add(fieldName);
    return null;
  }

  double? _sanitizeNullableNonNegativeDoubleForSync(
    double? value, {
    required String fieldName,
    required List<String> sanitizedFields,
  }) {
    final double? finiteValue = _sanitizeNullableFiniteDoubleForSync(
      value,
      fieldName: fieldName,
      sanitizedFields: sanitizedFields,
    );
    if (finiteValue == null) {
      return null;
    }
    if (finiteValue >= 0) {
      return finiteValue;
    }
    sanitizedFields.add(fieldName);
    return null;
  }

  double? _normalizeHeadingForSync(
    double? headingDeg, {
    required String fieldName,
    required List<String> sanitizedFields,
  }) {
    final double? finiteHeading = _sanitizeNullableFiniteDoubleForSync(
      headingDeg,
      fieldName: fieldName,
      sanitizedFields: sanitizedFields,
    );
    if (finiteHeading == null) {
      return null;
    }

    double normalized = finiteHeading % 360;
    if (normalized < 0) {
      normalized += 360;
    }
    if ((normalized - finiteHeading).abs() > 1e-9) {
      sanitizedFields.add(fieldName);
    }
    return normalized;
  }

  List<String> _dedupeSanitizedFields(List<String> fields) {
    return fields.toSet().toList(growable: false);
  }

  bool _isLikelyValidationFailure(DioException exception) {
    final int? statusCode = exception.response?.statusCode;
    final String combined = <String>[
      mapDioException(exception).message,
      exception.response?.data?.toString() ?? '',
    ].join(' ').toLowerCase();

    if (statusCode == 422) {
      return true;
    }
    if (statusCode == 400 &&
        (combined.contains('validation') ||
            combined.contains('input should') ||
            combined.contains('greater than or equal to') ||
            combined.contains('ge=0'))) {
      return true;
    }
    return combined.contains('greater than or equal to') ||
        combined.contains('input should') ||
        combined.contains('ge=0');
  }

  Future<void> _recordSyncDiagnosticBestEffort(
    int localSessionId, {
    required String eventType,
    required String message,
    required Map<String, dynamic> details,
  }) async {
    try {
      await _localDatabase.insertTrackingDiagnostic(
        localSessionId: localSessionId,
        eventType: eventType,
        message: message,
        details: details,
      );
    } catch (_) {
      return;
    }
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
    final String? ownerUserId = _currentUserIdOrNull;
    if (ownerUserId == null) {
      return Future<LocalRideSession?>.value(null);
    }
    return _localDatabase.getSessionById(
      localSessionId,
      ownerUserId: ownerUserId,
    );
  }

  LocalRideSession _buildSyncFailedSnapshot(
    LocalRideSession base,
    String message,
  ) {
    return LocalRideSession(
      localId: base.localId,
      ownerUserId: base.ownerUserId,
      remoteId: base.remoteId,
      resortId: base.resortId,
      startedAt: base.startedAt,
      endedAt: base.endedAt,
      activeDurationS: base.activeDurationS,
      distanceM: base.distanceM,
      maxSpeedMps: base.maxSpeedMps,
      avgSpeedMps: base.avgSpeedMps,
      elevationGainM: base.elevationGainM,
      elevationLossM: base.elevationLossM,
      state: LocalSessionState.syncFailed,
      pointCount: base.pointCount,
      syncAttemptCount: base.syncAttemptCount,
      lastSyncError: message,
      createdAt: base.createdAt,
      updatedAt: base.updatedAt,
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

class _SanitizedCompletionPayload {
  const _SanitizedCompletionPayload({
    required this.endedAt,
    required this.durationS,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.elevationGainM,
    required this.elevationLossM,
    required this.sanitizedFields,
  });

  final DateTime endedAt;
  final int durationS;
  final double distanceM;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final int? elevationGainM;
  final int? elevationLossM;
  final List<String> sanitizedFields;
}

class _PointSanitizationResult {
  const _PointSanitizationResult({
    required this.candidateCount,
    required this.uploadablePoints,
    required this.droppedPoints,
    required this.sanitizedPointCount,
    required this.sanitizedFieldCounts,
  });

  final int candidateCount;
  final List<_SanitizedSyncPoint> uploadablePoints;
  final List<_DroppedSyncPoint> droppedPoints;
  final int sanitizedPointCount;
  final Map<String, int> sanitizedFieldCounts;
}

class _SinglePointSanitizationResult {
  const _SinglePointSanitizationResult._({
    required this.sanitized,
    required this.dropped,
  });

  factory _SinglePointSanitizationResult.keep(_SanitizedSyncPoint point) {
    return _SinglePointSanitizationResult._(sanitized: point, dropped: null);
  }

  factory _SinglePointSanitizationResult.drop(
    LocalSessionPoint point, {
    required String reason,
  }) {
    return _SinglePointSanitizationResult._(
      sanitized: null,
      dropped: _DroppedSyncPoint(point: point, reason: reason),
    );
  }

  final _SanitizedSyncPoint? sanitized;
  final _DroppedSyncPoint? dropped;
}

class _SanitizedSyncPoint {
  const _SanitizedSyncPoint({
    required this.original,
    required this.payload,
    required this.sanitizedFields,
  });

  final LocalSessionPoint original;
  final Map<String, dynamic> payload;
  final List<String> sanitizedFields;
}

class _DroppedSyncPoint {
  const _DroppedSyncPoint({
    required this.point,
    required this.reason,
  });

  final LocalSessionPoint point;
  final String reason;
}

class _PointUploadResult {
  const _PointUploadResult({
    required this.usedIsolationFallback,
    required this.droppedPoints,
  });

  final bool usedIsolationFallback;
  final List<_DroppedSyncPoint> droppedPoints;
}
