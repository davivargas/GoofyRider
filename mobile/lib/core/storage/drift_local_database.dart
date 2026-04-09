import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../features/session/domain/session_models.dart';

class PendingRemoteSessionDeleteEntry {
  const PendingRemoteSessionDeleteEntry({
    required this.ownerUserId,
    required this.remoteId,
    required this.attemptCount,
  });

  final String ownerUserId;
  final String remoteId;
  final int attemptCount;
}

class DriftLocalDatabase extends GeneratedDatabase {
  DriftLocalDatabase._(super.connection) : super.connect();

  @override
  int get schemaVersion => 4;

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
    return openAtPath(path.join(directory.path, _dbFileName));
  }

  static Future<DriftLocalDatabase> openAtPath(String filePath) async {
    final File file = File(filePath);
    await file.parent.create(recursive: true);
    return _openWithConnection(DatabaseConnection(NativeDatabase(file)));
  }

  static Future<DriftLocalDatabase> openInMemory() async {
    return _openWithConnection(DatabaseConnection(NativeDatabase.memory()));
  }

  static DriftLocalDatabase connectForTesting(DatabaseConnection connection) {
    return DriftLocalDatabase._(connection);
  }

  static Future<DriftLocalDatabase> _openWithConnection(
    DatabaseConnection connection,
  ) async {
    final DriftLocalDatabase database = DriftLocalDatabase._(connection);
    await database.initialize();
    return database;
  }

  static Future<DriftLocalDatabase> openOrFallback({
    Future<DriftLocalDatabase> Function()? primaryOpen,
    Future<DriftLocalDatabase> Function()? fallbackOpen,
    void Function(Object error, StackTrace stackTrace)? onPrimaryOpenError,
  }) async {
    try {
      return await (primaryOpen ?? open)();
    } on Object catch (error, stackTrace) {
      onPrimaryOpenError?.call(error, stackTrace);
      return (fallbackOpen ?? openInMemory)();
    }
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

    await _migrateToV2();
    await _migrateToV3();
    await _normalizeLegacySessionStates();

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_ride_sessions_owner_started
      ON local_ride_sessions(owner_user_id, started_at DESC)
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_local_ride_sessions_owner_state_updated
      ON local_ride_sessions(owner_user_id, state, updated_at DESC)
    ''');

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

    await customStatement('''
      CREATE TABLE IF NOT EXISTS pending_remote_session_deletes (
        owner_user_id TEXT NOT NULL,
        remote_id TEXT NOT NULL,
        requested_at TEXT NOT NULL,
        last_attempt_at TEXT,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        state TEXT NOT NULL DEFAULT 'pending',
        next_attempt_at TEXT,
        PRIMARY KEY(owner_user_id, remote_id)
      )
    ''');

    await _migratePendingRemoteDeleteSchema();

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_pending_remote_session_deletes_owner_requested
      ON pending_remote_session_deletes(owner_user_id, requested_at ASC)
    ''');

    await customStatement('''
      CREATE INDEX IF NOT EXISTS ix_pending_remote_session_deletes_owner_state_next
      ON pending_remote_session_deletes(owner_user_id, state, next_attempt_at ASC, requested_at ASC)
    ''');

    await _migrateLegacyDeletedRemoteSessionTombstones();
    await _enforceRemoteSessionIdentityUniqueness();
    await _enforceLocalSessionPointUniqueness();
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
    final LocalSessionState canonicalState = _canonicalPersistedState(newState);
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
    await customUpdate(
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

  /// Records a failed sync without incrementing the counter again because the
  /// attempt was already counted when `beginSyncAttempt` started it.
  Future<void> markSyncFailed(
    int localId, {
    required String error,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await customUpdate(
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
    await customUpdate(
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

  Future<void> insertPoint({
    required int localSessionId,
    required NewSessionPoint point,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await transaction(() async {
      await customInsert(
        '''
        INSERT OR IGNORE INTO local_session_points (
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

      await _refreshSessionPointCount(
        localSessionId: localSessionId,
        updatedAt: now,
      );
    });
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

  Future<LocalRideSession?> getSessionByLocalId(int localId) async {
    final List<QueryRow> rows = await customSelect(
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
    await customStatement(
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

    final LocalRideSession? persisted = await getSessionByRemoteId(
      ownerUserId: ownerUserId,
      remoteId: remoteId,
    );
    if (persisted == null) {
      throw StateError('Remote-backed session summary was not persisted.');
    }
    return persisted.localId;
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
    final List<QueryRow> rows = await customSelect(
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

  Future<void> _normalizeLegacySessionStates() async {
    await customStatement(
      '''
      UPDATE local_ride_sessions
      SET state = 'syncPending'
      WHERE state = 'locallyCompleted'
      ''',
    );
  }

  Future<void> _enforceRemoteSessionIdentityUniqueness() async {
    await transaction(() async {
      final List<QueryRow> duplicateKeys = await customSelect(
        '''
        SELECT owner_user_id, remote_id
        FROM local_ride_sessions
        WHERE owner_user_id IS NOT NULL
        AND remote_id IS NOT NULL
        GROUP BY owner_user_id, remote_id
        HAVING COUNT(*) > 1
        ''',
      ).get();

      for (final QueryRow key in duplicateKeys) {
        final String ownerUserId = key.data['owner_user_id'] as String;
        final String remoteId = key.data['remote_id'] as String;
        final List<QueryRow> duplicates = await customSelect(
          '''
          SELECT local_id
          FROM local_ride_sessions
          WHERE owner_user_id = ?
          AND remote_id = ?
          ORDER BY point_count DESC, updated_at DESC, local_id DESC
          ''',
          variables: <Variable>[
            Variable<String>(ownerUserId),
            Variable<String>(remoteId),
          ],
        ).get();
        if (duplicates.length < 2) {
          continue;
        }

        final int keepLocalId = _asInt(duplicates.first.data['local_id']);
        for (final QueryRow duplicate in duplicates.skip(1)) {
          final int duplicateLocalId = _asInt(duplicate.data['local_id']);
          await customStatement(
            '''
            UPDATE local_session_points
            SET local_session_id = ?
            WHERE local_session_id = ?
            ''',
            <Object?>[
              keepLocalId,
              duplicateLocalId,
            ],
          );
          await customStatement(
            '''
            UPDATE local_session_tracking_diagnostics
            SET local_session_id = ?
            WHERE local_session_id = ?
            ''',
            <Object?>[
              keepLocalId,
              duplicateLocalId,
            ],
          );
          await customStatement(
            'DELETE FROM local_ride_sessions WHERE local_id = ?',
            <Object?>[duplicateLocalId],
          );
        }
      }

      await _removeDuplicateSessionPoints();
      await _refreshAllSessionPointCounts();
    });

    await customStatement(
        'DROP INDEX IF EXISTS ix_local_ride_sessions_owner_remote');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS uq_local_ride_sessions_owner_remote
      ON local_ride_sessions(owner_user_id, remote_id)
    ''');
  }

  Future<void> _enforceLocalSessionPointUniqueness() async {
    await transaction(() async {
      await _removeDuplicateSessionPoints();
      await _refreshAllSessionPointCounts();
    });

    await customStatement(
        'DROP INDEX IF EXISTS ix_local_session_points_session_offset');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS uq_local_session_points_session_offset
      ON local_session_points(local_session_id, t_offset_ms)
    ''');
  }

  Future<void> _removeDuplicateSessionPoints() {
    return customStatement(
      '''
      DELETE FROM local_session_points
      WHERE id NOT IN (
        SELECT MIN(id)
        FROM local_session_points
        GROUP BY local_session_id, t_offset_ms
      )
      ''',
    );
  }

  Future<void> _refreshSessionPointCount({
    required int localSessionId,
    required DateTime updatedAt,
  }) {
    return customUpdate(
      '''
      UPDATE local_ride_sessions
      SET point_count = (
            SELECT COUNT(*)
            FROM local_session_points
            WHERE local_session_id = ?
          ),
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
        Variable<String>(updatedAt.toIso8601String()),
        Variable<int>(localSessionId),
      ],
    );
  }

  Future<void> _refreshAllSessionPointCounts() {
    return customStatement(
      '''
      UPDATE local_ride_sessions
      SET point_count = (
        SELECT COUNT(*)
        FROM local_session_points
        WHERE local_session_id = local_ride_sessions.local_id
      )
      ''',
    );
  }

  LocalSessionState _canonicalPersistedState(LocalSessionState state) {
    if (state == LocalSessionState.locallyCompleted) {
      return LocalSessionState.syncPending;
    }
    return state;
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
          INSERT OR IGNORE INTO local_session_points (
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

      await _refreshSessionPointCount(
        localSessionId: localSessionId,
        updatedAt: now,
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

  Future<void> _migratePendingRemoteDeleteSchema() async {
    await _addColumnIfMissing(
      'pending_remote_session_deletes',
      "state TEXT NOT NULL DEFAULT 'pending'",
    );
    await _addColumnIfMissing(
      'pending_remote_session_deletes',
      'next_attempt_at TEXT',
    );
    await customStatement(
      '''
      UPDATE pending_remote_session_deletes
      SET state = 'pending'
      WHERE state IS NULL
      OR TRIM(state) = ''
      ''',
    );
  }

  Future<void> _migrateLegacyDeletedRemoteSessionTombstones() async {
    final List<QueryRow> tableRows = await customSelect(
      '''
      SELECT name
      FROM sqlite_master
      WHERE type = 'table'
      AND name = 'deleted_remote_sessions'
      ''',
    ).get();
    if (tableRows.isEmpty) {
      return;
    }

    final List<QueryRow> legacyColumns =
        await customSelect('PRAGMA table_info(deleted_remote_sessions)').get();
    final Set<String> legacyColumnNames = legacyColumns
        .map((QueryRow row) => row.data['name']?.toString() ?? '')
        .where((String name) => name.isNotEmpty)
        .toSet();
    final bool hasDeletedAt = legacyColumnNames.contains('deleted_at');
    final bool hasLastError = legacyColumnNames.contains('last_error');
    final String requestedAtExpr =
        hasDeletedAt ? 'deleted_at' : "'1970-01-01T00:00:00.000Z'";
    final String lastAttemptAtExpr = hasDeletedAt ? 'deleted_at' : 'NULL';
    final String attemptCountExpr = hasDeletedAt ? '1' : '0';
    final String lastErrorExpr = hasLastError
        ? 'COALESCE(last_error, \'Migrated legacy pending delete record.\')'
        : '\'Migrated legacy pending delete record.\'';

    await customStatement(
      '''
      INSERT OR IGNORE INTO pending_remote_session_deletes (
        owner_user_id,
        remote_id,
        requested_at,
        last_attempt_at,
        attempt_count,
        last_error
      )
      SELECT
        owner_user_id,
        remote_id,
        $requestedAtExpr,
        $lastAttemptAtExpr,
        $attemptCountExpr,
        $lastErrorExpr
      FROM deleted_remote_sessions
      ''',
    );

    await customStatement('DROP TABLE IF EXISTS deleted_remote_sessions');
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

  Future<List<Map<String, dynamic>>> readCachedWeatherMetadata() async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT resort_id, payload_json, fetched_at
      FROM cached_weather
      ORDER BY fetched_at DESC
      ''',
    ).get();

    return rows.map((QueryRow row) {
      final String payloadJson = row.data['payload_json'] as String;
      final Map<String, dynamic> payload =
          jsonDecode(payloadJson) as Map<String, dynamic>;
      return <String, dynamic>{
        'resort_id': row.data['resort_id'],
        'cached_fetched_at': row.data['fetched_at'],
        'payload_size_bytes': payloadJson.length,
        'payload_keys': payload.keys.toList(growable: false),
      };
    }).toList(growable: false);
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

  Future<Map<String, dynamic>?> readCachedRemoteSessionSummary({
    required String ownerUserId,
    required String remoteId,
  }) async {
    final List<QueryRow> rows = await customSelect(
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

  Future<void> deleteCachedRemoteSessionSummary({
    required String ownerUserId,
    required String remoteId,
  }) async {
    await customStatement(
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

  Future<void> enqueuePendingRemoteSessionDelete({
    required String ownerUserId,
    required String remoteId,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await customStatement(
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
    final DateTime now = DateTime.now().toUtc();
    final DateTime effectiveNextAttemptAt = (nextAttemptAt ?? now).toUtc();
    await customStatement(
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
    final DateTime now = DateTime.now().toUtc();
    await customStatement(
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
    await customStatement(
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

  Future<Set<String>> listPendingRemoteSessionDeleteIds({
    required String ownerUserId,
  }) async {
    final List<QueryRow> rows = await customSelect(
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
    final String now = DateTime.now().toUtc().toIso8601String();
    final List<QueryRow> rows = await customSelect(
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
    final String now = DateTime.now().toUtc().toIso8601String();
    final List<QueryRow> rows = await customSelect(
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
            attemptCount: _asInt(row.data['attempt_count']),
          ),
        )
        .toList(growable: false);
  }

  // Compatibility wrappers kept so existing call sites/tests can migrate
  // incrementally from legacy tombstone naming.
  Future<void> upsertDeletedRemoteSession({
    required String ownerUserId,
    required String remoteId,
    String? lastError,
  }) async {
    await enqueuePendingRemoteSessionDelete(
      ownerUserId: ownerUserId,
      remoteId: remoteId,
    );
    if (lastError != null && lastError.isNotEmpty) {
      await recordPendingRemoteSessionDeleteAttempt(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
        lastError: lastError,
      );
    }
  }

  Future<void> deleteDeletedRemoteSessionTombstone({
    required String ownerUserId,
    required String remoteId,
  }) {
    return clearPendingRemoteSessionDelete(
      ownerUserId: ownerUserId,
      remoteId: remoteId,
    );
  }

  Future<Set<String>> listDeletedRemoteSessionIds({
    required String ownerUserId,
  }) {
    return listPendingRemoteSessionDeleteIds(ownerUserId: ownerUserId);
  }

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
    await transaction(() async {
      await customStatement(
        '''
        DELETE FROM local_session_tracking_diagnostics
        WHERE local_session_id = ?
        ''',
        <Object?>[localSessionId],
      );

      await customStatement(
        '''
        DELETE FROM local_session_points
        WHERE local_session_id = ?
        ''',
        <Object?>[localSessionId],
      );

      deletedSessions = await customUpdate(
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
        await customStatement(
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
          await customStatement(
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
