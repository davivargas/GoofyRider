import 'dart:convert';

import 'package:drift/drift.dart';

import '../drift_local_database.dart';

/// Data-access object for the cached-weather table.
class WeatherCacheDao {
  WeatherCacheDao(this._db);
  final DriftLocalDatabase _db;

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<void> upsertCachedWeather(
    String resortId,
    Map<String, dynamic> payload,
  ) async {
    final now = DateTime.now().toUtc();
    await _db.customStatement(
      '''
      INSERT INTO cached_weather (resort_id, payload_json, fetched_at)
      VALUES (?, ?, ?)
      ON CONFLICT(resort_id)
      DO UPDATE SET
        payload_json = excluded.payload_json,
        fetched_at = excluded.fetched_at
      ''',
      <Object?>[
        resortId,
        jsonEncode(payload),
        now.toIso8601String(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>?> readCachedWeather(String resortId) async {
    final rows = await _db.customSelect(
      'SELECT * FROM cached_weather WHERE resort_id = ?',
      variables: <Variable>[Variable<String>(resortId)],
    ).get();

    if (rows.isEmpty) {
      return null;
    }

    final row = rows.first;
    final payload =
        jsonDecode(row.data['payload_json'] as String) as Map<String, dynamic>;
    payload['cached_fetched_at'] = row.data['fetched_at'];
    return payload;
  }

  Future<List<Map<String, dynamic>>> readCachedWeatherMetadata() async {
    final rows = await _db.customSelect(
      '''
      SELECT resort_id, payload_json, fetched_at
      FROM cached_weather
      ORDER BY fetched_at DESC
      ''',
    ).get();

    return rows.map((QueryRow row) {
      final payloadJson = row.data['payload_json'] as String;
      final payload =
          jsonDecode(payloadJson) as Map<String, dynamic>;
      return <String, dynamic>{
        'resort_id': row.data['resort_id'],
        'cached_fetched_at': row.data['fetched_at'],
        'payload_size_bytes': payloadJson.length,
        'payload_keys': payload.keys.toList(growable: false),
      };
    }).toList(growable: false);
  }
}
