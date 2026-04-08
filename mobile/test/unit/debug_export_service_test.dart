import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';
import 'package:goofyrider_mobile/core/utils/distance_unit.dart';
import 'package:goofyrider_mobile/core/utils/speed_unit.dart';
import 'package:goofyrider_mobile/features/profile/presentation/debug_export_service.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';

void main() {
  late DriftLocalDatabase database;
  late Directory tempDirectory;

  setUp(() async {
    database = await DriftLocalDatabase.openInMemory();
    tempDirectory = await Directory.systemTemp.createTemp('goofyrider_debug_export_test');
  });

  tearDown(() async {
    await database.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('export writes rich snapshot with masked email and capped points', () async {
    final int sessionId = await database.insertLocalSession(
      startedAt: DateTime.utc(2026, 1, 1),
      ownerUserId: 'user-1',
      resortId: 'resort-1',
    );
    await database.updateSessionState(
      sessionId,
      LocalSessionState.syncFailed,
      remoteId: 'remote-1',
      lastSyncError: 'Network timeout',
    );

    for (int index = 0; index < 120; index++) {
      await database.insertPoint(
        localSessionId: sessionId,
        point: NewSessionPoint(
          recordedAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
          tOffsetMs: index * 1000,
          latitude: 45.0 + (index / 10000),
          longitude: -122.0 - (index / 10000),
          accuracyM: 4,
          altitudeM: 1200 + index.toDouble(),
          speedMps: 8 + (index / 10),
          headingDeg: 180,
          acceptedForAnalytics: true,
          verticalAccuracyM: 2,
          provider: 'gps',
          motionState: 'descent',
          qualityClass: 'good',
          filteredLatitude: 45.0 + (index / 10000),
          filteredLongitude: -122.0 - (index / 10000),
        ),
      );
    }

    await database.insertTrackingDiagnostic(
      localSessionId: sessionId,
      eventType: 'sync_failed',
      message: 'Network timeout',
      details: <String, dynamic>{
        'http_status': 503,
        'access_token': 'top-secret',
      },
    );
    await database.replaceCachedRemoteSessions(
      ownerUserId: 'user-1',
      sessions: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'remote-1',
          'status': 'synced',
          'access_token': 'should_not_export',
        },
      ],
    );
    await database.upsertCachedResort(
      'resort-1',
      <String, dynamic>{
        'id': 'resort-1',
        'name': 'Mt. Test',
      },
    );
    await database.upsertCachedWeather(
      'resort-1',
      <String, dynamic>{
        'temperature_c': -3,
        'condition': 'snow',
      },
    );

    final DebugExportService service = DebugExportService(
      localDatabase: database,
      documentsDirectoryProvider: () async => tempDirectory,
    );
    final File file = await service.export(
      ownerUserId: 'user-1',
      userEmail: 'rider@example.com',
      speedUnit: SpeedUnit.kilometersPerHour,
      distanceUnit: DistanceUnit.meters,
    );

    expect(await file.exists(), isTrue);
    final Map<String, dynamic> payload =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(payload['schema_version'], 2);
    expect(payload['summary']['session_count'], 1);
    expect(payload['summary']['unsynced_session_count'], 1);
    expect(payload['summary']['cached_weather_count'], 1);
    expect(payload['settings']['speed_unit'], 'kilometersPerHour');
    expect(payload['settings']['distance_unit'], 'meters');
    expect(payload['user_context']['masked_email'], 'ri***@example.com');
    expect(payload['user_context']['masked_email'], isNot('rider@example.com'));
    expect(payload['cached_remote_sessions'], isNotEmpty);
    expect(payload['cached_resorts'], isNotEmpty);
    expect(payload['cached_weather_metadata'], isNotEmpty);

    final Map<String, dynamic> exportedSession =
        (payload['sessions'] as List<dynamic>).first as Map<String, dynamic>;
    final Map<String, dynamic> pointSample =
        exportedSession['point_sample'] as Map<String, dynamic>;
    expect(pointSample['included'], isTrue);
    expect(pointSample['accepted_points_preferred'], isTrue);
    expect(pointSample['total_points_available'], 120);
    expect((pointSample['sampled_points'] as List<dynamic>).length, 100);

    expect(payload.toString().contains('access_token'), isFalse);
    expect(payload.toString().contains('refresh_token'), isFalse);
  });
}
