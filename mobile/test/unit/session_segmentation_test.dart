import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_segmentation.dart';

LocalSessionPoint _point({
  required DateTime start,
  required int offsetSeconds,
  required double latitude,
  required double longitude,
  double altitudeM = 1800,
  double speedMps = 8,
  double headingDeg = 120,
  double? distanceDeltaM = 0,
  String? motionState,
  bool acceptedForAnalytics = true,
}) {
  return LocalSessionPoint(
    id: offsetSeconds,
    localSessionId: 1,
    recordedAt: start.add(Duration(seconds: offsetSeconds)),
    tOffsetMs: offsetSeconds * 1000,
    latitude: latitude,
    longitude: longitude,
    accuracyM: 8,
    altitudeM: altitudeM,
    speedMps: speedMps,
    headingDeg: headingDeg,
    acceptedForAnalytics: acceptedForAnalytics,
    qualityClass: acceptedForAnalytics ? 'accept' : 'reject',
    filteredLatitude: latitude,
    filteredLongitude: longitude,
    filteredAltitudeM: altitudeM,
    fusedSpeedMps: speedMps,
    distanceDeltaM: distanceDeltaM,
    motionState: motionState,
  );
}

void main() {
  test(
      'aggregates descent, lift, and idle time and keeps ride avg descent-only',
      () {
    final DateTime start = DateTime.utc(2026, 2, 1, 9, 0, 0);
    final List<LocalSessionPoint> points = <LocalSessionPoint>[
      _point(
        start: start,
        offsetSeconds: 0,
        latitude: 49.0,
        longitude: -123.0,
        distanceDeltaM: 0,
        motionState: 'active_descent',
      ),
      _point(
        start: start,
        offsetSeconds: 5,
        latitude: 49.0004,
        longitude: -123.0002,
        distanceDeltaM: 40,
        motionState: 'active_descent',
      ),
      _point(
        start: start,
        offsetSeconds: 10,
        latitude: 49.0008,
        longitude: -123.0004,
        distanceDeltaM: 50,
        motionState: 'active_descent',
      ),
      _point(
        start: start,
        offsetSeconds: 15,
        latitude: 49.0010,
        longitude: -123.0002,
        distanceDeltaM: 20,
        motionState: 'lift_uphill',
      ),
      _point(
        start: start,
        offsetSeconds: 20,
        latitude: 49.0012,
        longitude: -123.0,
        distanceDeltaM: 20,
        motionState: 'lift_uphill',
      ),
      _point(
        start: start,
        offsetSeconds: 25,
        latitude: 49.0012,
        longitude: -123.0,
        distanceDeltaM: 0,
        motionState: 'stopped_idle',
      ),
      _point(
        start: start,
        offsetSeconds: 30,
        latitude: 49.0012,
        longitude: -123.0,
        distanceDeltaM: 0,
        motionState: 'stopped_idle',
      ),
    ];

    final SessionTimelineAnalysis analysis = analyzeSessionTimeline(
      points: points,
    );
    final SessionStats stats = SessionStats(
      durationS: 30,
      distanceM: analysis.distanceM,
      maxSpeedMps: 16,
      avgSpeedMps: analysis.distanceM / 30,
      elevationGainM: 60,
      elevationLossM: 180,
      descentDurationS: analysis.descentDurationS,
      liftDurationS: analysis.liftDurationS,
      idleDurationS: analysis.idleDurationS,
      descentDistanceM: analysis.descentDistanceM,
      liftDistanceM: analysis.liftDistanceM,
      idleDistanceM: analysis.idleDistanceM,
    );

    expect(analysis.descentDurationS, 10);
    expect(analysis.liftDurationS, 10);
    expect(analysis.idleDurationS, 10);
    expect(analysis.descentDistanceM, 90);
    expect(analysis.liftDistanceM, 40);
    expect(analysis.distanceM, 130);
    expect(stats.rideAvgSpeedMps, 9);
    expect(stats.rideAvgSpeedMps, greaterThan(stats.avgSpeedMps));
  });

  test('stored recovery samples do not fragment a descent timeline', () {
    final DateTime start = DateTime.utc(2026, 2, 2, 9, 0, 0);
    final List<LocalSessionPoint> points = <LocalSessionPoint>[
      _point(
        start: start,
        offsetSeconds: 0,
        latitude: 49.0,
        longitude: -123.0,
        motionState: 'active_descent',
      ),
      _point(
        start: start,
        offsetSeconds: 5,
        latitude: 49.0004,
        longitude: -123.0002,
        distanceDeltaM: 35,
        motionState: 'active_descent',
      ),
      _point(
        start: start,
        offsetSeconds: 10,
        latitude: 49.0008,
        longitude: -123.0004,
        distanceDeltaM: 20,
        motionState: 'low_confidence_recovery',
      ),
      _point(
        start: start,
        offsetSeconds: 15,
        latitude: 49.0012,
        longitude: -123.0006,
        distanceDeltaM: 30,
        motionState: 'active_descent',
      ),
      _point(
        start: start,
        offsetSeconds: 20,
        latitude: 49.0016,
        longitude: -123.0008,
        distanceDeltaM: 30,
        motionState: 'active_descent',
      ),
    ];

    final SessionTimelineAnalysis analysis = analyzeSessionTimeline(
      points: points,
    );

    expect(analysis.segments, hasLength(1));
    expect(analysis.segments.single.type, SessionActivityType.descent);
    expect(analysis.descentDurationS, 20);
  });

  test('replay fallback keeps a brief slowdown inside a descent segment', () {
    final DateTime start = DateTime.utc(2026, 2, 3, 9, 0, 0);
    double latitude = 49.3;
    final List<LocalSessionPoint> points = <LocalSessionPoint>[];

    for (int index = 0; index < 3; index++) {
      points.add(
        _point(
          start: start,
          offsetSeconds: index,
          latitude: latitude,
          longitude: -123.2,
          altitudeM: 2200,
          speedMps: 0.1,
          headingDeg: 120,
          motionState: null,
        ),
      );
      latitude += 0.000001;
    }

    for (int index = 3; index < 12; index++) {
      points.add(
        _point(
          start: start,
          offsetSeconds: index,
          latitude: latitude,
          longitude: -123.2,
          altitudeM: 2200 - ((index - 2) * 3),
          speedMps: 12,
          headingDeg: 140,
          motionState: null,
        ),
      );
      latitude += 0.00012;
    }

    for (int index = 12; index < 17; index++) {
      points.add(
        _point(
          start: start,
          offsetSeconds: index,
          latitude: latitude,
          longitude: -123.2,
          altitudeM: 2170,
          speedMps: 2.6,
          headingDeg: 45 + ((index % 4) * 70),
          motionState: null,
        ),
      );
      latitude += 0.000025;
    }

    final SessionTimelineAnalysis analysis = analyzeSessionTimeline(
      points: points,
    );
    final int firstDescentIndex = analysis.segments.indexWhere(
      (SessionTimelineSegment segment) =>
          segment.type == SessionActivityType.descent,
    );

    expect(firstDescentIndex, greaterThanOrEqualTo(0));
    expect(
      analysis.segments.skip(firstDescentIndex).every(
            (SessionTimelineSegment segment) =>
                segment.type == SessionActivityType.descent,
          ),
      isTrue,
    );
    expect(analysis.descentDurationS, greaterThan(0));
  });

  test('replay fallback recognizes lift segments for old sessions', () {
    final DateTime start = DateTime.utc(2026, 2, 4, 9, 0, 0);
    final List<LocalSessionPoint> points = <LocalSessionPoint>[
      for (int index = 0; index < 4; index++)
        _point(
          start: start,
          offsetSeconds: index,
          latitude: 49.0 + (index * 0.00003),
          longitude: -123.0 + (index * 0.00001),
          speedMps: 3.5,
          altitudeM: 1000 + (index * 0.4),
          headingDeg: 30,
          motionState: null,
        ),
      for (int index = 4; index < 36; index++)
        _point(
          start: start,
          offsetSeconds: index,
          latitude: 49.00012 + (index * 0.00002),
          longitude: -122.99996 + (index * 0.00001),
          speedMps: 5.8,
          altitudeM: 1001.6 + ((index - 3) * 1.9),
          headingDeg: 32 + ((index % 3) * 1.2),
          motionState: null,
        ),
    ];

    final SessionTimelineAnalysis analysis = analyzeSessionTimeline(
      points: points,
    );

    expect(
      analysis.segments.any(
        (SessionTimelineSegment segment) =>
            segment.type == SessionActivityType.lift,
      ),
      isTrue,
    );
    expect(analysis.liftDurationS, greaterThan(0));
  });
}
