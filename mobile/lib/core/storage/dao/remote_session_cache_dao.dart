import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../features/session/domain/session_models.dart';
import '../drift_local_database.dart';

/// Data-access object for the cached remote session summaries table.
class RemoteSessionCacheDao {
  RemoteSessionCacheDao(this._db);
  final DriftLocalDatabase _db;

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<int> upsertRemoteSessionSummary({
    required String ownerUserId,
    required String remoteId,
    required DateTime startedAt,
    required DateTime? endedAt,
    required int activeDurationS,
    required double distanceM,
    required double maxSpeedMps,
    required double avgSpeedMps,
    required int? elevationGainM,
    required int? elevationLossM,
    required String? resortId,
    DateTime? createdAt,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.customStatement(
      '''
      INSERT INTO local_ride_sessions (
        owner_user_id,
        remote_id,
        resort_id,
        started_at,
        ended_at,
        active_duration_s,
        distance_m,
        max_speed_mps,
        avg_speed_mps,
        elevation_gain_m,
        elevation_loss_m,
        state,
        point_count,
        sync_attempt_count,
        last_sync_error,
        created_at,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(owner_user_id, remote_id)
      DO UPDATE SET
        resort_id = excluded.resort_id,
        started_at = excluded.started_at,
        ended_at = excluded.ended_at,
        active_duration_s = excluded.active_duration_s,
        distance_m = excluded.distance_m,
        max_speed_mps = excluded.max_speed_mps,
        avg_speed_mps = excluded.avg_speed_mps,
        elevation_gain_m = excluded.elevation_gain_m,
        elevation_loss_m = excluded.elevation_loss_m,
        state = excluded.state,
        last_sync_error = NULL,
        updated_at = excluded.updated_at
      ''',
      <Object?>[
        ownerUserId,
        remoteId,
        resortId,
        startedAt.toUtc().toIso8601String(),
        endedAt?.toUtc().toIso8601String(),
        activeDurationS,
        distanceM,
        maxSpeedMps,
        avgSpeedMps,
        elevationGainM,
        elevationLossM,
        LocalSessionState.synced.wireValue,
        0,
        0,
        null,
        (createdAt ?? now).toUtc().toIso8601String(),
        now.toIso8601String(),
      ],
    );

    final persisted =
        await _db.sessions.getSessionByRemoteId(
      ownerUserId: ownerUserId,
      remoteId: remoteId,
    );
    if (persisted == null) {
      throw StateError('Remote-backed session summary was not persisted.');
    }
    return persisted.localId;
  }

  Future<void> replaceCachedRemoteSessions({
    required String ownerUserId,
    required List<Map<String, dynamic>> sessions,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.transaction(() async {
      await _db.customStatement(
        'DELETE FROM cached_remote_session_summaries WHERE owner_user_id = ?',
        <Object?>[ownerUserId],
      );

      for (final session in sessions) {
        final remoteId = session['id'] as String?;
        if (remoteId == null || remoteId.isEmpty) {
          continue;
        }

        await _db.customStatement(
          '''
          INSERT INTO cached_remote_session_summaries (
            owner_user_id,
            remote_id,
            payload_json,
            fetched_at
          ) VALUES (?, ?, ?, ?)
          ''',
          <Object?>[
            ownerUserId,
            remoteId,
            jsonEncode(session),
            now.toIso8601String(),
          ],
        );
      }
    });
  }

  Future<void> deleteCachedRemoteSessionSummary({
    required String ownerUserId,
    required String remoteId,
  }) async {
    await _db.customStatement(
      '''
      DELETE FROM cached_remote_session_summaries
      WHERE owner_user_id = ?
      AND remote_id = ?
      ''',
      <Object?>[
        ownerUserId,
        remoteId,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> readCachedRemoteSessions({
    required String ownerUserId,
  }) async {
    final rows = await _db.customSelect(
      '''
      SELECT payload_json
      FROM cached_remote_session_summaries
      WHERE owner_user_id = ?
      ORDER BY fetched_at DESC
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
      ],
    ).get();

    return rows
        .map(
          (QueryRow row) => jsonDecode(row.data['payload_json'] as String)
              as Map<String, dynamic>,
        )
        .toList(growable: false);
  }

  Future<Map<String, dynamic>?> readCachedRemoteSessionSummary({
    required String ownerUserId,
    required String remoteId,
  }) async {
    final rows = await _db.customSelect(
      '''
      SELECT payload_json
      FROM cached_remote_session_summaries
      WHERE owner_user_id = ?
      AND remote_id = ?
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

    return jsonDecode(rows.first.data['payload_json'] as String)
        as Map<String, dynamic>;
  }
}
