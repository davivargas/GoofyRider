import 'package:drift/drift.dart';

import '../../../features/session/domain/session_models.dart';
import '../drift_local_database.dart';
import '_db_type_helpers.dart' as h;

/// Data-access object for local ride sessions.
///
/// All methods that previously lived on [DriftLocalDatabase] for session
/// CRUD are now here.  The database class keeps thin `@Deprecated` forwarding
/// stubs so that existing call-sites continue to compile.
class SessionDao {
  SessionDao(this._db);
  final DriftLocalDatabase _db;

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<int> insertLocalSession({
    required DateTime startedAt,
    required String ownerUserId,
    String? resortId,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    return _db.customInsert(
      '''
      INSERT INTO local_ride_sessions (
        owner_user_id,
        resort_id,
        started_at,
        state,
        created_at,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
        Variable<String>(resortId),
        Variable<String>(startedAt.toUtc().toIso8601String()),
        Variable<String>(LocalSessionState.recording.wireValue),
        Variable<String>(now.toIso8601String()),
        Variable<String>(now.toIso8601String()),
      ],
    );
  }

  Future<void> updateSessionState(
    int localId,
    LocalSessionState newState, {
    String? remoteId,
    String? lastSyncError,
  }) async {
    final LocalSessionState canonicalState =
        _canonicalPersistedState(newState);
    final DateTime now = DateTime.now().toUtc();
    await _db.customUpdate(
      '''
      UPDATE local_ride_sessions
      SET state = ?,
          remote_id = COALESCE(?, remote_id),
          last_sync_error = ?,
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<String>(canonicalState.wireValue),
        Variable<String>(remoteId),
        Variable<String>(lastSyncError),
        Variable<String>(now.toIso8601String()),
        Variable<int>(localId),
      ],
    );
  }

