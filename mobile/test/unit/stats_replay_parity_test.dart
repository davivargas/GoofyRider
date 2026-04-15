import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_segmentation.dart';
import 'package:goofyrider_mobile/features/session/domain/tracking_pipeline.dart';

LocationSample _sample({
  required DateTime at,
  required double lat,
  required double lon,
  double accuracy = 6,
  double speed = 8,
  double altitude = 2000,
  double heading = 90,
  double? bearingAccuracyDeg = 8,
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
    verticalAccuracyM: 10,
    bearingAccuracyDeg: bearingAccuracyDeg,
  );
}

LocalSessionPoint _toLocalPoint(NewSessionPoint p, int id) {
  return LocalSessionPoint(
    id: id,
    localSessionId: 1,
    recordedAt: p.recordedAt,
    tOffsetMs: p.tOffsetMs,
    latitude: p.latitude,
    longitude: p.longitude,
    accuracyM: p.accuracyM,
    altitudeM: p.altitudeM,
    speedMps: p.speedMps,
    headingDeg: p.headingDeg,
    acceptedForAnalytics: p.acceptedForAnalytics,
    elapsedRealtimeNs: p.elapsedRealtimeNs,
    verticalAccuracyM: p.verticalAccuracyM,
    speedAccuracyMps: p.speedAccuracyMps,
    bearingAccuracyDeg: p.bearingAccuracyDeg,
    provider: p.provider,
    isMocked: p.isMocked,
    qualityClass: p.qualityClass,
    qualityScore: p.qualityScore,
    qualityReason: p.qualityReason,
    filteredLatitude: p.filteredLatitude,
    filteredLongitude: p.filteredLongitude,
    filteredAltitudeM: p.filteredAltitudeM,
    fusedSpeedMps: p.fusedSpeedMps,
    derivedSpeedMps: p.derivedSpeedMps,
    distanceDeltaM: p.distanceDeltaM,
    motionState: p.motionState,
  );
}

class _LiveRunResult {
  const _LiveRunResult({
    required this.stats,
    required this.storedPoints,
  });

  final SessionStats stats;
  final List<LocalSessionPoint> storedPoints;
}

_LiveRunResult _runLive(List<LocationSample> samples) {
  final engine = TrackingPipelineEngine();
  final start = samples.first.timestamp.toUtc();
  final storedPoints = <LocalSessionPoint>[];
  TrackingProcessResult? last;
  var id = 1;

  for (final sample in samples) {
    last = engine.processSample(
      sample: sample,
      sessionStartedAtUtc: start,
      activeDurationS: sample.timestamp.toUtc().difference(start).inSeconds,
    );
    storedPoints.add(_toLocalPoint(last.point, id++));
  }

  return _LiveRunResult(
    stats: last!.stats,
    storedPoints: storedPoints,
  );
}

