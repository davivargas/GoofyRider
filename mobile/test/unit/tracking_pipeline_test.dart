import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/tracking_pipeline.dart';

LocationSample _sample({
  required DateTime timestamp,
  required double latitude,
  required double longitude,
  double accuracyM = 8,
  double altitudeM = 1200,
  double? speedMps,
  double headingDeg = 120,
  double? bearingAccuracyDeg,
  double? speedAccuracyMps,
  double? verticalAccuracyM = 12,
}) {
  return LocationSample(
    timestamp: timestamp,
    latitude: latitude,
    longitude: longitude,
    accuracyM: accuracyM,
    altitudeM: altitudeM,
    speedMps: speedMps,
    headingDeg: headingDeg,
    bearingAccuracyDeg: bearingAccuracyDeg,
    speedAccuracyMps: speedAccuracyMps,
    verticalAccuracyM: verticalAccuracyM,
  );
}

LocalSessionPoint _persistedPoint({
  required int id,
  required DateTime recordedAt,
  required int tOffsetMs,
  required bool acceptedForAnalytics,
  required String motionState,
  required double latitude,
  required double longitude,
  double? altitudeM = 1200,
  double? speedMps,
  double? fusedSpeedMps,
  double? derivedSpeedMps,
}) {
  return LocalSessionPoint(
    id: id,
    localSessionId: 1,
    recordedAt: recordedAt,
    tOffsetMs: tOffsetMs,
    latitude: latitude,
    longitude: longitude,
    accuracyM: 8,
    altitudeM: altitudeM,
    speedMps: speedMps,
    headingDeg: 120,
    acceptedForAnalytics: acceptedForAnalytics,
    qualityClass: acceptedForAnalytics ? 'accept' : 'reject',
    filteredLatitude: latitude,
    filteredLongitude: longitude,
    filteredAltitudeM: altitudeM,
    fusedSpeedMps: fusedSpeedMps,
    derivedSpeedMps: derivedSpeedMps,
    motionState: motionState,
  );
}

