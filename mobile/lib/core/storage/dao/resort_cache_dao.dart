import 'dart:convert';

import 'package:drift/drift.dart';

import '../drift_local_database.dart';

/// Data-access object for the cached-resorts table.
class ResortCacheDao {
  ResortCacheDao(this._db);
  final DriftLocalDatabase _db;

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<void> upsertCachedResort(
    String resortId,
    Map<String, dynamic> payload, {
    String? ownerUserId,
  }) async {
    final String effectiveOwnerUserId =
        _normalizeCachedResortOwnerUserId(ownerUserId);
    final Map<String, dynamic> payloadToPersist = _prepareCachedResortPayload(
      payload,
      allowFavoriteState: effectiveOwnerUserId.isNotEmpty,
    );
    final DateTime now = DateTime.now().toUtc();
    await _db.customStatement(
      '''
      INSERT INTO cached_resorts (
        owner_user_id,
        resort_id,
        payload_json,
        fetched_at
      )
      VALUES (?, ?, ?, ?)
      ON CONFLICT(owner_user_id, resort_id)
      DO UPDATE SET
        payload_json = excluded.payload_json,
        fetched_at = excluded.fetched_at
      ''',
      <Object?>[
        effectiveOwnerUserId,
        resortId,
        jsonEncode(payloadToPersist),
        now.toIso8601String(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>?> readCachedResort(
    String resortId, {
    String? ownerUserId,
  }) async {
    final String effectiveOwnerUserId =
        _normalizeCachedResortOwnerUserId(ownerUserId);
    final List<QueryRow> rows;
    if (effectiveOwnerUserId.isEmpty) {
      rows = await _db.customSelect(
        '''
        SELECT owner_user_id, resort_id, payload_json, fetched_at
        FROM cached_resorts
        WHERE owner_user_id = ''
        AND resort_id = ?
        ORDER BY fetched_at DESC
        LIMIT 1
        ''',
        variables: <Variable>[Variable<String>(resortId)],
      ).get();
    } else {
      rows = await _db.customSelect(
        '''
        SELECT owner_user_id, resort_id, payload_json, fetched_at
        FROM cached_resorts
        WHERE resort_id = ?
        AND owner_user_id IN (?, '')
        ORDER BY CASE WHEN owner_user_id = ? THEN 0 ELSE 1 END,
                 fetched_at DESC
        LIMIT 1
        ''',
        variables: <Variable>[
          Variable<String>(resortId),
          Variable<String>(effectiveOwnerUserId),
          Variable<String>(effectiveOwnerUserId),
        ],
      ).get();
    }

    if (rows.isEmpty) {
      return null;
    }

    return _mapCachedResortRow(rows.first);
  }

  Future<List<Map<String, dynamic>>> readCachedResorts({
    String? ownerUserId,
  }) async {
    final String effectiveOwnerUserId =
        _normalizeCachedResortOwnerUserId(ownerUserId);
    final List<QueryRow> rows;
    if (effectiveOwnerUserId.isEmpty) {
      rows = await _db.customSelect(
        '''
        SELECT owner_user_id, resort_id, payload_json, fetched_at
        FROM cached_resorts
        WHERE owner_user_id = ''
        ORDER BY fetched_at DESC
        ''',
      ).get();
      return rows.map(_mapCachedResortRow).toList(growable: false);
    }

    rows = await _db.customSelect(
      '''
      SELECT owner_user_id, resort_id, payload_json, fetched_at
      FROM cached_resorts
      WHERE owner_user_id IN (?, '')
      ORDER BY resort_id ASC,
               CASE WHEN owner_user_id = ? THEN 0 ELSE 1 END,
               fetched_at DESC
      ''',
      variables: <Variable>[
        Variable<String>(effectiveOwnerUserId),
        Variable<String>(effectiveOwnerUserId),
      ],
    ).get();

    final Map<String, Map<String, dynamic>> deduped =
        <String, Map<String, dynamic>>{};
    for (final QueryRow row in rows) {
      final String resortId = row.data['resort_id'] as String;
      deduped.putIfAbsent(resortId, () => _mapCachedResortRow(row));
    }

    final List<Map<String, dynamic>> cached =
        deduped.values.toList(growable: false);
    cached.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final String aFetchedAt = a['cached_fetched_at'] as String? ?? '';
      final String bFetchedAt = b['cached_fetched_at'] as String? ?? '';
      return bFetchedAt.compareTo(aFetchedAt);
    });
    return cached;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  String _normalizeCachedResortOwnerUserId(String? ownerUserId) {
    final String? trimmed = ownerUserId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return '';
    }
    return trimmed;
  }

  Map<String, dynamic> _prepareCachedResortPayload(
    Map<String, dynamic> payload, {
    required bool allowFavoriteState,
  }) {
    final Map<String, dynamic> sanitized = Map<String, dynamic>.from(payload)
      ..remove('cached_fetched_at');
    if (!allowFavoriteState) {
      sanitized['is_favorite'] = false;
    }
    return sanitized;
  }

  Map<String, dynamic> _mapCachedResortRow(QueryRow row) {
    final String ownerUserId =
        (row.data['owner_user_id'] as String? ?? '').trim();
    final Map<String, dynamic> payload =
        jsonDecode(row.data['payload_json'] as String) as Map<String, dynamic>;
    if (ownerUserId.isEmpty) {
      payload['is_favorite'] = false;
    }
    payload['cached_fetched_at'] = row.data['fetched_at'];
    return payload;
  }
}