void main() {
  test(
      'stats-replay parity: live accumulator and replay segmentation agree '
      'on per-bucket totals for a multi-phase trace',
      () {
    final start = DateTime.utc(2026, 4, 1, 9, 0, 0);
    final samples = <LocationSample>[];

    // Phase 1: 20 s of descent, well above the descent speed band.
    var lat = 49.0;
    var lon = -123.0;
    var altitude = 2200.0;
    for (var i = 0; i < 20; i++) {
      samples.add(_sample(
        at: start.add(Duration(seconds: i)),
        lat: lat,
        lon: lon,
        speed: 11,
        altitude: altitude,
        heading: 140,
        bearingAccuracyDeg: 6,
      ));
      lat += 0.00009;
      lon -= 0.00008;
      altitude -= 3;
    }

    // Phase 2: 30 s stationary — shorter than fallMaxStopDurationSeconds,
    // exercises the fall-rule "stays in descent" branch.
    final stopLat = lat;
    final stopLon = lon;
    final stopAltitude = altitude;
    for (var i = 20; i < 50; i++) {
      samples.add(_sample(
        at: start.add(Duration(seconds: i)),
        lat: stopLat,
        lon: stopLon,
        speed: 0.1,
        altitude: stopAltitude,
        heading: 140,
        bearingAccuracyDeg: 6,
      ));
    }

    // Phase 3: 25 s of descent again after the fall.
    for (var i = 50; i < 75; i++) {
      samples.add(_sample(
        at: start.add(Duration(seconds: i)),
        lat: lat,
        lon: lon,
        speed: 11,
        altitude: altitude,
        heading: 140,
        bearingAccuracyDeg: 6,
      ));
      lat += 0.00009;
      lon -= 0.00008;
      altitude -= 3;
    }

    // Phase 4: 45 s of lift-like uphill motion with a stable heading so the
    // detector can resolve to liftUphill after the persistence window.
    for (var i = 75; i < 120; i++) {
      samples.add(_sample(
        at: start.add(Duration(seconds: i)),
        lat: lat,
        lon: lon,
        speed: 3.2,
        altitude: altitude,
        heading: 30,
        bearingAccuracyDeg: 4,
      ));
      lat += 0.00003;
      lon += 0.00001;
      altitude += 2;
    }

    // Phase 5: 30 s stop after the lift — should bucket as idle (no
    // fall-rule carryover because the last stable activity was lift).
    final liftStopLat = lat;
    final liftStopLon = lon;
    final liftStopAltitude = altitude;
    for (var i = 120; i < 150; i++) {
      samples.add(_sample(
        at: start.add(Duration(seconds: i)),
        lat: liftStopLat,
        lon: liftStopLon,
        speed: 0.0,
        altitude: liftStopAltitude,
        heading: 30,
        bearingAccuracyDeg: 4,
      ));
    }

    final live = _runLive(samples);
    // Step 4c parity compares the live Layer-1 accumulator against the
    // replay path's Layer-1 output. Disable the Layer-2 reclassification
    // pass so the two surfaces line up (Layer 2 is replay-only by design).
    final replay = analyzeSessionTimeline(
      points: live.storedPoints,
      applyIdleReclassification: false,
    );

    expect(replay.descentDurationS, live.stats.descentDurationS);
    expect(replay.liftDurationS, live.stats.liftDurationS);
    expect(replay.idleDurationS, live.stats.idleDurationS);
    expect(
      replay.descentDistanceM,
      closeTo(live.stats.descentDistanceM, 0.0005),
    );
    expect(
      replay.liftDistanceM,
      closeTo(live.stats.liftDistanceM, 0.0005),
    );
    expect(
      replay.idleDistanceM,
      closeTo(live.stats.idleDistanceM, 0.0005),
    );
    expect(
      replay.distanceM,
      closeTo(live.stats.distanceM, 0.0005),
    );
  });

  test(
      'stats-replay parity: long fall beyond 90 s threshold buckets live '
      'and replay identically',
      () {
    final start = DateTime.utc(2026, 4, 2, 9, 0, 0);
    final samples = <LocationSample>[];

    // 20 s of descent to seed the last-stable-activity bucket.
    var lat = 49.0;
    var lon = -123.0;
    var altitude = 2100.0;
    for (var i = 0; i < 20; i++) {
      samples.add(_sample(
        at: start.add(Duration(seconds: i)),
        lat: lat,
        lon: lon,
        speed: 11,
        altitude: altitude,
        heading: 140,
        bearingAccuracyDeg: 6,
      ));
      lat += 0.00009;
      lon -= 0.00008;
      altitude -= 3;
    }

    // 130 s stationary — well past fallMaxStopDurationSeconds so a portion
    // of the stop must flip to idle.
    final stopLat = lat;
    final stopLon = lon;
    final stopAltitude = altitude;
    for (var i = 20; i < 150; i++) {
      samples.add(_sample(
        at: start.add(Duration(seconds: i)),
        lat: stopLat,
        lon: stopLon,
        speed: 0.1,
        altitude: stopAltitude,
        heading: 140,
        bearingAccuracyDeg: 6,
      ));
    }

    final live = _runLive(samples);
    // Step 4c parity compares the live Layer-1 accumulator against the
    // replay path's Layer-1 output. Disable the Layer-2 reclassification
    // pass so the two surfaces line up (Layer 2 is replay-only by design).
    final replay = analyzeSessionTimeline(
      points: live.storedPoints,
      applyIdleReclassification: false,
    );

    expect(replay.descentDurationS, live.stats.descentDurationS);
    expect(replay.liftDurationS, live.stats.liftDurationS);
    expect(replay.idleDurationS, live.stats.idleDurationS);
    expect(
      replay.descentDistanceM,
      closeTo(live.stats.descentDistanceM, 0.0005),
    );
    expect(
      replay.liftDistanceM,
      closeTo(live.stats.liftDistanceM, 0.0005),
    );
    expect(
      replay.idleDistanceM,
      closeTo(live.stats.idleDistanceM, 0.0005),
    );
  });
}
