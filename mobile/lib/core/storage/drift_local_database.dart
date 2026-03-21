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
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator migrator) async {},
        onUpgrade: (Migrator migrator, int from, int to) async {},
      );

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables =>
      const <TableInfo<Table, dynamic>>[];

  static const String _dbFileName = 'goofyrider_local.sqlite';
  static const int _maxTrackingDiagnosticsPerSession = 400;

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
        owner_user_id TEXT,
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
      CREATE INDEX IF NOT EXISTS ix_local_ride_sessions_owner_started
      ON local_ride_sessions(owner_user_id, started_at DESC)
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_ride_sessions_owner_state_updated
      ON local_ride_sessions(owner_user_id, state, updated_at DESC)
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_ride_sessions_owner_remote
      ON local_ride_sessions(owner_user_id, remote_id)
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
        elapsed_realtime_ns INTEGER,
        altitude_m REAL,
        vertical_accuracy_m REAL,
        speed_mps REAL,
        speed_accuracy_mps REAL,
        heading_deg REAL,
        bearing_accuracy_deg REAL,
        provider TEXT,
        is_mocked INTEGER,
        quality_class TEXT,
        quality_score REAL,
        quality_reason TEXT,
        filtered_latitude REAL,
        filtered_longitude REAL,
        filtered_altitude_m REAL,
        fused_speed_mps REAL,
        derived_speed_mps REAL,
        distance_delta_m REAL,
        motion_state TEXT,
        accepted_for_analytics INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(local_session_id) REFERENCES local_ride_sessions(local_id)
      )
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_session_points_session_offset
      ON local_session_points(local_session_id, t_offset_ms)
    ''');

    await _migrateToV2();
    await _migrateToV3();

    await customStatement('''
      CREATE TABLE IF NOT EXISTS local_session_tracking_diagnostics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_session_id INTEGER NOT NULL,
        occurred_at TEXT NOT NULL,
        event_type TEXT NOT NULL,
        message TEXT,
        details_json TEXT,
        FOREIGN KEY(local_session_id) REFERENCES local_ride_sessions(local_id)
      )
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_session_tracking_diag_session_occurred
      ON local_session_tracking_diagnostics(local_session_id, occurred_at DESC)
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

    await customStatement('''
      CREATE TABLE IF NOT EXISTS cached_remote_session_summaries (
        owner_user_id TEXT NOT NULL,
        remote_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        PRIMARY KEY(owner_user_id, remote_id)
      )
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_cached_remote_session_summaries_owner_fetched
      ON cached_remote_session_summaries(owner_user_id, fetched_at DESC)
    ''');
  }

  Future<int> insertLocalSession({
    required DateTime startedAt,
    required String ownerUserId,
    String? resortId,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    return customInsert(
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
        elapsed_realtime_ns,
        altitude_m,
        vertical_accuracy_m,
        speed_mps,
        speed_accuracy_mps,
        heading_deg,
        bearing_accuracy_deg,
        provider,
        is_mocked,
        quality_class,
        quality_score,
        quality_reason,
        filtered_latitude,
        filtered_longitude,
        filtered_altitude_m,
        fused_speed_mps,
        derived_speed_mps,
        distance_delta_m,
        motion_state,
        accepted_for_analytics,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
        Variable<String>(point.recordedAt.toUtc().toIso8601String()),
        Variable<int>(point.tOffsetMs),
        Variable<double>(point.latitude),
        Variable<double>(point.longitude),
        Variable<double>(point.accuracyM),
        Variable<int>(point.elapsedRealtimeNs),
        Variable<double>(point.altitudeM),
        Variable<double>(point.verticalAccuracyM),
        Variable<double>(point.speedMps),
        Variable<double>(point.speedAccuracyMps),
        Variable<double>(point.headingDeg),
        Variable<double>(point.bearingAccuracyDeg),
        Variable<String>(point.provider),
        Variable<int>(
            point.isMocked == null ? null : (point.isMocked! ? 1 : 0)),
        Variable<String>(point.qualityClass),
        Variable<double>(point.qualityScore),
        Variable<String>(point.qualityReason),
        Variable<double>(point.filteredLatitude),
        Variable<double>(point.filteredLongitude),
        Variable<double>(point.filteredAltitudeM),
        Variable<double>(point.fusedSpeedMps),
        Variable<double>(point.derivedSpeedMps),
        Variable<double>(point.distanceDeltaM),
        Variable<String>(point.motionState),
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

  Future<LocalRideSession?> getSessionById(
    int localId, {
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await customSelect(
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

  Future<LocalRideSession?> getSessionByRemoteId({
    required String ownerUserId,
    required String remoteId,
  }) async {
    final List<QueryRow> rows = await customSelect(
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
    final DateTime now = DateTime.now().toUtc();
    final LocalRideSession? existing = await getSessionByRemoteId(
      ownerUserId: ownerUserId,
      remoteId: remoteId,
    );

    if (existing != null) {
      await customUpdate(
        '''
        UPDATE local_ride_sessions
        SET owner_user_id = ?,
            resort_id = ?,
            started_at = ?,
            ended_at = ?,
            active_duration_s = ?,
            distance_m = ?,
            max_speed_mps = ?,
            avg_speed_mps = ?,
            elevation_gain_m = ?,
            elevation_loss_m = ?,
            state = ?,
            last_sync_error = NULL,
            updated_at = ?
        WHERE local_id = ?
        ''',
        variables: <Variable>[
          Variable<String>(ownerUserId),
          Variable<String>(resortId),
          Variable<String>(startedAt.toUtc().toIso8601String()),
          Variable<String>(endedAt?.toUtc().toIso8601String()),
          Variable<int>(activeDurationS),
          Variable<double>(distanceM),
          Variable<double>(maxSpeedMps),
          Variable<double>(avgSpeedMps),
          Variable<int>(elevationGainM),
          Variable<int>(elevationLossM),
          Variable<String>(LocalSessionState.synced.wireValue),
          Variable<String>(now.toIso8601String()),
          Variable<int>(existing.localId),
        ],
      );
      return existing.localId;
    }

    return customInsert(
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
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
        Variable<String>(remoteId),
        Variable<String>(resortId),
        Variable<String>(startedAt.toUtc().toIso8601String()),
        Variable<String>(endedAt?.toUtc().toIso8601String()),
        Variable<int>(activeDurationS),
        Variable<double>(distanceM),
        Variable<double>(maxSpeedMps),
        Variable<double>(avgSpeedMps),
        Variable<int>(elevationGainM),
        Variable<int>(elevationLossM),
        Variable<String>(LocalSessionState.synced.wireValue),
        const Variable<int>(0),
        const Variable<int>(0),
        Variable<String>(null),
        Variable<String>((createdAt ?? now).toUtc().toIso8601String()),
        Variable<String>(now.toIso8601String()),
      ],
    );
  }

  Future<LocalRideSession?> getInProgressSession({
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await customSelect(
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
    final List<QueryRow> rows = await customSelect(
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
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT *
      FROM local_ride_sessions
      WHERE owner_user_id = ?
      AND state IN ('locallyCompleted', 'syncPending', 'syncFailed')
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
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT COUNT(*) AS count_value
      FROM local_ride_sessions
      WHERE owner_user_id = ?
      AND state IN ('locallyCompleted', 'syncPending', 'syncing', 'syncFailed')
      ''',
      variables: <Variable>[
        Variable<String>(ownerUserId),
      ],
    ).get();

    if (rows.isEmpty) {
      return 0;
    }
    return _asInt(rows.first.data['count_value']);
  }

  Future<void> _migrateToV3() async {
    await _addColumnIfMissing('local_ride_sessions', 'owner_user_id TEXT');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_ride_sessions_owner_started
      ON local_ride_sessions(owner_user_id, started_at DESC)
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_ride_sessions_owner_state_updated
      ON local_ride_sessions(owner_user_id, state, updated_at DESC)
    ''');
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

  Future<void> replaceSessionPoints({
    required int localSessionId,
    required List<NewSessionPoint> points,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await transaction(() async {
      await customStatement(
        'DELETE FROM local_session_points WHERE local_session_id = ?',
        <Object?>[localSessionId],
      );

      for (final NewSessionPoint point in points) {
        await customInsert(
          '''
          INSERT INTO local_session_points (
            local_session_id,
            recorded_at,
            t_offset_ms,
            latitude,
            longitude,
            accuracy_m,
            elapsed_realtime_ns,
            altitude_m,
            vertical_accuracy_m,
            speed_mps,
            speed_accuracy_mps,
            heading_deg,
            bearing_accuracy_deg,
            provider,
            is_mocked,
            quality_class,
            quality_score,
            quality_reason,
            filtered_latitude,
            filtered_longitude,
            filtered_altitude_m,
            fused_speed_mps,
            derived_speed_mps,
            distance_delta_m,
            motion_state,
            accepted_for_analytics,
            created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          variables: <Variable>[
            Variable<int>(localSessionId),
            Variable<String>(point.recordedAt.toUtc().toIso8601String()),
            Variable<int>(point.tOffsetMs),
            Variable<double>(point.latitude),
            Variable<double>(point.longitude),
            Variable<double>(point.accuracyM),
            Variable<int>(point.elapsedRealtimeNs),
            Variable<double>(point.altitudeM),
            Variable<double>(point.verticalAccuracyM),
            Variable<double>(point.speedMps),
            Variable<double>(point.speedAccuracyMps),
            Variable<double>(point.headingDeg),
            Variable<double>(point.bearingAccuracyDeg),
            Variable<String>(point.provider),
            Variable<int>(
              point.isMocked == null ? null : (point.isMocked! ? 1 : 0),
            ),
            Variable<String>(point.qualityClass),
            Variable<double>(point.qualityScore),
            Variable<String>(point.qualityReason),
            Variable<double>(point.filteredLatitude),
            Variable<double>(point.filteredLongitude),
            Variable<double>(point.filteredAltitudeM),
            Variable<double>(point.fusedSpeedMps),
            Variable<double>(point.derivedSpeedMps),
            Variable<double>(point.distanceDeltaM),
            Variable<String>(point.motionState),
            Variable<int>(point.acceptedForAnalytics ? 1 : 0),
            Variable<String>(now.toIso8601String()),
          ],
        );
      }

      await customUpdate(
        '''
        UPDATE local_ride_sessions
        SET point_count = ?,
            updated_at = ?
        WHERE local_id = ?
        ''',
        variables: <Variable>[
          Variable<int>(points.length),
          Variable<String>(now.toIso8601String()),
          Variable<int>(localSessionId),
        ],
      );
    });
  }

  Future<void> _migrateToV2() async {
    await _addColumnIfMissing(
        'local_session_points', 'elapsed_realtime_ns INTEGER');
    await _addColumnIfMissing(
        'local_session_points', 'vertical_accuracy_m REAL');
    await _addColumnIfMissing(
        'local_session_points', 'speed_accuracy_mps REAL');
    await _addColumnIfMissing(
        'local_session_points', 'bearing_accuracy_deg REAL');
    await _addColumnIfMissing('local_session_points', 'provider TEXT');
    await _addColumnIfMissing('local_session_points', 'is_mocked INTEGER');
    await _addColumnIfMissing('local_session_points', 'quality_class TEXT');
    await _addColumnIfMissing('local_session_points', 'quality_score REAL');
    await _addColumnIfMissing('local_session_points', 'quality_reason TEXT');
    await _addColumnIfMissing('local_session_points', 'filtered_latitude REAL');
    await _addColumnIfMissing(
        'local_session_points', 'filtered_longitude REAL');
    await _addColumnIfMissing(
        'local_session_points', 'filtered_altitude_m REAL');
    await _addColumnIfMissing('local_session_points', 'fused_speed_mps REAL');
    await _addColumnIfMissing('local_session_points', 'derived_speed_mps REAL');
    await _addColumnIfMissing('local_session_points', 'distance_delta_m REAL');
    await _addColumnIfMissing('local_session_points', 'motion_state TEXT');
  }

  Future<void> _addColumnIfMissing(String table, String columnDef) async {
    final String columnName = columnDef.split(' ').first;
    final List<QueryRow> rows =
        await customSelect('PRAGMA table_info($table)').get();
    final bool exists = rows.any(
      (QueryRow row) => row.data['name']?.toString() == columnName,
    );
    if (exists) {
      return;
    }
    await customStatement('ALTER TABLE $table ADD COLUMN $columnDef');
  }

  Future<LocalSessionPoint?> latestAcceptedPoint(int localSessionId) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT *
      FROM local_session_points
      WHERE local_session_id = ?
      AND accepted_for_analytics = 1
      ORDER BY recorded_at DESC
      LIMIT 1
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
      ],
    ).get();

    if (rows.isEmpty) {
      return null;
    }
    return _mapPoint(rows.first);
  }

  Future<void> insertTrackingDiagnostic({
    required int localSessionId,
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await customInsert(
      '''
      INSERT INTO local_session_tracking_diagnostics (
        local_session_id,
        occurred_at,
        event_type,
        message,
        details_json
      ) VALUES (?, ?, ?, ?, ?)
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
        Variable<String>(now.toIso8601String()),
        Variable<String>(eventType),
        Variable<String>(message),
        Variable<String>(
          details == null ? null : jsonEncode(details),
        ),
      ],
    );

    await customStatement(
      '''
      DELETE FROM local_session_tracking_diagnostics
      WHERE local_session_id = ?
      AND id NOT IN (
        SELECT id
        FROM local_session_tracking_diagnostics
        WHERE local_session_id = ?
        ORDER BY occurred_at DESC
        LIMIT $_maxTrackingDiagnosticsPerSession
      )
      ''',
      <Object?>[
        localSessionId,
        localSessionId,
      ],
    );
  }

  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit = 120,
  }) async {
    final int safeLimit =
        limit.clamp(1, _maxTrackingDiagnosticsPerSession).toInt();
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT *
      FROM local_session_tracking_diagnostics
      WHERE local_session_id = ?
      ORDER BY occurred_at DESC
      LIMIT ?
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
        Variable<int>(safeLimit),
      ],
    ).get();

    return rows.map(_mapTrackingDiagnostic).toList(growable: false);
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

  Future<void> replaceCachedRemoteSessions({
    required String ownerUserId,
    required List<Map<String, dynamic>> sessions,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await transaction(() async {
      await customStatement(
        'DELETE FROM cached_remote_session_summaries WHERE owner_user_id = ?',
        <Object?>[ownerUserId],
      );

      for (final Map<String, dynamic> session in sessions) {
        final String? remoteId = session['id'] as String?;
        if (remoteId == null || remoteId.isEmpty) {
          continue;
        }

        await customStatement(
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

  Future<List<Map<String, dynamic>>> readCachedRemoteSessions({
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await customSelect(
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

  Future<void> clearCaches() async {
    await customStatement('DELETE FROM cached_weather');
    await customStatement('DELETE FROM cached_resorts');
  }

  LocalRideSession _mapSession(QueryRow row) {
    final Map<String, Object?> data = row.data;

    return LocalRideSession(
      localId: _asInt(data['local_id']),
      ownerUserId: data['owner_user_id'] as String?,
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
      elapsedRealtimeNs: _asNullableInt(data['elapsed_realtime_ns']),
      verticalAccuracyM: _asNullableDouble(data['vertical_accuracy_m']),
      speedAccuracyMps: _asNullableDouble(data['speed_accuracy_mps']),
      bearingAccuracyDeg: _asNullableDouble(data['bearing_accuracy_deg']),
      provider: data['provider'] as String?,
      isMocked: _asNullableBool(data['is_mocked']),
      qualityClass: data['quality_class'] as String?,
      qualityScore: _asNullableDouble(data['quality_score']),
      qualityReason: data['quality_reason'] as String?,
      filteredLatitude: _asNullableDouble(data['filtered_latitude']),
      filteredLongitude: _asNullableDouble(data['filtered_longitude']),
      filteredAltitudeM: _asNullableDouble(data['filtered_altitude_m']),
      fusedSpeedMps: _asNullableDouble(data['fused_speed_mps']),
      derivedSpeedMps: _asNullableDouble(data['derived_speed_mps']),
      distanceDeltaM: _asNullableDouble(data['distance_delta_m']),
      motionState: data['motion_state'] as String?,
    );
  }

  TrackingDiagnosticEvent _mapTrackingDiagnostic(QueryRow row) {
    final Map<String, Object?> data = row.data;
    final String? detailsJson = data['details_json'] as String?;
    return TrackingDiagnosticEvent(
      id: _asInt(data['id']),
      localSessionId: _asInt(data['local_session_id']),
      occurredAt: DateTime.parse(data['occurred_at'] as String).toUtc(),
      eventType: data['event_type'] as String,
      message: data['message'] as String?,
      details: _parseJsonMap(detailsJson),
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

  int? _asNullableInt(Object? value) {
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

  bool? _asNullableBool(Object? value) {
    final int? integerValue = _asNullableInt(value);
    if (integerValue == null) {
      return null;
    }
    return integerValue == 1;
  }

  Map<String, dynamic> _parseJsonMap(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (Object? key, Object? value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      return const <String, dynamic>{};
    }
    return const <String, dynamic>{};
  }
}
