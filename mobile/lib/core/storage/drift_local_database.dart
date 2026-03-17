import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../features/session/domain/session_models.dart';

class DriftLocalDatabase extends GeneratedDatabase {
  DriftLocalDatabase._(super.connection) : super.connect();

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables =>
      const <TableInfo<Table, dynamic>>[];

  static const String _dbFileName = 'goofyrider_local.sqlite';

  static Future<DriftLocalDatabase> open() async {
    final Directory directory = await getApplicationDocumentsDirectory();
    final File file = File(path.join(directory.path, _dbFileName));
    final DatabaseConnection connection =
        DatabaseConnection(NativeDatabase(file));

    final DriftLocalDatabase database = DriftLocalDatabase._(connection);
    await database.initialize();
    return database;
  }

  Future<void> initialize() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS local_ride_sessions (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_id TEXT,
        resort_id TEXT,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        active_duration_s INTEGER NOT NULL DEFAULT 0,
        distance_m REAL NOT NULL DEFAULT 0,
        max_speed_mps REAL NOT NULL DEFAULT 0,
        avg_speed_mps REAL NOT NULL DEFAULT 0,
        elevation_gain_m INTEGER,
        elevation_loss_m INTEGER,
        state TEXT NOT NULL,
        point_count INTEGER NOT NULL DEFAULT 0,
        sync_attempt_count INTEGER NOT NULL DEFAULT 0,
        last_sync_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_ride_sessions_state_updated
      ON local_ride_sessions(state, updated_at DESC)
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS local_session_points (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_session_id INTEGER NOT NULL,
        recorded_at TEXT NOT NULL,
        t_offset_ms INTEGER NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        accuracy_m REAL,
        altitude_m REAL,
        speed_mps REAL,
        heading_deg REAL,
        accepted_for_analytics INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(local_session_id) REFERENCES local_ride_sessions(local_id)
      )
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_session_points_session_offset
      ON local_session_points(local_session_id, t_offset_ms)
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS cached_resorts (
        resort_id TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        fetched_at TEXT NOT NULL
      )
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS cached_weather (
        resort_id TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        fetched_at TEXT NOT NULL
      )
    ''');
  }

  Future<int> insertLocalSession({
    required DateTime startedAt,
    String? resortId,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    return customInsert(
      '''
      INSERT INTO local_ride_sessions (
        resort_id,
        started_at,
        state,
        created_at,
        updated_at
      ) VALUES (?, ?, ?, ?, ?)
      ''',
      variables: <Variable>[
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
    final DateTime now = DateTime.now().toUtc();
    await customUpdate(
      '''
      UPDATE local_ride_sessions
      SET state = ?,
          remote_id = COALESCE(?, remote_id),
          last_sync_error = ?,
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<String>(newState.wireValue),
        Variable<String>(remoteId),
        Variable<String>(lastSyncError),
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
    await customUpdate(
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

  Future<void> completeLocalSession({
    required int localId,
    required DateTime endedAt,
    required SessionStats stats,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await customUpdate(
      '''
      UPDATE local_ride_sessions
      SET ended_at = ?,
          active_duration_s = ?,
          distance_m = ?,
          max_speed_mps = ?,
          avg_speed_mps = ?,
          elevation_gain_m = ?,
          elevation_loss_m = ?,
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
        Variable<String>(LocalSessionState.syncPending.wireValue),
        Variable<String>(now.toIso8601String()),
        Variable<int>(localId),
      ],
    );
  }

  Future<void> insertPoint({
    required int localSessionId,
    required NewSessionPoint point,
  }) async {
    final DateTime now = DateTime.now().toUtc();

    await customInsert(
      '''
      INSERT INTO local_session_points (
        local_session_id,
        recorded_at,
        t_offset_ms,
        latitude,
        longitude,
        accuracy_m,
        altitude_m,
        speed_mps,
        heading_deg,
        accepted_for_analytics,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
        Variable<String>(point.recordedAt.toUtc().toIso8601String()),
        Variable<int>(point.tOffsetMs),
        Variable<double>(point.latitude),
        Variable<double>(point.longitude),
        Variable<double>(point.accuracyM),
        Variable<double>(point.altitudeM),
        Variable<double>(point.speedMps),
        Variable<double>(point.headingDeg),
        Variable<int>(point.acceptedForAnalytics ? 1 : 0),
        Variable<String>(now.toIso8601String()),
      ],
    );

    await customUpdate(
      '''
      UPDATE local_ride_sessions
      SET point_count = point_count + 1,
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<String>(now.toIso8601String()),
        Variable<int>(localSessionId),
      ],
    );
  }

  Future<LocalRideSession?> getSessionById(int localId) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT * FROM local_ride_sessions WHERE local_id = ?',
      variables: <Variable>[Variable<int>(localId)],
    ).get();

    if (rows.isEmpty) {
      return null;
    }
    return _mapSession(rows.first);
  }

  Future<LocalRideSession?> getInProgressSession() async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT *
      FROM local_ride_sessions
      WHERE state IN ('recording', 'paused')
      ORDER BY updated_at DESC
      LIMIT 1
      ''',
    ).get();

    if (rows.isEmpty) {
      return null;
    }
    return _mapSession(rows.first);
  }

  Future<List<LocalRideSession>> listSessions() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT * FROM local_ride_sessions ORDER BY started_at DESC',
    ).get();

    return rows.map(_mapSession).toList(growable: false);
  }

  Future<int> unsyncedCount() async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT COUNT(*) AS count_value
      FROM local_ride_sessions
      WHERE state IN ('locallyCompleted', 'syncPending', 'syncing', 'syncFailed')
      ''',
    ).get();

    if (rows.isEmpty) {
      return 0;
    }
    return _asInt(rows.first.data['count_value']);
  }

  Future<List<LocalSessionPoint>> listPoints(
    int localSessionId, {
    bool onlyAccepted = false,
  }) async {
    final String acceptedClause =
        onlyAccepted ? 'AND accepted_for_analytics = 1' : '';
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT *
      FROM local_session_points
      WHERE local_session_id = ?
      $acceptedClause
      ORDER BY recorded_at ASC
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
      ],
    ).get();

    return rows.map(_mapPoint).toList(growable: false);
  }

  Future<void> upsertCachedResort(
    String resortId,
    Map<String, dynamic> payload,
  ) async {
    final DateTime now = DateTime.now().toUtc();
    await customStatement(
      '''
      INSERT INTO cached_resorts (resort_id, payload_json, fetched_at)
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

  Future<Map<String, dynamic>?> readCachedResort(String resortId) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT * FROM cached_resorts WHERE resort_id = ?',
      variables: <Variable>[Variable<String>(resortId)],
    ).get();

