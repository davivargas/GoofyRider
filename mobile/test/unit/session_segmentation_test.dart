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
    final start = DateTime.utc(2026, 2, 1, 9, 0, 0);
    final points = <LocalSessionPoint>[
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

    final analysis = analyzeSessionTimeline(
      points: points,
    );
    final stats = SessionStats(
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
    final start = DateTime.utc(2026, 2, 2, 9, 0, 0);
    final points = <LocalSessionPoint>[
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

    final analysis = analyzeSessionTimeline(
      points: points,
    );

    expect(analysis.segments, hasLength(1));
    expect(analysis.segments.single.type, SessionActivityType.descent);
    expect(analysis.descentDurationS, 20);
  });

  test('replay fallback keeps a brief slowdown inside a descent segment', () {
    final start = DateTime.utc(2026, 2, 3, 9, 0, 0);
    var latitude = 49.3;
    final points = <LocalSessionPoint>[];

    for (var index = 0; index < 3; index++) {
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

    for (var index = 3; index < 12; index++) {
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

    for (var index = 12; index < 17; index++) {
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

    final analysis = analyzeSessionTimeline(
      points: points,
    );
    final firstDescentIndex = analysis.segments.indexWhere(
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
    final start = DateTime.utc(2026, 2, 4, 9, 0, 0);
    final points = <LocalSessionPoint>[
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

    final analysis = analyzeSessionTimeline(
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

  test(
      'fall-rule: a brief stop (<90s) bracketed by descent stays in descent bucket',
      () {
    final start = DateTime.utc(2026, 3, 1, 9, 0, 0);
    final points = <LocalSessionPoint>[
      // 10s of descent approaching the fall location.
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
      // 60s of stopped samples at the fall position (zero drift).
      for (int offset = 15; offset <= 70; offset += 5)
        _point(
          start: start,
          offsetSeconds: offset,
          latitude: 49.0008,
          longitude: -123.0004,
          distanceDeltaM: 0,
          motionState: 'stopped_idle',
        ),
    ];

    final analysis = analyzeSessionTimeline(points: points);

    // Expect everything to land in descent — this is still "in-run".
    expect(analysis.idleDurationS, 0);
    expect(analysis.descentDurationS, 70);
  });

  test(
      'fall-rule: a long stop (>90s) after descent flips to idle once threshold passes',
      () {
    final start = DateTime.utc(2026, 3, 2, 9, 0, 0);
    final points = <LocalSessionPoint>[
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
      // 120s of stationary samples — the stop goes well past the 90s cutoff.
      for (int offset = 15; offset <= 135; offset += 5)
        _point(
          start: start,
          offsetSeconds: offset,
          latitude: 49.0008,
          longitude: -123.0004,
          distanceDeltaM: 0,
          motionState: 'stopped_idle',
        ),
    ];

    final analysis = analyzeSessionTimeline(points: points);

    // First 90s of the stop stays in descent (fall window), remainder flips.
    expect(analysis.idleDurationS, greaterThan(0));
    expect(analysis.descentDurationS, greaterThan(0));
    // Once we've crossed the 90s cut-off, subsequent intervals bucket as idle.
    // The long-stop test is primarily a "something becomes idle eventually"
    // check so the exact split is tolerant to rounding of the cut-off sample.
    expect(analysis.descentDurationS + analysis.idleDurationS, 135);
  });

  test('fall-rule: a stop immediately after a lift always buckets as idle', () {
    final start = DateTime.utc(2026, 3, 3, 9, 0, 0);
    final points = <LocalSessionPoint>[
      _point(
        start: start,
        offsetSeconds: 0,
        latitude: 49.0,
        longitude: -123.0,
        speedMps: 3.0,
        altitudeM: 1000,
        motionState: 'lift_uphill',
      ),
      _point(
        start: start,
        offsetSeconds: 5,
        latitude: 49.0001,
        longitude: -123.0,
        distanceDeltaM: 12,
        speedMps: 3.0,
        altitudeM: 1005,
        motionState: 'lift_uphill',
      ),
      _point(
        start: start,
        offsetSeconds: 10,
        latitude: 49.0002,
        longitude: -123.0,
        distanceDeltaM: 12,
        speedMps: 3.0,
        altitudeM: 1010,
        motionState: 'lift_uphill',
      ),
      // Stationary immediately after the lift — should all be idle.
      for (int offset = 15; offset <= 40; offset += 5)
        _point(
          start: start,
          offsetSeconds: offset,
          latitude: 49.0002,
          longitude: -123.0,
          distanceDeltaM: 0,
          speedMps: 0,
          altitudeM: 1010,
          motionState: 'stopped_idle',
        ),
    ];

    final analysis = analyzeSessionTimeline(points: points);

    expect(analysis.descentDurationS, 0);
    expect(analysis.liftDurationS, 10);
    expect(analysis.idleDurationS, 30);
  });

  test(
      'layer-2: a 4-min on-slope stop bracketed by descent reclassifies to '
      'descent', () {
    final start = DateTime.utc(2026, 4, 10, 9, 0, 0);
    const stopDurationSeconds = 240;
    final points = <LocalSessionPoint>[
      for (int i = 0; i < 10; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.0 + (i * 0.00008),
          longitude: -123.0 - (i * 0.00008),
          altitudeM: 1800 - (i * 2.0),
          motionState: 'active_descent',
          distanceDeltaM: i == 0 ? 0 : 9,
        ),
      for (int i = 10; i < 10 + stopDurationSeconds; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.00072,
          longitude: -123.00072,
          altitudeM: 1782,
          motionState: 'stopped_idle',
          distanceDeltaM: 0,
        ),
      for (int i = 10 + stopDurationSeconds;
          i < 20 + stopDurationSeconds;
          i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.00072 +
              ((i - (9 + stopDurationSeconds)) * 0.00008),
          longitude: -123.00072 -
              ((i - (9 + stopDurationSeconds)) * 0.00008),
          altitudeM: 1782 - ((i - (9 + stopDurationSeconds)) * 2.0),
          motionState: 'active_descent',
          distanceDeltaM: 9,
        ),
    ];

    final reclassified = analyzeSessionTimeline(points: points);
    final layer1 = analyzeSessionTimeline(
      points: points,
      applyIdleReclassification: false,
    );

    expect(layer1.idleDurationS, greaterThan(0));
    expect(reclassified.idleDurationS, 0);
    expect(reclassified.reclassifiedIdleDurationS, layer1.idleDurationS);
    expect(
      reclassified.descentDurationS,
      layer1.descentDurationS + layer1.idleDurationS,
    );
  });

  test(
      'layer-2: a 12-min on-slope stop exceeds the max duration and stays idle',
      () {
    final start = DateTime.utc(2026, 4, 11, 9, 0, 0);
    const stopDurationSeconds = 720;
    final points = <LocalSessionPoint>[
      for (int i = 0; i < 10; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.0 + (i * 0.00008),
          longitude: -123.0 - (i * 0.00008),
          altitudeM: 1800 - (i * 2.0),
          motionState: 'active_descent',
          distanceDeltaM: i == 0 ? 0 : 9,
        ),
      for (int i = 10; i < 10 + stopDurationSeconds; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.00072,
          longitude: -123.00072,
          altitudeM: 1782,
          motionState: 'stopped_idle',
          distanceDeltaM: 0,
        ),
      for (int i = 10 + stopDurationSeconds;
          i < 20 + stopDurationSeconds;
          i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.00072 +
              ((i - (9 + stopDurationSeconds)) * 0.00008),
          longitude: -123.00072 -
              ((i - (9 + stopDurationSeconds)) * 0.00008),
          altitudeM: 1782 - ((i - (9 + stopDurationSeconds)) * 2.0),
          motionState: 'active_descent',
          distanceDeltaM: 9,
        ),
    ];

    final analysis = analyzeSessionTimeline(points: points);

    expect(analysis.reclassifiedIdleDurationS, 0);
    expect(analysis.idleDurationS, greaterThan(480));
  });

  test(
      'layer-2: a 4-min stop with >30m drift radius is treated as walked and '
      'stays idle', () {
    final start = DateTime.utc(2026, 4, 12, 9, 0, 0);
    const stopSamples = 240;
    // ~0.000009 lat ≈ 1 m. Drift linearly 1 m/sample so the idle segment
    // ends up spanning ~200 m, well past the 30 m reclassification radius.
    final points = <LocalSessionPoint>[
      for (int i = 0; i < 10; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.0,
          longitude: -123.0,
          altitudeM: 1800,
          motionState: 'active_descent',
          distanceDeltaM: i == 0 ? 0 : 9,
        ),
      for (int i = 10; i < 10 + stopSamples; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.0 + ((i - 10) * 0.000009),
          longitude: -123.0,
          altitudeM: 1800,
          motionState: 'stopped_idle',
          distanceDeltaM: 0,
        ),
      for (int i = 10 + stopSamples; i < 20 + stopSamples; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.0 + (stopSamples * 0.000009),
          longitude: -123.0,
          altitudeM: 1800,
          motionState: 'active_descent',
          distanceDeltaM: 9,
        ),
    ];

    final analysis = analyzeSessionTimeline(points: points);
    expect(analysis.reclassifiedIdleDurationS, 0);
    expect(analysis.idleDurationS, greaterThan(0));
  });

  test(
      'layer-2: a descent → stop → lift bracket does not reclassify the idle '
      '(queue at the bottom of a run)', () {
    final start = DateTime.utc(2026, 4, 13, 9, 0, 0);
    const stopSamples = 240;
    final points = <LocalSessionPoint>[
      for (int i = 0; i < 10; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.0 + (i * 0.00008),
          longitude: -123.0 - (i * 0.00008),
          altitudeM: 1800 - (i * 2.0),
          motionState: 'active_descent',
          distanceDeltaM: i == 0 ? 0 : 9,
        ),
      for (int i = 10; i < 10 + stopSamples; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.00072,
          longitude: -123.00072,
          altitudeM: 1782,
          motionState: 'stopped_idle',
          distanceDeltaM: 0,
        ),
      for (int i = 10 + stopSamples; i < 40 + stopSamples; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.00072 +
              ((i - (9 + stopSamples)) * 0.00003),
          longitude: -123.00072 +
              ((i - (9 + stopSamples)) * 0.00001),
          altitudeM: 1782 + ((i - (9 + stopSamples)) * 1.2),
          speedMps: 3.2,
          headingDeg: 30,
          motionState: 'lift_uphill',
          distanceDeltaM: 3,
        ),
    ];

    final analysis = analyzeSessionTimeline(points: points);
    expect(analysis.reclassifiedIdleDurationS, 0);
    expect(analysis.idleDurationS, greaterThan(0));
  });

  test(
      'layer-2: an idle segment with >20 m elevation delta across its span '
      'stays idle (not an on-slope stop)', () {
    final start = DateTime.utc(2026, 4, 14, 9, 0, 0);
    const stopSamples = 240;
    final points = <LocalSessionPoint>[
      for (int i = 0; i < 10; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.0 + (i * 0.00008),
          longitude: -123.0 - (i * 0.00008),
          altitudeM: 1800 - (i * 2.0),
          motionState: 'active_descent',
          distanceDeltaM: i == 0 ? 0 : 9,
        ),
      for (int i = 10; i < 10 + stopSamples; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.00072,
          longitude: -123.00072,
          // Altitude slowly drops through the stop — by the time Layer 1
          // has flipped to idle, the idle segment has a 40 m span.
          altitudeM: 1782 - ((i - 10) * 0.2),
          motionState: 'stopped_idle',
          distanceDeltaM: 0,
        ),
      for (int i = 10 + stopSamples; i < 20 + stopSamples; i++)
        _point(
          start: start,
          offsetSeconds: i,
          latitude: 49.00072 +
              ((i - (9 + stopSamples)) * 0.00008),
          longitude: -123.00072 -
              ((i - (9 + stopSamples)) * 0.00008),
          altitudeM: 1734 - ((i - (9 + stopSamples)) * 2.0),
          motionState: 'active_descent',
          distanceDeltaM: 9,
        ),
    ];

    final analysis = analyzeSessionTimeline(points: points);
    expect(analysis.reclassifiedIdleDurationS, 0);
    expect(analysis.idleDurationS, greaterThan(0));
  });

  test(
      'fall-rule: a stop that drifts past the radius flips to idle even inside 90s',
      () {
    final start = DateTime.utc(2026, 3, 4, 9, 0, 0);
    // ~0.00018 lat ≈ 20 m north. 15m is the cutoff.
    final driftedLat = 49.0008 + 0.00018;
    final points = <LocalSessionPoint>[
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
      // First stopped sample anchors the fall window...
      _point(
        start: start,
        offsetSeconds: 15,
        latitude: 49.0008,
        longitude: -123.0004,
        distanceDeltaM: 0,
        motionState: 'stopped_idle',
      ),
      // ...second stopped sample has drifted ~20m north — past the radius.
      _point(
        start: start,
        offsetSeconds: 20,
        latitude: driftedLat,
        longitude: -123.0004,
        distanceDeltaM: 0,
        motionState: 'stopped_idle',
      ),
      _point(
        start: start,
        offsetSeconds: 25,
        latitude: driftedLat,
        longitude: -123.0004,
        distanceDeltaM: 0,
        motionState: 'stopped_idle',
      ),
    ];

    final analysis = analyzeSessionTimeline(points: points);

    // The interval that lands on the first stopped sample (offset 10→15) is
    // still inside the fall radius, so it stays descent. Once the drift
    // exceeds 15m, the subsequent intervals flip to idle.
    expect(analysis.descentDurationS, 15);
    expect(analysis.idleDurationS, 10);
  });
}