void main() {
  test('suppresses distance inflation for near-static jitter', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime sessionStart = DateTime.utc(2026, 1, 1, 10, 0, 0);

    for (int index = 0; index < 30; index++) {
      final double jitterLat = 50.0 + ((index.isEven ? 1 : -1) * 0.000005);
      final double jitterLng = -122.0 + ((index % 3 == 0 ? 1 : -1) * 0.000005);
      engine.processSample(
        sample: _sample(
          timestamp: sessionStart.add(Duration(seconds: index)),
          latitude: jitterLat,
          longitude: jitterLng,
          speedMps: 0.2,
        ),
        sessionStartedAtUtc: sessionStart,
        activeDurationS: index,
      );
    }

    final TrackingProcessResult last = engine.processSample(
      sample: _sample(
        timestamp: sessionStart.add(const Duration(seconds: 31)),
        latitude: 50.000004,
        longitude: -122.000004,
        speedMps: 0.1,
      ),
      sessionStartedAtUtc: sessionStart,
      activeDurationS: 31,
    );

    expect(last.stats.distanceM, lessThan(25));
    expect(last.motionState, MotionState.stoppedIdle);
  });

  test('rejects untrusted geometry spikes and avoids fake max speed', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime sessionStart = DateTime.utc(2026, 1, 1, 12, 0, 0);

    for (int index = 0; index < 8; index++) {
      engine.processSample(
        sample: _sample(
          timestamp: sessionStart.add(Duration(seconds: index)),
          latitude: 50.0 + (index * 0.00008),
          longitude: -122.0 - (index * 0.00008),
          speedMps: 12,
          speedAccuracyMps: 0.8,
        ),
        sessionStartedAtUtc: sessionStart,
        activeDurationS: index,
      );
    }

    final TrackingProcessResult spike = engine.processSample(
      sample: _sample(
        timestamp: sessionStart.add(const Duration(seconds: 9)),
        latitude: 50.03,
        longitude: -122.03,
        speedMps: null,
        speedAccuracyMps: null,
      ),
      sessionStartedAtUtc: sessionStart,
      activeDurationS: 9,
    );

    expect(spike.point.acceptedForAnalytics, isFalse);
    expect(spike.point.qualityClass, 'reject');

    final TrackingProcessResult afterRecovery = engine.processSample(
      sample: _sample(
        timestamp: sessionStart.add(const Duration(seconds: 10)),
        latitude: 50.0009,
        longitude: -122.0009,
        speedMps: 11,
        speedAccuracyMps: 1.0,
      ),
      sessionStartedAtUtc: sessionStart,
      activeDurationS: 10,
    );

    expect(afterRecovery.stats.maxSpeedMps, lessThan(25));
  });

  test(
      'uses trusted platform speed over geometry fallback when confidence is high',
      () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime sessionStart = DateTime.utc(2026, 1, 2, 8, 0, 0);

    for (int index = 0; index < 3; index++) {
      engine.processSample(
        sample: _sample(
          timestamp: sessionStart.add(Duration(seconds: index)),
          latitude: 49.0 + (index * 0.00004),
          longitude: -123.0,
          speedMps: 6,
          speedAccuracyMps: 0.7,
        ),
        sessionStartedAtUtc: sessionStart,
        activeDurationS: index,
      );
    }

    final TrackingProcessResult result = engine.processSample(
      sample: _sample(
        timestamp: sessionStart.add(const Duration(seconds: 4)),
        latitude: 49.000332,
        longitude: -123.0,
        speedMps: 14,
        speedAccuracyMps: 0.5,
      ),
      sessionStartedAtUtc: sessionStart,
      activeDurationS: 4,
    );

    expect(result.point.fusedSpeedMps, closeTo(14, 1.0));
    expect(result.point.qualityClass, isNot('reject'));
  });

  test(
      'classifies poor horizontal accuracy as low confidence once lock is stable',
      () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime sessionStart = DateTime.utc(2026, 1, 3, 9, 0, 0);

    for (int index = 0; index < 4; index++) {
      engine.processSample(
        sample: _sample(
          timestamp: sessionStart.add(Duration(seconds: index)),
          latitude: 51.0 + (index * 0.00006),
          longitude: -121.0,
          speedMps: 7,
          accuracyM: 10,
        ),
        sessionStartedAtUtc: sessionStart,
        activeDurationS: index,
      );
    }

    final TrackingProcessResult lowConfidence = engine.processSample(
      sample: _sample(
        timestamp: sessionStart.add(const Duration(seconds: 5)),
        latitude: 51.00032,
        longitude: -121.00002,
        speedMps: 6,
        accuracyM: 55,
      ),
      sessionStartedAtUtc: sessionStart,
      activeDurationS: 5,
    );

    expect(lowConfidence.point.acceptedForAnalytics, isTrue);
    expect(lowConfidence.point.qualityClass, 'accept_low_confidence');
    expect(lowConfidence.lowAccuracy, isTrue);
  });

  test('time-aware live smoothing responds to actual sample gaps', () {
    TrackingProcessResult runScenario({required int gapSeconds}) {
      final TrackingPipelineEngine engine = TrackingPipelineEngine();
      final DateTime start = DateTime.utc(2026, 1, 4, 10, 0, 0);
      double latitude = 48.5;

      for (int index = 0; index < 8; index++) {
        latitude += 0.00007;
        engine.processSample(
          sample: _sample(
            timestamp: start.add(Duration(seconds: index)),
            latitude: latitude,
            longitude: -122.5,
            altitudeM: 1800 - (index * 2),
            speedMps: 8,
            speedAccuracyMps: 0.8,
            accuracyM: 10,
          ),
          sessionStartedAtUtc: start,
          activeDurationS: index,
        );
      }

      return engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: 8 + gapSeconds)),
          latitude: latitude + 0.000006,
          longitude: -122.5,
          altitudeM: 1780,
          speedMps: 16,
          speedAccuracyMps: 0.6,
          accuracyM: 55,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: 8 + gapSeconds,
      );
    }

    final TrackingProcessResult shortGap = runScenario(gapSeconds: 1);
    final TrackingProcessResult longGap = runScenario(gapSeconds: 5);

    expect(longGap.liveSpeedMps, greaterThan(shortGap.liveSpeedMps + 1.0));
    expect(shortGap.point.qualityClass, isNot('reject'));
    expect(longGap.point.qualityClass, isNot('reject'));
  });

  test('tracks steady downhill acceleration with believable live speed', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 5, 11, 0, 0);
    double latitude = 49.2;
    TrackingProcessResult? last;
    double previousLive = 0;

    for (int index = 0; index < 16; index++) {
      latitude += 0.0001;
      final TrackingProcessResult current = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -123.2,
          altitudeM: 2200 - (index * 3),
          speedMps: 5 + (index * 0.7),
          speedAccuracyMps: 0.7,
          accuracyM: 6,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
      if (index > 2) {
        expect(current.liveSpeedMps, greaterThanOrEqualTo(previousLive - 0.3));
      }
      previousLive = current.liveSpeedMps;
      last = current;
    }

    expect(last, isNotNull);
    expect(last!.motionState, MotionState.activeDescent);
    expect(last.liveSpeedMps, greaterThan(11));
    expect(last.liveSpeedMps, lessThan(last.point.fusedSpeedMps!));
  });

  test('drops live speed quickly after sharp deceleration to stop', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 6, 9, 0, 0);
    double latitude = 47.8;
    TrackingProcessResult last = engine.processSample(
      sample: _sample(
        timestamp: start,
        latitude: latitude,
        longitude: -121.6,
        altitudeM: 2100,
        speedMps: 12,
        speedAccuracyMps: 0.8,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 0,
    );

    for (int index = 1; index < 14; index++) {
      latitude += 0.00011;
      last = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -121.6,
          altitudeM: 2100 - (index * 2),
          speedMps: 13,
          speedAccuracyMps: 0.8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    final double beforeDrop = last.liveSpeedMps;
    final TrackingProcessResult drop1 = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 14)),
        latitude: latitude + 0.000001,
        longitude: -121.6,
        altitudeM: 2072,
        speedMps: 0.4,
        speedAccuracyMps: 0.9,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 14,
    );
    final TrackingProcessResult drop2 = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 15)),
        latitude: latitude + 0.0000012,
        longitude: -121.6,
        altitudeM: 2072,
        speedMps: 0.2,
        speedAccuracyMps: 1.1,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 15,
    );
    final TrackingProcessResult drop3 = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 16)),
        latitude: latitude + 0.0000013,
        longitude: -121.6,
        altitudeM: 2072,
        speedMps: 0.1,
        speedAccuracyMps: 1.1,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 16,
    );

    expect(drop1.liveSpeedMps, lessThan(beforeDrop - 3));
    expect(drop2.liveSpeedMps, lessThan(drop1.liveSpeedMps));
    expect(drop3.liveSpeedMps, lessThan(2));
  });

  test('keeps fused speed near platform when geometry is noisy', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 7, 8, 0, 0);

    for (int index = 0; index < 5; index++) {
      engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: 50.4 + (index * 0.00009),
          longitude: -122.8,
          altitudeM: 1950 - (index * 2),
          speedMps: 8,
          speedAccuracyMps: 0.9,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    final TrackingProcessResult noisyGeometry = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 6)),
        latitude: 50.400455,
        longitude: -122.8,
        altitudeM: 1938,
        speedMps: 14,
        speedAccuracyMps: 0.5,
        accuracyM: 55,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 6,
    );

    expect(noisyGeometry.point.qualityClass, 'accept_low_confidence');
    expect(noisyGeometry.point.fusedSpeedMps, greaterThan(11));
  });

  test('falls back toward geometry when platform speed accuracy is poor', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 8, 10, 0, 0);

    for (int index = 0; index < 5; index++) {
      engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: 49.6 + (index * 0.00007),
          longitude: -123.4,
          altitudeM: 2050 - index.toDouble(),
          speedMps: 7,
          speedAccuracyMps: 0.8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    final TrackingProcessResult poorPlatform = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 6)),
        latitude: 49.60062,
        longitude: -123.4,
        altitudeM: 2043,
        speedMps: 18,
        speedAccuracyMps: 5.2,
        accuracyM: 8,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 6,
    );

    final double fused = poorPlatform.point.fusedSpeedMps!;
    final double derived = poorPlatform.point.derivedSpeedMps!;

    expect((fused - derived).abs(), lessThan((fused - 18).abs()));
    expect(fused, lessThan(18));
  });

  test('handles mixed trusted and untrusted platform-speed samples', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 9, 10, 0, 0);

    for (int index = 0; index < 5; index++) {
      engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: 48.9 + (index * 0.00008),
          longitude: -123.1,
          altitudeM: 1800 - (index * 2),
          speedMps: 9,
          speedAccuracyMps: 0.8,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    final TrackingProcessResult trusted = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 6)),
        latitude: 48.900405,
        longitude: -123.1,
        altitudeM: 1788,
        speedMps: 15,
        speedAccuracyMps: 0.5,
        accuracyM: 50,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 6,
    );

    final TrackingProcessResult untrusted = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 7)),
        latitude: 48.90052,
        longitude: -123.1,
        altitudeM: 1786,
        speedMps: 15,
        speedAccuracyMps: 4.8,
        accuracyM: 7,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 7,
    );

    final double trustedFused = trusted.point.fusedSpeedMps!;
    final double trustedDerived = trusted.point.derivedSpeedMps!;
    final double untrustedFused = untrusted.point.fusedSpeedMps!;
    final double untrustedDerived = untrusted.point.derivedSpeedMps!;

    expect(trustedFused, greaterThan(12));
    expect(
      (trustedFused - 15).abs(),
      lessThan((trustedFused - trustedDerived).abs()),
    );
    expect(
      (untrustedFused - untrustedDerived).abs(),
      lessThan((untrustedFused - 15).abs()),
    );
  });

  test('max-speed window resists single-sample spikes', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 10, 8, 0, 0);
    double latitude = 50.1;
    TrackingProcessResult last = engine.processSample(
      sample: _sample(
        timestamp: start,
        latitude: latitude,
        longitude: -122.1,
        altitudeM: 2100,
        speedMps: 12,
        speedAccuracyMps: 0.8,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 0,
    );

    for (int index = 1; index < 10; index++) {
      latitude += 0.00011;
      last = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.1,
          altitudeM: 2100 - (index * 2),
          speedMps: 12,
          speedAccuracyMps: 0.8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    latitude += 0.00029;
    final TrackingProcessResult spike = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 10)),
        latitude: latitude,
        longitude: -122.1,
        altitudeM: 2080,
        speedMps: 32,
        speedAccuracyMps: 0.7,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 10,
    );

    for (int index = 11; index < 16; index++) {
      latitude += 0.00011;
      last = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.1,
          altitudeM: 2080 - ((index - 10) * 2),
          speedMps: 12,
          speedAccuracyMps: 0.8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(spike.liveSpeedMps, greaterThan(20));
    expect(last.stats.maxSpeedMps, lessThan(18));
  });

  test('applies heavier smoothing after transition to stopped mode', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 11, 7, 0, 0);
    double latitude = 49.9;

    TrackingProcessResult last = engine.processSample(
      sample: _sample(
        timestamp: start,
        latitude: latitude,
        longitude: -122.9,
        altitudeM: 2200,
        speedMps: 12,
        speedAccuracyMps: 0.7,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 0,
    );

    for (int index = 1; index < 16; index++) {
      latitude += 0.00011;
      last = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.9,
          altitudeM: 2200 - (index * 2),
          speedMps: 12,
          speedAccuracyMps: 0.7,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    final double activeBaseline = last.liveSpeedMps;
    final TrackingProcessResult activeSpike = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 16)),
        latitude: latitude + 0.00002,
        longitude: -122.9,
        altitudeM: 2168,
        speedMps: 18,
        speedAccuracyMps: 0.6,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 16,
    );
    final double activeDelta = activeSpike.liveSpeedMps - activeBaseline;
    expect(activeDelta, greaterThan(1));

    double stopLatitude = latitude + 0.000021;
    TrackingProcessResult stopped = activeSpike;
    for (int index = 17; index < 33; index++) {
      stopLatitude += 0.000001;
      stopped = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: stopLatitude,
          longitude: -122.9,
          altitudeM: 2168,
          speedMps: 0.1,
          speedAccuracyMps: 1.2,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(stopped.motionState, MotionState.stoppedIdle);
    final double stoppedBaseline = stopped.liveSpeedMps;
    final TrackingProcessResult stoppedSpike = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 33)),
        latitude: stopLatitude + 0.000002,
        longitude: -122.9,
        altitudeM: 2168,
        speedMps: 3,
        speedAccuracyMps: 0.8,
        accuracyM: 8,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 33,
    );

    final double stoppedDelta = stoppedSpike.liveSpeedMps - stoppedBaseline;
    expect(stoppedDelta, lessThan(activeDelta * 0.7));
  });

  test('uses the previous stable state on the sample that flips into descent',
      () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 12, 7, 0, 0);
    double latitude = 49.7;

    TrackingProcessResult settled = engine.processSample(
      sample: _sample(
        timestamp: start,
        latitude: latitude,
        longitude: -123.0,
        altitudeM: 2250,
        speedMps: 0.1,
        speedAccuracyMps: 1.0,
        accuracyM: 8,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 0,
    );

    for (int index = 1; index < 20; index++) {
      latitude += 0.000001;
      settled = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -123.0,
          altitudeM: 2250,
          speedMps: 0.1,
          speedAccuracyMps: 1.0,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(settled.motionState, MotionState.stoppedIdle);

    TrackingProcessResult transition = settled;
    for (int index = 20; index < 26; index++) {
      latitude += 0.00012;
      transition = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -123.0,
          altitudeM: 2250 - ((index - 19) * 3),
          speedMps: 12,
          speedAccuracyMps: 0.7,
          accuracyM: 6,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(transition.motionState, MotionState.activeDescent);
    expect(transition.liveSpeedMps, lessThan(5));

    latitude += 0.00012;
    final TrackingProcessResult followUp = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 26)),
        latitude: latitude,
        longitude: -123.0,
        altitudeM: 2229,
        speedMps: 12,
        speedAccuracyMps: 0.7,
        accuracyM: 6,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 26,
    );

    expect(followUp.liveSpeedMps, greaterThan(transition.liveSpeedMps + 2));
  });

  test(
      'rejected samples hold displayed speed while advancing the smoothing clock',
      () {
    ({
      TrackingProcessResult baseline,
      TrackingProcessResult? rejected,
      TrackingProcessResult recovery,
    }) runScenario({
      required bool insertRejectedGap,
    }) {
      final TrackingPipelineEngine engine = TrackingPipelineEngine();
      final DateTime start = DateTime.utc(2026, 1, 13, 8, 0, 0);
      double latitude = 48.8;
      TrackingProcessResult baseline = engine.processSample(
        sample: _sample(
          timestamp: start,
          latitude: latitude,
          longitude: -122.6,
          altitudeM: 2100,
          speedMps: 8,
          speedAccuracyMps: 0.8,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: 0,
      );

      for (int index = 1; index < 8; index++) {
        latitude += 0.00009;
        baseline = engine.processSample(
          sample: _sample(
            timestamp: start.add(Duration(seconds: index)),
            latitude: latitude,
            longitude: -122.6,
            altitudeM: 2100 - (index * 2),
            speedMps: 8,
            speedAccuracyMps: 0.8,
            accuracyM: 8,
          ),
          sessionStartedAtUtc: start,
          activeDurationS: index,
        );
      }

      TrackingProcessResult? rejected;
      if (insertRejectedGap) {
        latitude += 0.00002;
        rejected = engine.processSample(
          sample: _sample(
            timestamp: start.add(const Duration(seconds: 8)),
            latitude: latitude,
            longitude: -122.6,
            altitudeM: 2084,
            speedMps: 18,
            speedAccuracyMps: 0.7,
            accuracyM: 95,
          ),
          sessionStartedAtUtc: start,
          activeDurationS: 8,
        );
      }

      latitude += 0.00018;
      final TrackingProcessResult recovery = engine.processSample(
        sample: _sample(
          timestamp: start.add(const Duration(seconds: 9)),
          latitude: latitude,
          longitude: -122.6,
          altitudeM: 2080,
          speedMps: 16,
          speedAccuracyMps: 0.6,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: 9,
      );

      return (
        baseline: baseline,
        rejected: rejected,
        recovery: recovery,
      );
    }

    final ({
      TrackingProcessResult baseline,
      TrackingProcessResult? rejected,
      TrackingProcessResult recovery,
    }) withRejected = runScenario(insertRejectedGap: true);
    final ({
      TrackingProcessResult baseline,
      TrackingProcessResult? rejected,
      TrackingProcessResult recovery,
    }) withoutRejected = runScenario(insertRejectedGap: false);

    expect(withRejected.rejected, isNotNull);
    expect(withRejected.rejected!.point.qualityClass, 'reject');
    expect(
      withRejected.rejected!.liveSpeedMps,
      closeTo(withRejected.baseline.liveSpeedMps, 0.001),
    );
    expect(
      withRejected.recovery.liveSpeedMps,
      lessThan(withoutRejected.recovery.liveSpeedMps - 0.5),
    );
  });

  test('holds the previous stopped state through ambiguous movement', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 14, 8, 0, 0);
    double latitude = 49.4;

    TrackingProcessResult settled = engine.processSample(
      sample: _sample(
        timestamp: start,
        latitude: latitude,
        longitude: -122.4,
        altitudeM: 2180,
        speedMps: 0.1,
        speedAccuracyMps: 1.0,
        accuracyM: 8,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 0,
    );

    for (int index = 1; index < 20; index++) {
      latitude += 0.000001;
      settled = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.4,
          altitudeM: 2180,
          speedMps: 0.1,
          speedAccuracyMps: 1.0,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(settled.motionState, MotionState.stoppedIdle);

    TrackingProcessResult ambiguous = settled;
    for (int index = 20; index < 29; index++) {
      latitude += 0.000025;
      ambiguous = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.4,
          altitudeM: 2180,
          speedMps: 2.6,
          speedAccuracyMps: 0.8,
          accuracyM: 8,
          headingDeg: 45 + ((index % 4) * 70),
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(ambiguous.motionState, MotionState.stoppedIdle);
    expect(ambiguous.liveSpeedMps, lessThan(2));
  });

  test('ambiguous samples do not keep low-confidence recovery sticky', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 15, 8, 0, 0);
    double latitude = 49.6;

    TrackingProcessResult settled = engine.processSample(
      sample: _sample(
        timestamp: start,
        latitude: latitude,
        longitude: -122.2,
        altitudeM: 2200,
        speedMps: 0.1,
        speedAccuracyMps: 1.0,
        accuracyM: 8,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 0,
    );

    for (int index = 1; index < 20; index++) {
      latitude += 0.000001;
      settled = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.2,
          altitudeM: 2200,
          speedMps: 0.1,
          speedAccuracyMps: 1.0,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(settled.motionState, MotionState.stoppedIdle);

    TrackingProcessResult recovery = settled;
    for (int index = 20; index < 23; index++) {
      latitude += 0.00002;
      recovery = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.2,
          altitudeM: 2200,
          speedMps: 14,
          speedAccuracyMps: 0.7,
          accuracyM: 95,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(recovery.motionState, MotionState.lowConfidenceRecovery);

    TrackingProcessResult ambiguous = recovery;
    for (int index = 23; index < 33; index++) {
      latitude += 0.000025;
      ambiguous = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.2,
          altitudeM: 2200,
          speedMps: 2.6,
          speedAccuracyMps: 0.8,
          accuracyM: 8,
          headingDeg: 45 + ((index % 4) * 70),
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
    }

    expect(ambiguous.motionState, MotionState.stoppedIdle);
  });

  test('live stats keep ride average tied to descent time only', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 16, 7, 0, 0);
    double latitude = 49.5;

    for (int index = 0; index < 3; index++) {
      engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.8,
          altitudeM: 2200,
          speedMps: 0.1,
          speedAccuracyMps: 1.0,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
      latitude += 0.000001;
    }

    TrackingProcessResult last = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 3)),
        latitude: latitude,
        longitude: -122.8,
        altitudeM: 2197,
        speedMps: 12,
        speedAccuracyMps: 0.8,
        accuracyM: 8,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 3,
    );
    latitude += 0.00012;

    for (int index = 4; index < 13; index++) {
      last = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.8,
          altitudeM: 2197 - ((index - 2) * 3),
          speedMps: 12,
          speedAccuracyMps: 0.8,
          accuracyM: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
      latitude += 0.00012;
    }

    for (int index = 13; index < 45; index++) {
      last = engine.processSample(
        sample: _sample(
          timestamp: start.add(Duration(seconds: index)),
          latitude: latitude,
          longitude: -122.79996 + ((index - 13) * 0.00001),
          altitudeM: 2164 + ((index - 12) * 1.9),
          speedMps: 5.8,
          speedAccuracyMps: 0.8,
          accuracyM: 8,
          headingDeg: 32 + ((index % 3) * 1.2),
          bearingAccuracyDeg: 8,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: index,
      );
      latitude += 0.00002;
    }

    expect(last.motionState, MotionState.liftUphill);
    expect(last.stats.descentDurationS, greaterThan(0));
    expect(last.stats.liftDurationS, greaterThan(0));
    expect(last.stats.rideAvgSpeedMps, greaterThan(last.stats.avgSpeedMps));
  });

  test('seedFromPersistedPoints restores the last stable motion fallback', () {
    final TrackingPipelineEngine engine = TrackingPipelineEngine();
    final DateTime start = DateTime.utc(2026, 1, 17, 8, 0, 0);

    engine.seedFromPersistedPoints(
      points: <LocalSessionPoint>[
        _persistedPoint(
          id: 1,
          recordedAt: start,
          tOffsetMs: 0,
          acceptedForAnalytics: true,
          motionState: MotionState.activeDescent.wireValue,
          latitude: 50.0,
          longitude: -123.0,
          altitudeM: 1800,
          speedMps: 12,
          fusedSpeedMps: 12,
        ),
        _persistedPoint(
          id: 2,
          recordedAt: start.add(const Duration(seconds: 1)),
          tOffsetMs: 1000,
          acceptedForAnalytics: true,
          motionState: MotionState.activeDescent.wireValue,
          latitude: 50.0001,
          longitude: -123.0,
          altitudeM: 1798,
          speedMps: 12,
          fusedSpeedMps: 12,
        ),
        _persistedPoint(
          id: 3,
          recordedAt: start.add(const Duration(seconds: 2)),
          tOffsetMs: 2000,
          acceptedForAnalytics: true,
          motionState: MotionState.activeDescent.wireValue,
          latitude: 50.0002,
          longitude: -123.0,
          altitudeM: 1796,
          speedMps: 12,
          fusedSpeedMps: 12,
        ),
        _persistedPoint(
          id: 4,
          recordedAt: start.add(const Duration(seconds: 5)),
          tOffsetMs: 5000,
          acceptedForAnalytics: false,
          motionState: MotionState.lowConfidenceRecovery.wireValue,
          latitude: 50.0004,
          longitude: -123.0,
          altitudeM: 1790,
          speedMps: 14,
          fusedSpeedMps: 14,
        ),
      ],
      stats: SessionStats.zero,
    );

    final TrackingProcessResult result = engine.processSample(
      sample: _sample(
        timestamp: start.add(const Duration(seconds: 12)),
        latitude: 50.00045,
        longitude: -123.0,
        altitudeM: 1790,
        speedMps: 2.6,
        speedAccuracyMps: 0.8,
        accuracyM: 8,
        headingDeg: 210,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 12,
    );

    expect(result.motionState, MotionState.activeDescent);
  });
}
