import 'dart:io';

import 'package:drift/drift.dart'
    show DatabaseConnection, QueryRow, Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';

void main() {
  group('DriftLocalDatabase integrity', () {
    late DriftLocalDatabase database;

    setUp(() async {
      database = await DriftLocalDatabase.openInMemory();
    });

    tearDown(() async {
      await database.close();
    });

    test('duplicate point offsets are ignored and point count stays consistent',
        () async {
      final int localSessionId = await database.insertLocalSession(
        startedAt: DateTime.utc(2026, 1, 1, 8),
        ownerUserId: 'user-1',
      );

      await database.insertPoint(
        localSessionId: localSessionId,
        point: _point(
          recordedAt: DateTime.utc(2026, 1, 1, 8, 0, 1),
          tOffsetMs: 1000,
          latitude: 49.0,
          longitude: -123.0,
        ),
      );
      await database.insertPoint(
        localSessionId: localSessionId,
        point: _point(
          recordedAt: DateTime.utc(2026, 1, 1, 8, 0, 2),
          tOffsetMs: 1000,
          latitude: 50.0,
          longitude: -124.0,
        ),
      );

      final List<LocalSessionPoint> points = await database.listPoints(
        localSessionId,
      );
      final LocalRideSession? session =
          await database.getSessionById(localSessionId, ownerUserId: 'user-1');

      expect(points, hasLength(1));
      expect(points.single.latitude, 49.0);
      expect(points.single.longitude, -123.0);
      expect(session?.pointCount, 1);
    });

    test(
        'remote session summary upsert reuses the same local row and preserves points',
        () async {
      final int firstLocalId = await database.upsertRemoteSessionSummary(
        ownerUserId: 'user-1',
        remoteId: 'remote-1',
        startedAt: DateTime.utc(2026, 1, 1, 9),
        endedAt: DateTime.utc(2026, 1, 1, 9, 10),
        activeDurationS: 600,
        distanceM: 1200,
        maxSpeedMps: 18,
        avgSpeedMps: 10,
        elevationGainM: 50,
        elevationLossM: 300,
        resortId: 'resort-1',
      );

      await database.insertPoint(
        localSessionId: firstLocalId,
        point: _point(
          recordedAt: DateTime.utc(2026, 1, 1, 9, 0, 5),
          tOffsetMs: 5000,
          latitude: 49.0,
          longitude: -123.0,
        ),
      );

      final int secondLocalId = await database.upsertRemoteSessionSummary(
        ownerUserId: 'user-1',
        remoteId: 'remote-1',
        startedAt: DateTime.utc(2026, 1, 1, 9),
        endedAt: DateTime.utc(2026, 1, 1, 9, 12),
        activeDurationS: 720,
        distanceM: 1500,
        maxSpeedMps: 22,
        avgSpeedMps: 11,
        elevationGainM: 60,
        elevationLossM: 320,
        resortId: 'resort-2',
      );

      final List<LocalRideSession> sessions =
          await database.listSessions(ownerUserId: 'user-1');
      final LocalRideSession? session = await database.getSessionByRemoteId(
        ownerUserId: 'user-1',
        remoteId: 'remote-1',
      );
      final List<LocalSessionPoint> points = await database.listPoints(
        firstLocalId,
      );

      expect(secondLocalId, firstLocalId);
      expect(sessions, hasLength(1));
      expect(session?.resortId, 'resort-2');
      expect(session?.activeDurationS, 720);
      expect(session?.pointCount, 1);
      expect(points, hasLength(1));
    });

    test('pending remote deletes stay hidden until their retry window opens',
        () async {
      await database.enqueuePendingRemoteSessionDelete(
        ownerUserId: 'user-1',
        remoteId: 'remote-queued',
      );
      await database.recordPendingRemoteSessionDeleteAttempt(
        ownerUserId: 'user-1',
        remoteId: 'remote-queued',
        lastError: 'Network unavailable',
        nextAttemptAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );

      final Set<String> hiddenIds =
          await database.listPendingRemoteSessionDeleteIds(
        ownerUserId: 'user-1',
      );
      final List<String> retryableIds =
          await database.listPendingRemoteDeleteIds(
        ownerUserId: 'user-1',
      );

      expect(hiddenIds, <String>{'remote-queued'});
      expect(retryableIds, isEmpty);
    });

    test('failed remote deletes stop hiding history and stop automatic retries',
        () async {
      await database.enqueuePendingRemoteSessionDelete(
        ownerUserId: 'user-1',
        remoteId: 'remote-failed',
      );
      await database.markPendingRemoteSessionDeleteFailed(
        ownerUserId: 'user-1',
        remoteId: 'remote-failed',
        lastError: 'Authentication required.',
      );

      final Set<String> hiddenIds =
          await database.listPendingRemoteSessionDeleteIds(
        ownerUserId: 'user-1',
      );
      final List<PendingRemoteSessionDeleteEntry> retryableDeletes =
          await database.listRetryablePendingRemoteDeletes(
        ownerUserId: 'user-1',
      );

      expect(hiddenIds, isEmpty);
      expect(retryableDeletes, isEmpty);
    });

    test(
        'legacy pending delete schema upgrades before creating retry indexes',
        () async {
      final bool previousDontWarn =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final Directory tempDirectory =
          await Directory.systemTemp.createTemp('goofyrider_legacy_db_');
      DriftLocalDatabase? fileDatabase;
      addTearDown(() async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDontWarn;
        final DriftLocalDatabase? databaseToClose = fileDatabase;
        fileDatabase = null;
        if (databaseToClose != null) {
          await databaseToClose.close();
        }
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      final String dbPath =
          '${tempDirectory.path}${Platform.pathSeparator}legacy.sqlite';
      fileDatabase = DriftLocalDatabase.connectForTesting(
        DatabaseConnection(NativeDatabase(File(dbPath))),
      );

      await fileDatabase!.customStatement('''
        CREATE TABLE pending_remote_session_deletes (
          owner_user_id TEXT NOT NULL,
          remote_id TEXT NOT NULL,
          requested_at TEXT NOT NULL,
          last_attempt_at TEXT,
          attempt_count INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          PRIMARY KEY(owner_user_id, remote_id)
        )
      ''');
      await fileDatabase!.customStatement(
        '''
        INSERT INTO pending_remote_session_deletes (
          owner_user_id,
          remote_id,
          requested_at,
          last_attempt_at,
          attempt_count,
          last_error
        ) VALUES (?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          'user-1',
          'remote-legacy',
          DateTime.utc(2026, 1, 1, 12).toIso8601String(),
          null,
          0,
          null,
        ],
      );
      await fileDatabase!.close();
      fileDatabase = null;

      fileDatabase = await DriftLocalDatabase.openAtPath(dbPath);

      final List<QueryRow> columns = await fileDatabase!.customSelect(
        'PRAGMA table_info(pending_remote_session_deletes)',
      ).get();
      final Set<String> columnNames = columns
          .map((QueryRow row) => row.data['name'] as String)
          .toSet();
      final Set<String> pendingIds =
          await fileDatabase!.listPendingRemoteSessionDeleteIds(
        ownerUserId: 'user-1',
      );
      final List<QueryRow> migratedRows = await fileDatabase!.customSelect(
        '''
        SELECT state, next_attempt_at
        FROM pending_remote_session_deletes
        WHERE owner_user_id = ?
        AND remote_id = ?
        ''',
        variables: <Variable>[
          const Variable<String>('user-1'),
          const Variable<String>('remote-legacy'),
        ],
      ).get();

      expect(columnNames, containsAll(<String>['state', 'next_attempt_at']));
      expect(pendingIds, <String>{'remote-legacy'});
      expect(migratedRows.single.data['state'], 'pending');
      expect(migratedRows.single.data['next_attempt_at'], isNull);
    });

    test('legacy deleted remote tombstones migrate into pending deletes',
        () async {
      final bool previousDontWarn =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final Directory tempDirectory =
          await Directory.systemTemp.createTemp('goofyrider_legacy_db_');
      DriftLocalDatabase? fileDatabase;
      addTearDown(() async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDontWarn;
        final DriftLocalDatabase? databaseToClose = fileDatabase;
        fileDatabase = null;
        if (databaseToClose != null) {
          await databaseToClose.close();
        }
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      final String dbPath =
          '${tempDirectory.path}${Platform.pathSeparator}legacy_tombstones.sqlite';
      fileDatabase = DriftLocalDatabase.connectForTesting(
        DatabaseConnection(NativeDatabase(File(dbPath))),
      );

      await fileDatabase!.customStatement('''
        CREATE TABLE deleted_remote_sessions (
          owner_user_id TEXT NOT NULL,
          remote_id TEXT NOT NULL,
          deleted_at TEXT,
          last_error TEXT,
          PRIMARY KEY(owner_user_id, remote_id)
        )
      ''');
      await fileDatabase!.customStatement(
        '''
        INSERT INTO deleted_remote_sessions (
          owner_user_id,
          remote_id,
          deleted_at,
          last_error
        ) VALUES (?, ?, ?, ?)
        ''',
        <Object?>[
          'user-1',
          'remote-legacy-delete',
          DateTime.utc(2026, 1, 3, 7).toIso8601String(),
          'Migrated from legacy queue',
        ],
      );
      await fileDatabase!.close();
      fileDatabase = null;

      fileDatabase = await DriftLocalDatabase.openAtPath(dbPath);

      final List<QueryRow> migratedRows = await fileDatabase!.customSelect(
        '''
        SELECT requested_at, last_attempt_at, attempt_count, last_error, state
        FROM pending_remote_session_deletes
        WHERE owner_user_id = ?
        AND remote_id = ?
        ''',
        variables: <Variable>[
          const Variable<String>('user-1'),
          const Variable<String>('remote-legacy-delete'),
        ],
      ).get();
      final List<QueryRow> legacyTableRows = await fileDatabase!.customSelect(
        '''
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
        AND name = 'deleted_remote_sessions'
        ''',
      ).get();

      expect(migratedRows, hasLength(1));
      expect(migratedRows.single.data['state'], 'pending');
      expect(migratedRows.single.data['attempt_count'], 1);
      expect(
        migratedRows.single.data['last_error'],
        'Migrated from legacy queue',
      );
      expect(legacyTableRows, isEmpty);
    });

    test(
        'legacy ride session schema adds owner column before owner indexes',
        () async {
      final bool previousDontWarn =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final Directory tempDirectory =
          await Directory.systemTemp.createTemp('goofyrider_legacy_db_');
      DriftLocalDatabase? fileDatabase;
      addTearDown(() async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDontWarn;
        final DriftLocalDatabase? databaseToClose = fileDatabase;
        fileDatabase = null;
        if (databaseToClose != null) {
          await databaseToClose.close();
        }
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      final String dbPath =
          '${tempDirectory.path}${Platform.pathSeparator}legacy_sessions.sqlite';
      fileDatabase = DriftLocalDatabase.connectForTesting(
        DatabaseConnection(NativeDatabase(File(dbPath))),
      );

      await fileDatabase!.customStatement('''
        CREATE TABLE local_ride_sessions (
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
      await fileDatabase!.customStatement(
        '''
        INSERT INTO local_ride_sessions (
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
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          'remote-legacy',
          'resort-legacy',
          DateTime.utc(2026, 1, 2, 8).toIso8601String(),
          null,
          0,
          0,
          0,
          0,
          null,
          null,
          'recording',
          0,
          0,
          null,
          DateTime.utc(2026, 1, 2, 8).toIso8601String(),
          DateTime.utc(2026, 1, 2, 8).toIso8601String(),
        ],
      );
      await fileDatabase!.close();
      fileDatabase = null;

      fileDatabase = await DriftLocalDatabase.openAtPath(dbPath);

      final List<QueryRow> columns = await fileDatabase!.customSelect(
        'PRAGMA table_info(local_ride_sessions)',
      ).get();
      final Set<String> columnNames = columns
          .map((QueryRow row) => row.data['name'] as String)
          .toSet();
      final List<QueryRow> indexes = await fileDatabase!.customSelect(
        'PRAGMA index_list(local_ride_sessions)',
      ).get();
      final Set<String> indexNames = indexes
          .map((QueryRow row) => row.data['name'] as String)
          .toSet();

      expect(columnNames, contains('owner_user_id'));
      expect(
        indexNames,
        containsAll(<String>[
          'ix_local_ride_sessions_owner_started',
          'ix_local_ride_sessions_owner_state_updated',
        ]),
      );
    });
  });
}

NewSessionPoint _point({
  required DateTime recordedAt,
  required int tOffsetMs,
  required double latitude,
  required double longitude,
}) {
  return NewSessionPoint(
    recordedAt: recordedAt,
    tOffsetMs: tOffsetMs,
    latitude: latitude,
    longitude: longitude,
    accuracyM: 5,
    altitudeM: 1200,
    speedMps: 8,
    headingDeg: 120,
    acceptedForAnalytics: true,
    qualityClass: 'accept',
    qualityScore: 0.9,
    qualityReason: 'test',
    filteredLatitude: latitude,
    filteredLongitude: longitude,
    filteredAltitudeM: 1200,
    fusedSpeedMps: 8,
    derivedSpeedMps: 8,
    distanceDeltaM: 12,
    motionState: 'active_descent',
  );
}
