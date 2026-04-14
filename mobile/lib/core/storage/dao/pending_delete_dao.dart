import 'package:drift/drift.dart';

import '../drift_local_database.dart';
import '_db_type_helpers.dart' as h;

/// Data-access object for the pending remote session deletes table.
class PendingDeleteDao {
  PendingDeleteDao(this._db);
  final DriftLocalDatabase _db;

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<void> enqueuePendingRemoteSessionDelete({
    required String ownerUserId,
    required String remoteId,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.customStatement(
      '''
      INSERT INTO pending_remote_session_deletes (
        owner_user_id,
        remote_id,
        requested_at,
        last_attempt_at,
        attempt_count,
        last_error,
        state,
        next_attempt_at
      )
      VALUES (?, ?, ?, NULL, 0, NULL, 'pending', NULL)
      ON CONFLICT(owner_user_id, remote_id)
      DO UPDATE SET
        requested_at = excluded.requested_at,
        last_attempt_at = NULL,
        attempt_count = 0,
        last_error = NULL,
        state = 'pending',
        next_attempt_at = NULL
      ''',
      <Object?>[
        ownerUserId,
        remoteId,
        now.toIso8601String(),
      ],
    );
  }

  Future<void> recordPendingRemoteSessionDeleteAttempt({
    required String ownerUserId,
    required String remoteId,
    required String lastError,
    DateTime? nextAttemptAt,
  }) async {
    final now = DateTime.now().toUtc();
    final effectiveNextAttemptAt = (nextAttemptAt ?? now).toUtc();
    await _db.customStatement(
      '''
      INSERT INTO pending_remote_session_deletes (
        owner_user_id,
        remote_id,
        requested_at,
        last_attempt_at,
        attempt_count,
        last_error,
        state,
        next_attempt_at
      )
      VALUES (?, ?, ?, ?, 1, ?, 'pending', ?)
      ON CONFLICT(owner_user_id, remote_id)
      DO UPDATE SET
        last_attempt_at = excluded.last_attempt_at,
        attempt_count = pending_remote_session_deletes.attempt_count + 1,
        last_error = excluded.last_error,
        state = 'pending',
        next_attempt_at = excluded.next_attempt_at
      ''',
      <Object?>[
        ownerUserId,
        remoteId,
        now.toIso8601String(),
        now.toIso8601String(),
        lastError,
        effectiveNextAttemptAt.toIso8601String(),
      ],
    );
  }

  Future<void> markPendingRemoteSessionDeleteFailed({
    required String ownerUserId,
    required String remoteId,
    required String lastError,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.customStatement(
      '''
      INSERT INTO pending_remote_session_deletes (
        owner_user_id,
        remote_id,
        requested_at,
        last_attempt_at,
        attempt_count,
        last_error,
        state,
        next_attempt_at
      )
      VALUES (?, ?, ?, ?, 1, ?, 'failed', NULL)
      ON CONFLICT(owner_user_id, remote_id)
      DO UPDATE SET
        last_attempt_at = excluded.last_attempt_at,
        attempt_count = pending_remote_session_deletes.attempt_count + 1,
        last_error = excluded.last_error,
        state = 'failed',
        next_attempt_at = NULL
      ''',
      <Object?>[
        ownerUserId,
        remoteId,
        now.toIso8601String(),
        now.toIso8601String(),
        lastError,
      ],
    );
  }

  Future<void> clearPendingRemoteSessionDelete({
    required String ownerUserId,
    required String remoteId,
  }) async {
    await _db.customStatement(
      '''
      DELETE FROM pending_remote_session_deletes
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

  Future<Set<String>> listPendingRemoteSessionDeleteIds({
    required String ownerUserId,
  }) async {
    final rows = await _db.customSelect(
      '''
      SELECT remote_id
      FROM pending_remote_session_deletes
      WHERE owner_user_id = ?
      AND state = 'pending'
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
      ],
    ).get();

    return rows.map((QueryRow row) => row.data['remote_id'] as String).toSet();
  }

  Future<List<String>> listPendingRemoteDeleteIds({
    required String ownerUserId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final rows = await _db.customSelect(
      '''
      SELECT remote_id
      FROM pending_remote_session_deletes
      WHERE owner_user_id = ?
      AND state = 'pending'
      AND (
        next_attempt_at IS NULL
        OR next_attempt_at <= ?
      )
      ORDER BY requested_at ASC
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
        Variable<String>(now),
      ],
    ).get();

    return rows
        .map((QueryRow row) => row.data['remote_id'] as String)
        .toList(growable: false);
  }

  Future<List<PendingRemoteSessionDeleteEntry>>
      listRetryablePendingRemoteDeletes({
    required String ownerUserId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final rows = await _db.customSelect(
      '''
      SELECT owner_user_id, remote_id, attempt_count
      FROM pending_remote_session_deletes
      WHERE owner_user_id = ?
      AND state = 'pending'
      AND (
        next_attempt_at IS NULL
        OR next_attempt_at <= ?
      )
      ORDER BY requested_at ASC
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
        Variable<String>(now),
      ],
    ).get();

    return rows
        .map(
          (QueryRow row) => PendingRemoteSessionDeleteEntry(
            ownerUserId: row.data['owner_user_id'] as String,
            remoteId: row.data['remote_id'] as String,
            attemptCount: h.asInt(row.data['attempt_count']),
          ),
        )
        .toList(growable: false);
  }
}