  /// Moves a session into `syncing` and bumps the attempt counter in one write
  /// so retry bookkeeping cannot drift between separate updates.
  Future<void> beginSyncAttempt(int localId) async {
    final DateTime now = DateTime.now().toUtc();
    await _db.customUpdate(
      '''
      UPDATE local_ride_sessions
      SET state = ?,
          sync_attempt_count = sync_attempt_count + 1,
          last_sync_error = NULL,
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<String>(LocalSessionState.syncing.wireValue),
        Variable<String>(now.toIso8601String()),
        Variable<int>(localId),
      ],
    );
  }

  Future<void> incrementSyncAttempt(
    int localId, {
    String? error,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await _db.customUpdate(
      '''
      UPDATE local_ride_sessions
      SET sync_attempt_count = sync_attempt_count + 1,
          last_sync_error = ?,
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<String>(error),
        Variable<String>(now.toIso8601String()),
        Variable<int>(localId),
      ],
    );
  }

  /// Records a failed sync without incrementing the counter again because the
  /// attempt was already counted when `beginSyncAttempt` started it.
  Future<void> markSyncFailed(
    int localId, {
    required String error,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await _db.customUpdate(
      '''
      UPDATE local_ride_sessions
      SET state = ?,
          last_sync_error = ?,
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<String>(LocalSessionState.syncFailed.wireValue),
        Variable<String>(error),
        Variable<String>(now.toIso8601String()),
        Variable<int>(localId),
      ],
    );
  }

  Future<void> completeLocalSession({
    required int localId,
    required DateTime endedAt,
    required SessionStats stats,
    String? resortId,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await _db.customUpdate(
      '''
      UPDATE local_ride_sessions
      SET ended_at = ?,
          active_duration_s = ?,
          distance_m = ?,
          max_speed_mps = ?,
          avg_speed_mps = ?,
          elevation_gain_m = ?,
          elevation_loss_m = ?,
          resort_id = COALESCE(?, resort_id),
          state = ?,
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<String>(endedAt.toUtc().toIso8601String()),
        Variable<int>(stats.durationS),
        Variable<double>(stats.distanceM),
        Variable<double>(stats.maxSpeedMps),
        Variable<double>(stats.avgSpeedMps),
        Variable<int>(stats.elevationGainM),
        Variable<int>(stats.elevationLossM),
        Variable<String>(resortId),
        Variable<String>(LocalSessionState.syncPending.wireValue),
        Variable<String>(now.toIso8601String()),
        Variable<int>(localId),
      ],
    );
  }

  Future<void> updateSessionResortId({
    required int localId,
    required String ownerUserId,
    required String resortId,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await _db.customUpdate(
      '''
      UPDATE local_ride_sessions
      SET resort_id = ?,
          updated_at = ?
      WHERE local_id = ?
      AND owner_user_id = ?
      ''',
      variables: <Variable>[
        Variable<String>(resortId),
        Variable<String>(now.toIso8601String()),
        Variable<int>(localId),
        Variable<String>(ownerUserId),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Future<LocalRideSession?> getSessionById(
    int localId, {
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_ride_sessions
      WHERE local_id = ?
      AND owner_user_id = ?
      ''',
      variables: <Variable>[
        Variable<int>(localId),
        Variable<String>(ownerUserId),
      ],
    ).get();

    if (rows.isEmpty) {
      return null;
    }
    return _mapSession(rows.first);
  }

  Future<LocalRideSession?> getSessionByLocalId(int localId) async {
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_ride_sessions
      WHERE local_id = ?
      LIMIT 1
      ''',
      variables: <Variable>[
        Variable<int>(localId),
      ],
    ).get();

    if (rows.isEmpty) {
      return null;
    }
    return _mapSession(rows.first);
  }

  Future<LocalRideSession?> getSessionByRemoteId({
    required String ownerUserId,
    required String remoteId,
  }) async {
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_ride_sessions
      WHERE owner_user_id = ?
      AND remote_id = ?
      ORDER BY local_id DESC
      LIMIT 1
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
        Variable<String>(remoteId),
      ],
    ).get();

    if (rows.isEmpty) {
      return null;
    }
    return _mapSession(rows.first);
  }

  Future<LocalRideSession?> getInProgressSession({
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_ride_sessions
      WHERE owner_user_id = ?
      AND state IN ('recording', 'paused')
      ORDER BY updated_at DESC
      LIMIT 1
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
      ],
    ).get();

    if (rows.isEmpty) {
      return null;
    }
    return _mapSession(rows.first);
  }

  Future<List<LocalRideSession>> listSessions({
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_ride_sessions
      WHERE owner_user_id = ?
      ORDER BY started_at DESC
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
      ],
    ).get();

    return rows.map(_mapSession).toList(growable: false);
  }

  Future<List<LocalRideSession>> listPendingSyncSessions({
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_ride_sessions
      WHERE owner_user_id = ?
      AND state IN ('syncPending', 'syncing', 'syncFailed')
      ORDER BY updated_at DESC
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
      ],
    ).get();

    return rows.map(_mapSession).toList(growable: false);
  }

  Future<int> unsyncedCount({
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT COUNT(*) AS count_value
      FROM local_ride_sessions
      WHERE owner_user_id = ?
      AND state IN ('syncPending', 'syncing', 'syncFailed')
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
      ],
    ).get();

    if (rows.isEmpty) {
      return 0;
    }
    return h.asInt(rows.first.data['count_value']);
  }

  // ---------------------------------------------------------------------------
  // Cascade delete
  // ---------------------------------------------------------------------------

  Future<bool> deleteSessionCascade({
    required int localSessionId,
    required String ownerUserId,
    String? remoteId,
    bool clearDeletedRemoteSessionTombstone = true,
    bool? clearPendingRemoteSessionDelete,
  }) async {
    final bool shouldClearPendingRemoteDelete =
        clearPendingRemoteSessionDelete ?? clearDeletedRemoteSessionTombstone;
    int deletedSessions = 0;
    await _db.transaction(() async {
      await _db.customStatement(
        '''
        DELETE FROM local_session_tracking_diagnostics
        WHERE local_session_id = ?
        ''',
        <Object?>[localSessionId],
      );

      await _db.customStatement(
        '''
        DELETE FROM local_session_points
        WHERE local_session_id = ?
        ''',
        <Object?>[localSessionId],
      );

      deletedSessions = await _db.customUpdate(
        '''
        DELETE FROM local_ride_sessions
        WHERE local_id = ?
        AND owner_user_id = ?
        ''',
        variables: <Variable>[
          Variable<int>(localSessionId),
          Variable<String>(ownerUserId),
        ],
      );

      final String? trimmedRemoteId = remoteId?.trim();
      if (trimmedRemoteId != null && trimmedRemoteId.isNotEmpty) {
        await _db.customStatement(
          '''
          DELETE FROM cached_remote_session_summaries
          WHERE owner_user_id = ?
          AND remote_id = ?
          ''',
          <Object?>[
            ownerUserId,
            trimmedRemoteId,
          ],
        );
        if (shouldClearPendingRemoteDelete) {
          await _db.customStatement(
            '''
            DELETE FROM pending_remote_session_deletes
            WHERE owner_user_id = ?
            AND remote_id = ?
            ''',
            <Object?>[
              ownerUserId,
              trimmedRemoteId,
            ],
          );
        }
      }
    });

    return deletedSessions > 0;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  LocalSessionState _canonicalPersistedState(LocalSessionState state) {
    if (state == LocalSessionState.locallyCompleted) {
      return LocalSessionState.syncPending;
    }
    return state;
  }

  LocalRideSession _mapSession(QueryRow row) {
    final Map<String, Object?> data = row.data;

    return LocalRideSession(
      localId: h.asInt(data['local_id']),
      ownerUserId: data['owner_user_id'] as String?,
      remoteId: data['remote_id'] as String?,
      resortId: data['resort_id'] as String?,
      startedAt: DateTime.parse(data['started_at'] as String).toUtc(),
      endedAt: data['ended_at'] == null
          ? null
          : DateTime.parse(data['ended_at'] as String).toUtc(),
      activeDurationS: h.asInt(data['active_duration_s']),
      distanceM: h.asDouble(data['distance_m']),
      maxSpeedMps: h.asDouble(data['max_speed_mps']),
      avgSpeedMps: h.asDouble(data['avg_speed_mps']),
      elevationGainM: data['elevation_gain_m'] == null
          ? null
          : h.asInt(data['elevation_gain_m']),
      elevationLossM: data['elevation_loss_m'] == null
          ? null
          : h.asInt(data['elevation_loss_m']),
      state: LocalSessionStateCodec.fromWire(data['state'] as String),
      pointCount: h.asInt(data['point_count']),
      syncAttemptCount: h.asInt(data['sync_attempt_count']),
      lastSyncError: data['last_sync_error'] as String?,
      createdAt: DateTime.parse(data['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(data['updated_at'] as String).toUtc(),
    );
  }
}
