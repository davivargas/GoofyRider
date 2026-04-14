import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';
import 'package:goofyrider_mobile/features/session/data/session_resort_attribution_service.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';

void main() {
  late DriftLocalDatabase database;
  late SessionResortAttributionService service;

  setUp(() async {
    database = await DriftLocalDatabase.openInMemory();
    service = SessionResortAttributionService(localDatabase: database);
  });

  tearDown(() async {
    await database.close();
  });

  test('resolve prefers explicit resort association from cache', () async {
    await database.upsertCachedResort(
      'resort-1',
      <String, dynamic>{
        'id': 'resort-1',
        'name': 'Whistler Blackcomb',
        'country': 'Canada',
        'region': 'BC',
      },
    );

    final session = _buildSession(
      localId: 1,
      resortId: 'resort-1',
    );

    final resolved = await service.resolve(session);

    expect(resolved.label, 'Whistler Blackcomb');
    expect(resolved.resortId, 'resort-1');
    expect(resolved.inferred, isFalse);
  });

  test('resolve infers nearest resort from latest accepted point', () async {
    await database.upsertCachedResort(
      'resort-1',
      <String, dynamic>{
        'id': 'resort-1',
        'name': 'Whistler Blackcomb',
        'country': 'Canada',
        'region': 'BC',
        'latitude': 50.1163,
        'longitude': -122.9574,
      },
    );

    final localId = await database.insertLocalSession(
      startedAt: DateTime.utc(2026, 1, 1),
      ownerUserId: 'user-1',
    );
    await database.insertPoint(
      localSessionId: localId,
      point: NewSessionPoint(
        recordedAt: DateTime.utc(2026, 1, 1),
        tOffsetMs: 0,
        latitude: 50.117,
        longitude: -122.958,
        accuracyM: 5,
        altitudeM: 1000,
        speedMps: 4,
        headingDeg: 90,
        acceptedForAnalytics: true,
      ),
    );

    final session =
        (await database.getSessionById(localId, ownerUserId: 'user-1'))!;
    final resolved = await service.resolve(session);

    expect(resolved.label, 'Whistler Blackcomb');
    expect(resolved.resortId, 'resort-1');
    expect(resolved.inferred, isTrue);
  });

  test('resolve returns unknown resort when no nearby match exists', () async {
    await database.upsertCachedResort(
      'resort-1',
      <String, dynamic>{
        'id': 'resort-1',
        'name': 'Whistler Blackcomb',
        'country': 'Canada',
        'region': 'BC',
        'latitude': 50.1163,
        'longitude': -122.9574,
      },
    );

    final localId = await database.insertLocalSession(
      startedAt: DateTime.utc(2026, 1, 1),
      ownerUserId: 'user-1',
    );
    await database.insertPoint(
      localSessionId: localId,
      point: NewSessionPoint(
        recordedAt: DateTime.utc(2026, 1, 1),
        tOffsetMs: 0,
        latitude: 40.7128,
        longitude: -74.0060,
        accuracyM: 5,
        altitudeM: 1000,
        speedMps: 4,
        headingDeg: 90,
        acceptedForAnalytics: true,
      ),
    );

    final session =
        (await database.getSessionById(localId, ownerUserId: 'user-1'))!;
    final resolved = await service.resolve(session);

    expect(resolved.label, unknownSessionResortLabel);
    expect(resolved.resortId, isNull);
  });
}

LocalRideSession _buildSession({
  required int localId,
  String? resortId,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: localId,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: resortId,
    startedAt: now,
    endedAt: now,
    activeDurationS: 60,
    distanceM: 100,
    maxSpeedMps: 5,
    avgSpeedMps: 4,
    elevationGainM: null,
    elevationLossM: null,
    state: LocalSessionState.synced,
    pointCount: 0,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: now,
    updatedAt: now,
  );
}
