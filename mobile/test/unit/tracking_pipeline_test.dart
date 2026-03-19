import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/tracking_pipeline.dart';

LocationSample _sample({
  required DateTime timestamp,
  required double latitude,
  required double longitude,
  double accuracyM = 8,
  double altitudeM = 1200,
  double? speedMps,
  double headingDeg = 120,
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
    speedAccuracyMps: speedAccuracyMps,
    verticalAccuracyM: verticalAccuracyM,
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

  test('uses trusted platform speed over geometry fallback when confidence is high', () {
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

  test('classifies poor horizontal accuracy as low confidence once lock is stable', () {
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
}
