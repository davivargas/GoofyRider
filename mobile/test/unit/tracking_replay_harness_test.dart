import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/tracking_pipeline.dart';

class ReplayOutcome {
  const ReplayOutcome({
    required this.distanceM,
    required this.maxSpeedMps,
    required this.acceptedCount,
    required this.rejectCount,
    required this.lowConfidenceCount,
    required this.lastMotionState,
  });

  final double distanceM;
  final double maxSpeedMps;
  final int acceptedCount;
  final int rejectCount;
  final int lowConfidenceCount;
  final MotionState? lastMotionState;
}

ReplayOutcome replayTrace(List<LocationSample> samples) {
  final DateTime startedAt = samples.first.timestamp.toUtc();
  final TrackingPipelineEngine engine = TrackingPipelineEngine();
  int acceptedCount = 0;
  int rejectCount = 0;
  int lowConfidenceCount = 0;
  TrackingProcessResult? last;

  for (final LocationSample sample in samples) {
    last = engine.processSample(
      sample: sample,
      sessionStartedAtUtc: startedAt,
      activeDurationS: sample.timestamp.difference(startedAt).inSeconds,
    );
    if (last.point.acceptedForAnalytics) {
      acceptedCount += 1;
    }
    if (last.point.qualityClass == 'reject') {
      rejectCount += 1;
    }
    if (last.point.qualityClass == 'accept_low_confidence') {
      lowConfidenceCount += 1;
    }
  }

  return ReplayOutcome(
    distanceM: last?.stats.distanceM ?? 0,
    maxSpeedMps: last?.stats.maxSpeedMps ?? 0,
    acceptedCount: acceptedCount,
    rejectCount: rejectCount,
    lowConfidenceCount: lowConfidenceCount,
    lastMotionState: last?.motionState,
  );
}

LocationSample _sample({
  required DateTime at,
  required double lat,
  required double lon,
  double accuracy = 8,
  double speed = 6,
  double altitude = 1000,
  double heading = 90,
  double? bearingAccuracyDeg = 12,
}) {
  return LocationSample(
    timestamp: at,
    latitude: lat,
    longitude: lon,
    accuracyM: accuracy,
    altitudeM: altitude,
    speedMps: speed,
    headingDeg: heading,
    speedAccuracyMps: 1.0,
    verticalAccuracyM: 12,
    bearingAccuracyDeg: bearingAccuracyDeg,
  );
}

void main() {
  test('replay harness suppresses static jitter distance inflation', () {
    final DateTime start = DateTime.utc(2026, 2, 1, 10, 0, 0);
    final List<LocationSample> trace = <LocationSample>[
      for (int i = 0; i < 40; i++)
        _sample(
          at: start.add(Duration(seconds: i)),
          lat: 50.0 + ((i.isEven ? 1 : -1) * 0.000006),
          lon: -122.0 + ((i % 3 == 0 ? 1 : -1) * 0.000006),
          speed: 0.2,
        ),
    ];

    final ReplayOutcome outcome = replayTrace(trace);
    expect(outcome.distanceM, lessThan(30));
    expect(outcome.maxSpeedMps, lessThan(4));
  });

  test('replay harness rejects geometry spikes and keeps max speed sane', () {
    final DateTime start = DateTime.utc(2026, 2, 2, 10, 0, 0);
    final List<LocationSample> trace = <LocationSample>[
      for (int i = 0; i < 10; i++)
        _sample(
          at: start.add(Duration(seconds: i)),
          lat: 49.0 + (i * 0.00009),
          lon: -123.0 - (i * 0.00009),
          speed: 13,
        ),
      _sample(
        at: start.add(const Duration(seconds: 11)),
        lat: 49.04,
        lon: -123.04,
        speed: 40,
      ),
      for (int i = 12; i < 20; i++)
        _sample(
          at: start.add(Duration(seconds: i)),
          lat: 49.001 + (i * 0.00009),
          lon: -123.001 - (i * 0.00009),
          speed: 12,
        ),
    ];

    final ReplayOutcome outcome = replayTrace(trace);
    expect(outcome.rejectCount, greaterThanOrEqualTo(1));
    expect(outcome.maxSpeedMps, lessThan(25));
  });

  test('replay harness requires heading stability to classify lift motion', () {
    final DateTime start = DateTime.utc(2026, 2, 3, 10, 0, 0);
    final List<LocationSample> trace = <LocationSample>[
      for (int i = 0; i < 4; i++)
        _sample(
          at: start.add(Duration(seconds: i)),
          lat: 49.0 + (i * 0.00003),
          lon: -123.0 + (i * 0.00001),
          speed: 3.5,
          altitude: 1000 + (i * 0.4),
        ),
      for (int i = 4; i < 36; i++)
        _sample(
          at: start.add(Duration(seconds: i)),
          lat: 49.00012 + (i * 0.00002),
          lon: -122.99996 + (i * 0.00001),
          speed: 5.8,
          altitude: 1001.6 + ((i - 3) * 1.9),
          heading: 32 + ((i % 3) * 1.2),
          bearingAccuracyDeg: 8,
        ),
    ];

    expect(
      replayTrace(trace).lastMotionState,
      MotionState.liftUphill,
    );
  });

  test(
      'replay harness marks active descent with 30m accuracy as low confidence',
      () {
    final DateTime start = DateTime.utc(2026, 2, 4, 10, 0, 0);
    final TrackingPipelineEngine engine = TrackingPipelineEngine();

    for (int i = 0; i < 14; i++) {
      engine.processSample(
        sample: _sample(
          at: start.add(Duration(seconds: i)),
          lat: 50.0 + (i * 0.00008),
          lon: -122.0 - (i * 0.00009),
          speed: 11,
          altitude: 1800 - (i * 2.5),
          accuracy: 10,
          heading: 140,
          bearingAccuracyDeg: 10,
        ),
        sessionStartedAtUtc: start,
        activeDurationS: i,
      );
    }

    final TrackingProcessResult lowConfidence = engine.processSample(
      sample: _sample(
        at: start.add(const Duration(seconds: 15)),
        lat: 50.0013,
        lon: -122.00145,
        speed: 12,
        altitude: 1762,
        accuracy: 30,
        heading: 138,
        bearingAccuracyDeg: 10,
      ),
      sessionStartedAtUtc: start,
      activeDurationS: 15,
    );

    expect(lowConfidence.motionState, MotionState.activeDescent);
    expect(lowConfidence.point.qualityClass, 'accept_low_confidence');
    expect(lowConfidence.lowAccuracy, isTrue);
  });
}