    if (rows.isEmpty) {
      return null;
    }

    final QueryRow row = rows.first;
    final Map<String, dynamic> payload =
        jsonDecode(row.data['payload_json'] as String) as Map<String, dynamic>;
    payload['cached_fetched_at'] = row.data['fetched_at'];
    return payload;
  }

  Future<List<Map<String, dynamic>>> readCachedResorts() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT * FROM cached_resorts ORDER BY fetched_at DESC',
    ).get();

    return rows.map((QueryRow row) {
      final Map<String, dynamic> payload =
          jsonDecode(row.data['payload_json'] as String)
              as Map<String, dynamic>;
      payload['cached_fetched_at'] = row.data['fetched_at'];
      return payload;
    }).toList(growable: false);
  }

  Future<void> upsertCachedWeather(
    String resortId,
    Map<String, dynamic> payload,
  ) async {
    final DateTime now = DateTime.now().toUtc();
    await customStatement(
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

  Future<Map<String, dynamic>?> readCachedWeather(String resortId) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT * FROM cached_weather WHERE resort_id = ?',
      variables: <Variable>[Variable<String>(resortId)],
    ).get();

    if (rows.isEmpty) {
      return null;
    }

    final QueryRow row = rows.first;
    final Map<String, dynamic> payload =
        jsonDecode(row.data['payload_json'] as String) as Map<String, dynamic>;
    payload['cached_fetched_at'] = row.data['fetched_at'];
    return payload;
  }

  Future<void> clearCaches() async {
    await customStatement('DELETE FROM cached_weather');
    await customStatement('DELETE FROM cached_resorts');
  }

  LocalRideSession _mapSession(QueryRow row) {
    final Map<String, Object?> data = row.data;

    return LocalRideSession(
      localId: _asInt(data['local_id']),
      remoteId: data['remote_id'] as String?,
      resortId: data['resort_id'] as String?,
      startedAt: DateTime.parse(data['started_at'] as String).toUtc(),
      endedAt: data['ended_at'] == null
          ? null
          : DateTime.parse(data['ended_at'] as String).toUtc(),
      activeDurationS: _asInt(data['active_duration_s']),
      distanceM: _asDouble(data['distance_m']),
      maxSpeedMps: _asDouble(data['max_speed_mps']),
      avgSpeedMps: _asDouble(data['avg_speed_mps']),
      elevationGainM: data['elevation_gain_m'] == null
          ? null
          : _asInt(data['elevation_gain_m']),
      elevationLossM: data['elevation_loss_m'] == null
          ? null
          : _asInt(data['elevation_loss_m']),
      state: LocalSessionStateCodec.fromWire(data['state'] as String),
      pointCount: _asInt(data['point_count']),
      syncAttemptCount: _asInt(data['sync_attempt_count']),
      lastSyncError: data['last_sync_error'] as String?,
      createdAt: DateTime.parse(data['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(data['updated_at'] as String).toUtc(),
    );
  }

  LocalSessionPoint _mapPoint(QueryRow row) {
    final Map<String, Object?> data = row.data;
    return LocalSessionPoint(
      id: _asInt(data['id']),
      localSessionId: _asInt(data['local_session_id']),
      recordedAt: DateTime.parse(data['recorded_at'] as String).toUtc(),
      tOffsetMs: _asInt(data['t_offset_ms']),
      latitude: _asDouble(data['latitude']),
      longitude: _asDouble(data['longitude']),
      accuracyM: _asNullableDouble(data['accuracy_m']),
      altitudeM: _asNullableDouble(data['altitude_m']),
      speedMps: _asNullableDouble(data['speed_mps']),
      headingDeg: _asNullableDouble(data['heading_deg']),
      acceptedForAnalytics: _asInt(data['accepted_for_analytics']) == 1,
    );
  }

  int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.parse(value.toString());
  }

  double _asDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.parse(value.toString());
  }

  double? _asNullableDouble(Object? value) {
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
}
