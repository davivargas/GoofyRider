import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../features/session/domain/session_models.dart';
import 'dao/pending_delete_dao.dart';
import 'dao/remote_session_cache_dao.dart';
import 'dao/resort_cache_dao.dart';
import 'dao/session_dao.dart';
import 'dao/session_point_dao.dart';
import 'dao/tracking_diagnostics_dao.dart';
import 'dao/weather_cache_dao.dart';

export 'dao/pending_delete_dao.dart';
export 'dao/remote_session_cache_dao.dart';
export 'dao/resort_cache_dao.dart';
export 'dao/session_dao.dart';
export 'dao/session_point_dao.dart';
export 'dao/tracking_diagnostics_dao.dart';
export 'dao/weather_cache_dao.dart';

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

  // ---------------------------------------------------------------------------
  // DAO getters
  // ---------------------------------------------------------------------------

  SessionDao get sessions => SessionDao(this);
  SessionPointDao get sessionPoints => SessionPointDao(this);
  ResortCacheDao get resortCache => ResortCacheDao(this);
  WeatherCacheDao get weatherCache => WeatherCacheDao(this);
  RemoteSessionCacheDao get remoteSessionCache => RemoteSessionCacheDao(this);
  TrackingDiagnosticsDao get trackingDiagnostics =>
      TrackingDiagnosticsDao(this);
  PendingDeleteDao get pendingDeletes => PendingDeleteDao(this);

  // ---------------------------------------------------------------------------
  // Factory / lifecycle
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Initialization & migrations (kept in-place)
  // ---------------------------------------------------------------------------

  Future<void> initialize() async {
    final List<QueryRow> versionRows =
        await customSelect('PRAGMA user_version').get();
    final int currentVersion = versionRows.isNotEmpty
        ? (versionRows.first.data.values.first as int? ?? 0)
        : 0;
    if (currentVersion >= schemaVersion) {
      return;
    }

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
        owner_user_id TEXT NOT NULL DEFAULT '',
        resort_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        PRIMARY KEY(owner_user_id, resort_id)
      )
    ''');
    await _migrateCachedResortSchema();

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

    await customStatement('PRAGMA user_version = $schemaVersion');
  }

  // ---------------------------------------------------------------------------
  // Deprecated forwarding stubs — Session
  // ---------------------------------------------------------------------------

  @Deprecated('Use sessions.insertLocalSession instead')
  Future<int> insertLocalSession({
    required DateTime startedAt,
    required String ownerUserId,
    String? resortId,
  }) =>
      sessions.insertLocalSession(
        startedAt: startedAt,
        ownerUserId: ownerUserId,
        resortId: resortId,
      );

  @Deprecated('Use sessions.updateSessionState instead')
  Future<void> updateSessionState(
    int localId,
    LocalSessionState newState, {
    String? remoteId,
    String? lastSyncError,
  }) =>
      sessions.updateSessionState(
        localId,
        newState,
        remoteId: remoteId,
        lastSyncError: lastSyncError,
      );

  @Deprecated('Use sessions.beginSyncAttempt instead')
  Future<void> beginSyncAttempt(int localId) =>
      sessions.beginSyncAttempt(localId);

  @Deprecated('Use sessions.incrementSyncAttempt instead')
  Future<void> incrementSyncAttempt(
    int localId, {
    String? error,
  }) =>
      sessions.incrementSyncAttempt(localId, error: error);

  @Deprecated('Use sessions.markSyncFailed instead')
  Future<void> markSyncFailed(
    int localId, {
    required String error,
  }) =>
      sessions.markSyncFailed(localId, error: error);

  @Deprecated('Use sessions.completeLocalSession instead')
  Future<void> completeLocalSession({
    required int localId,
    required DateTime endedAt,
    required SessionStats stats,
    String? resortId,
  }) =>
      sessions.completeLocalSession(
        localId: localId,
        endedAt: endedAt,
        stats: stats,
        resortId: resortId,
      );

  @Deprecated('Use sessions.updateSessionResortId instead')
  Future<void> updateSessionResortId({
    required int localId,
    required String ownerUserId,
    required String resortId,
  }) =>
      sessions.updateSessionResortId(
        localId: localId,
        ownerUserId: ownerUserId,
        resortId: resortId,
      );

  @Deprecated('Use sessions.getSessionById instead')
  Future<LocalRideSession?> getSessionById(
    int localId, {
    required String ownerUserId,
  }) =>
      sessions.getSessionById(localId, ownerUserId: ownerUserId);

  @Deprecated('Use sessions.getSessionByLocalId instead')
  Future<LocalRideSession?> getSessionByLocalId(int localId) =>
      sessions.getSessionByLocalId(localId);

  @Deprecated('Use sessions.getSessionByRemoteId instead')
  Future<LocalRideSession?> getSessionByRemoteId({
    required String ownerUserId,
    required String remoteId,
  }) =>
      sessions.getSessionByRemoteId(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
      );

  @Deprecated('Use sessions.getInProgressSession instead')
  Future<LocalRideSession?> getInProgressSession({
    required String ownerUserId,
  }) =>
      sessions.getInProgressSession(ownerUserId: ownerUserId);

  @Deprecated('Use sessions.listSessions instead')
  Future<List<LocalRideSession>> listSessions({
    required String ownerUserId,
  }) =>
      sessions.listSessions(ownerUserId: ownerUserId);

  @Deprecated('Use sessions.listPendingSyncSessions instead')
  Future<List<LocalRideSession>> listPendingSyncSessions({
    required String ownerUserId,
  }) =>
      sessions.listPendingSyncSessions(ownerUserId: ownerUserId);

  @Deprecated('Use sessions.unsyncedCount instead')
  Future<int> unsyncedCount({
    required String ownerUserId,
  }) =>
      sessions.unsyncedCount(ownerUserId: ownerUserId);

  @Deprecated('Use sessions.deleteSessionCascade instead')
  Future<bool> deleteSessionCascade({
    required int localSessionId,
    required String ownerUserId,
    String? remoteId,
    bool clearDeletedRemoteSessionTombstone = true,
    bool? clearPendingRemoteSessionDelete,
  }) =>
      sessions.deleteSessionCascade(
        localSessionId: localSessionId,
        ownerUserId: ownerUserId,
        remoteId: remoteId,
        clearDeletedRemoteSessionTombstone: clearDeletedRemoteSessionTombstone,
        clearPendingRemoteSessionDelete: clearPendingRemoteSessionDelete,
      );

  // ---------------------------------------------------------------------------
  // Deprecated forwarding stubs — Session Points
  // ---------------------------------------------------------------------------

  @Deprecated('Use sessionPoints.insertPoint instead')
  Future<void> insertPoint({
    required int localSessionId,
    required NewSessionPoint point,
  }) =>
      sessionPoints.insertPoint(
        localSessionId: localSessionId,
        point: point,
      );

  @Deprecated('Use sessionPoints.latestAcceptedPoint instead')
  Future<LocalSessionPoint?> latestAcceptedPoint(int localSessionId) =>
      sessionPoints.latestAcceptedPoint(localSessionId);

  @Deprecated('Use sessionPoints.listPoints instead')
  Future<List<LocalSessionPoint>> listPoints(
    int localSessionId, {
    bool onlyAccepted = false,
  }) =>
      sessionPoints.listPoints(
        localSessionId,
        onlyAccepted: onlyAccepted,
      );

  @Deprecated('Use sessionPoints.replaceSessionPoints instead')
  Future<void> replaceSessionPoints({
    required int localSessionId,
    required List<NewSessionPoint> points,
  }) =>
      sessionPoints.replaceSessionPoints(
        localSessionId: localSessionId,
        points: points,
      );

  // ---------------------------------------------------------------------------
  // Deprecated forwarding stubs — Resort Cache
  // ---------------------------------------------------------------------------

  @Deprecated('Use resortCache.upsertCachedResort instead')
  Future<void> upsertCachedResort(
    String resortId,
    Map<String, dynamic> payload, {
    String? ownerUserId,
  }) =>
      resortCache.upsertCachedResort(
        resortId,
        payload,
        ownerUserId: ownerUserId,
      );

  @Deprecated('Use resortCache.readCachedResort instead')
  Future<Map<String, dynamic>?> readCachedResort(
    String resortId, {
    String? ownerUserId,
  }) =>
      resortCache.readCachedResort(resortId, ownerUserId: ownerUserId);

  @Deprecated('Use resortCache.readCachedResorts instead')
  Future<List<Map<String, dynamic>>> readCachedResorts({
    String? ownerUserId,
  }) =>
      resortCache.readCachedResorts(ownerUserId: ownerUserId);

  // ---------------------------------------------------------------------------
  // Deprecated forwarding stubs — Weather Cache
  // ---------------------------------------------------------------------------

  @Deprecated('Use weatherCache.upsertCachedWeather instead')
  Future<void> upsertCachedWeather(
    String resortId,
    Map<String, dynamic> payload,
  ) =>
      weatherCache.upsertCachedWeather(resortId, payload);

  @Deprecated('Use weatherCache.readCachedWeather instead')
  Future<Map<String, dynamic>?> readCachedWeather(String resortId) =>
      weatherCache.readCachedWeather(resortId);

  @Deprecated('Use weatherCache.readCachedWeatherMetadata instead')
  Future<List<Map<String, dynamic>>> readCachedWeatherMetadata() =>
      weatherCache.readCachedWeatherMetadata();

  // ---------------------------------------------------------------------------
  // Deprecated forwarding stubs — Remote Session Cache
  // ---------------------------------------------------------------------------

  @Deprecated('Use remoteSessionCache.upsertRemoteSessionSummary instead')
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
  }) =>
      remoteSessionCache.upsertRemoteSessionSummary(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
        startedAt: startedAt,
        endedAt: endedAt,
        activeDurationS: activeDurationS,
        distanceM: distanceM,
        maxSpeedMps: maxSpeedMps,
        avgSpeedMps: avgSpeedMps,
        elevationGainM: elevationGainM,
        elevationLossM: elevationLossM,
        resortId: resortId,
        createdAt: createdAt,
      );

  @Deprecated('Use remoteSessionCache.replaceCachedRemoteSessions instead')
  Future<void> replaceCachedRemoteSessions({
    required String ownerUserId,
    required List<Map<String, dynamic>> sessions,
  }) =>
      remoteSessionCache.replaceCachedRemoteSessions(
        ownerUserId: ownerUserId,
        sessions: sessions,
      );

  @Deprecated('Use remoteSessionCache.readCachedRemoteSessions instead')
  Future<List<Map<String, dynamic>>> readCachedRemoteSessions({
    required String ownerUserId,
  }) =>
      remoteSessionCache.readCachedRemoteSessions(ownerUserId: ownerUserId);

  @Deprecated(
      'Use remoteSessionCache.readCachedRemoteSessionSummary instead')
  Future<Map<String, dynamic>?> readCachedRemoteSessionSummary({
    required String ownerUserId,
    required String remoteId,
  }) =>
      remoteSessionCache.readCachedRemoteSessionSummary(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
      );

  @Deprecated(
      'Use remoteSessionCache.deleteCachedRemoteSessionSummary instead')
  Future<void> deleteCachedRemoteSessionSummary({
    required String ownerUserId,
    required String remoteId,
  }) =>
      remoteSessionCache.deleteCachedRemoteSessionSummary(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
      );

  // ---------------------------------------------------------------------------
  // Deprecated forwarding stubs — Tracking Diagnostics
  // ---------------------------------------------------------------------------

  @Deprecated('Use trackingDiagnostics.insertTrackingDiagnostic instead')
  Future<void> insertTrackingDiagnostic({
    required int localSessionId,
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) =>
      trackingDiagnostics.insertTrackingDiagnostic(
        localSessionId: localSessionId,
        eventType: eventType,
        message: message,
        details: details,
      );

  @Deprecated('Use trackingDiagnostics.listTrackingDiagnostics instead')
  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit = 120,
  }) =>
      trackingDiagnostics.listTrackingDiagnostics(
        localSessionId,
        limit: limit,
      );

  // ---------------------------------------------------------------------------
  // Deprecated forwarding stubs — Pending Deletes
  // ---------------------------------------------------------------------------

  @Deprecated('Use pendingDeletes.enqueuePendingRemoteSessionDelete instead')
  Future<void> enqueuePendingRemoteSessionDelete({
    required String ownerUserId,
    required String remoteId,
  }) =>
      pendingDeletes.enqueuePendingRemoteSessionDelete(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
      );

  @Deprecated(
      'Use pendingDeletes.recordPendingRemoteSessionDeleteAttempt instead')
  Future<void> recordPendingRemoteSessionDeleteAttempt({
    required String ownerUserId,
    required String remoteId,
    required String lastError,
    DateTime? nextAttemptAt,
  }) =>
      pendingDeletes.recordPendingRemoteSessionDeleteAttempt(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
        lastError: lastError,
        nextAttemptAt: nextAttemptAt,
      );

  @Deprecated(
      'Use pendingDeletes.markPendingRemoteSessionDeleteFailed instead')
  Future<void> markPendingRemoteSessionDeleteFailed({
    required String ownerUserId,
    required String remoteId,
    required String lastError,
  }) =>
      pendingDeletes.markPendingRemoteSessionDeleteFailed(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
        lastError: lastError,
      );

  @Deprecated('Use pendingDeletes.clearPendingRemoteSessionDelete instead')
  Future<void> clearPendingRemoteSessionDelete({
    required String ownerUserId,
    required String remoteId,
  }) =>
      pendingDeletes.clearPendingRemoteSessionDelete(
        ownerUserId: ownerUserId,
        remoteId: remoteId,
      );

  @Deprecated(
      'Use pendingDeletes.listPendingRemoteSessionDeleteIds instead')
  Future<Set<String>> listPendingRemoteSessionDeleteIds({
    required String ownerUserId,
  }) =>
      pendingDeletes.listPendingRemoteSessionDeleteIds(
        ownerUserId: ownerUserId,
      );

  @Deprecated('Use pendingDeletes.listPendingRemoteDeleteIds instead')
  Future<List<String>> listPendingRemoteDeleteIds({
    required String ownerUserId,
  }) =>
      pendingDeletes.listPendingRemoteDeleteIds(ownerUserId: ownerUserId);

  @Deprecated(
      'Use pendingDeletes.listRetryablePendingRemoteDeletes instead')
  Future<List<PendingRemoteSessionDeleteEntry>>
      listRetryablePendingRemoteDeletes({
    required String ownerUserId,
  }) =>
          pendingDeletes.listRetryablePendingRemoteDeletes(
            ownerUserId: ownerUserId,
          );

  // ---------------------------------------------------------------------------
  // Kept in-place: clearCaches
  // ---------------------------------------------------------------------------

  Future<void> clearCaches() async {
    await customStatement('DELETE FROM cached_weather');
    await customStatement('DELETE FROM cached_resorts');
  }

  // ---------------------------------------------------------------------------
  // Migration helpers (kept in-place — private)
  // ---------------------------------------------------------------------------

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

  Future<void> _migrateCachedResortSchema() async {
    final List<QueryRow> columns =
        await customSelect('PRAGMA table_info(cached_resorts)').get();
    final Set<String> columnNames = columns
        .map((QueryRow row) => row.data['name']?.toString() ?? '')
        .where((String name) => name.isNotEmpty)
        .toSet();
    if (columnNames.contains('owner_user_id')) {
      return;
    }

    final List<QueryRow> legacyRows = await customSelect(
      '''
      SELECT resort_id, payload_json, fetched_at
      FROM cached_resorts
      ''',
    ).get();

    await customStatement('ALTER TABLE cached_resorts RENAME TO cached_resorts_legacy');
    await customStatement('''
      CREATE TABLE cached_resorts (
        owner_user_id TEXT NOT NULL DEFAULT '',
        resort_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        PRIMARY KEY(owner_user_id, resort_id)
      )
    ''');

    for (final QueryRow row in legacyRows) {
      await customStatement(
        '''
        INSERT INTO cached_resorts (
          owner_user_id,
          resort_id,
          payload_json,
          fetched_at
        ) VALUES (?, ?, ?, ?)
        ''',
        <Object?>[
          '',
          row.data['resort_id'],
          row.data['payload_json'],
          row.data['fetched_at'],
        ],
      );
    }

    await customStatement('DROP TABLE IF EXISTS cached_resorts_legacy');
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

  // ---------------------------------------------------------------------------
  // Private type-conversion helpers (kept for migration code)
  // ---------------------------------------------------------------------------

  int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.parse(value.toString());
  }
}
