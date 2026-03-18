import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';

LocalSessionPoint buildPoint({
  required int id,
  required DateTime at,
  required double lat,
  required double lng,
  double? altitude,
  bool accepted = true,
}) {
  return LocalSessionPoint(
    id: id,
    localSessionId: 1,
    recordedAt: at,
    tOffsetMs: id * 1000,
    latitude: lat,
    longitude: lng,
    accuracyM: 5,
    altitudeM: altitude,
    speedMps: null,
    headingDeg: null,
    acceptedForAnalytics: accepted,
  );
}

void main() {
  const SessionAnalyticsEngine engine = SessionAnalyticsEngine();

  test('haversineDistanceMeters returns positive distance', () {
    final double distance =
        haversineDistanceMeters(50.0, -122.0, 50.001, -122.001);
    expect(distance, greaterThan(0));
  });

  test('evaluate rejects invalid coordinates', () {
    final PointAcceptanceResult result = engine.evaluate(
      null,
      NewSessionPoint(
        recordedAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
        tOffsetMs: 0,
        latitude: 120,
        longitude: 0,
        accuracyM: 5,
        altitudeM: null,
        speedMps: null,
        headingDeg: null,
        acceptedForAnalytics: false,
      ),
    );

    expect(result.acceptedForAnalytics, isFalse);
    expect(result.acceptedForReplay, isFalse);
  });

  test('evaluate keeps replay route for poor accuracy samples', () {
    final PointAcceptanceResult result = engine.evaluate(
      null,
      NewSessionPoint(
        recordedAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
        tOffsetMs: 0,
        latitude: 50,
        longitude: -122,
        accuracyM: 70,
        altitudeM: null,
        speedMps: null,
        headingDeg: null,
        acceptedForAnalytics: false,
      ),
    );

    expect(result.acceptedForAnalytics, isFalse);
    expect(result.acceptedForReplay, isTrue);
  });

  test(
      'computeStats calculates average speed from distance and active duration',
      () {
    final DateTime start = DateTime.utc(2026, 1, 1, 0, 0, 0);
    final List<LocalSessionPoint> accepted = <LocalSessionPoint>[
      buildPoint(id: 0, at: start, lat: 50.0, lng: -122.0),
      buildPoint(
          id: 1,
          at: start.add(const Duration(seconds: 2)),
          lat: 50.0005,
          lng: -122.0005),
      buildPoint(
          id: 2,
          at: start.add(const Duration(seconds: 4)),
          lat: 50.001,
          lng: -122.001),
    ];

    final SessionStats stats =
        engine.computeStats(acceptedPoints: accepted, activeDurationS: 4);

    expect(stats.distanceM, greaterThan(0));
    expect(stats.avgSpeedMps, closeTo(stats.distanceM / 4, 0.0001));
  });

  test('computeStats applies elevation smoothing threshold', () {
    final DateTime start = DateTime.utc(2026, 1, 1, 0, 0, 0);
    final List<LocalSessionPoint> accepted = <LocalSessionPoint>[
      buildPoint(id: 0, at: start, lat: 50.0, lng: -122.0, altitude: 1000),
      buildPoint(
          id: 1,
          at: start.add(const Duration(seconds: 2)),
          lat: 50.0002,
          lng: -122.0002,
          altitude: 1005),
      buildPoint(
          id: 2,
          at: start.add(const Duration(seconds: 4)),
          lat: 50.0004,
          lng: -122.0004,
          altitude: 1010),
      buildPoint(
          id: 3,
          at: start.add(const Duration(seconds: 6)),
          lat: 50.0006,
          lng: -122.0006,
          altitude: 1015),
      buildPoint(
          id: 4,
          at: start.add(const Duration(seconds: 8)),
          lat: 50.0008,
          lng: -122.0008,
          altitude: 1020),
      buildPoint(
          id: 5,
          at: start.add(const Duration(seconds: 10)),
          lat: 50.001,
          lng: -122.001,
          altitude: 1030),
    ];

    final SessionStats stats =
        engine.computeStats(acceptedPoints: accepted, activeDurationS: 10);
    expect(stats.elevationGainM, isNotNull);
    expect(stats.elevationGainM!, greaterThan(0));
  });

  test('evaluate keeps replay point when delta exceeds analytics window', () {
    final DateTime start = DateTime.utc(2026, 1, 1, 0, 0, 0);
    final LocalSessionPoint previous = buildPoint(
      id: 1,
      at: start,
      lat: 50.0,
      lng: -122.0,
    );

    final PointAcceptanceResult result = engine.evaluate(
      previous,
      NewSessionPoint(
        recordedAt: start.add(const Duration(seconds: 45)),
        tOffsetMs: 45000,
        latitude: 50.001,
        longitude: -122.001,
        accuracyM: 5,
        altitudeM: null,
        speedMps: null,
        headingDeg: null,
        acceptedForAnalytics: false,
      ),
    );

    expect(result.acceptedForAnalytics, isFalse);
    expect(result.acceptedForReplay, isTrue);
    expect(result.reason, 'invalid_delta');
  });
}
