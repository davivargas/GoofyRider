import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/constants/session_constants.dart';
import 'package:goofyrider_mobile/features/session/presentation/recording/auto_pause_tracker.dart';

void main() {
  group('AutoPauseTracker', () {
    final start = DateTime.utc(2026, 4, 14, 12, 0, 0);
    const anchorLat = 49.0;
    const anchorLon = -123.0;

    test(
        'accumulates stillness and triggers auto-pause once 5 minutes of '
        'low-speed samples have elapsed inside the drift radius',
        () {
      final tracker = AutoPauseTracker();

      // Minute 0 — first still sample anchors the window.
      final first = tracker.observe(
        sampleTimeUtc: start,
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.1,
      );
      expect(first.isStill, isTrue);
      expect(first.triggered, isFalse);
      expect(first.stillnessDurationS, 0);

      // Minute 4:59 — still inside the window, not yet triggered.
      final almost = tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 4, seconds: 59)),
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      expect(almost.triggered, isFalse);
      expect(almost.stillnessDurationS,
          SessionConstants.autoPauseStillnessThresholdSeconds - 1);

      // Minute 5:00 — crosses the threshold.
      final trigger = tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 5)),
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.2,
      );
      expect(trigger.triggered, isTrue);
      expect(trigger.stillnessDurationS,
          SessionConstants.autoPauseStillnessThresholdSeconds);
    });

    test(
        'a motion sample resets the stillness window so the tracker has to '
        're-accumulate the full 5 minutes',
        () {
      final tracker = AutoPauseTracker();

      tracker.observe(
        sampleTimeUtc: start,
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.1,
      );
      // A quick burst of motion (speed above the stopped threshold) resets.
      final moving = tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 2)),
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps:
            SessionConstants.stoppedSpeedThresholdMetersPerSecond + 0.1,
      );
      expect(moving.isStill, isFalse);
      expect(tracker.isTrackingStillness, isFalse);

      // A fresh still sample starts a new window at t=2m — so a trigger
      // at t=6m corresponds to 4m of stillness and must NOT fire yet.
      tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 2, seconds: 1)),
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      final probe = tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 6)),
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      expect(probe.triggered, isFalse);
    });

    test(
        'drifting past the max radius re-anchors the window instead of '
        'accumulating stillness across the walked distance',
        () {
      final tracker = AutoPauseTracker();

      tracker.observe(
        sampleTimeUtc: start,
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      // ~0.0005 degrees latitude ≈ 55 m north — past the 30 m default.
      final drifted = tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 3)),
        latitude: anchorLat + 0.0005,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      expect(drifted.isStill, isFalse);
      // The drift sample re-anchors the window to its own timestamp, so the
      // next observation measures against that fresh anchor rather than
      // inheriting the original 3 min of accumulated stillness.
      final reAnchored = tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 3, seconds: 1)),
        latitude: anchorLat + 0.0005,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      expect(reAnchored.isStill, isTrue);
      expect(reAnchored.stillnessDurationS, 1);
      expect(reAnchored.triggered, isFalse);
    });

    test(
        'small drift inside the radius keeps accumulating stillness — '
        'handheld GPS wander at a coffee break should still auto-pause',
        () {
      final tracker = AutoPauseTracker();

      tracker.observe(
        sampleTimeUtc: start,
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      // ~0.0001 deg ≈ 11 m — well inside 30 m.
      final trigger = tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 5, seconds: 1)),
        latitude: anchorLat + 0.0001,
        longitude: anchorLon + 0.0001,
        speedMps: 0.1,
      );
      expect(trigger.triggered, isTrue);
    });

    test('reset clears the stillness window so the next sample re-anchors',
        () {
      final tracker = AutoPauseTracker();

      tracker.observe(
        sampleTimeUtc: start,
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      expect(tracker.isTrackingStillness, isTrue);

      tracker.reset();
      expect(tracker.isTrackingStillness, isFalse);

      // Re-anchoring after reset means the 5-min clock starts fresh.
      final fresh = tracker.observe(
        sampleTimeUtc: start.add(const Duration(minutes: 4)),
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      expect(fresh.stillnessDurationS, 0);
      expect(fresh.triggered, isFalse);
    });

    test(
        'honors a custom threshold passed via the constructor so tests can '
        'drive the trigger without burning 5 real minutes of sample data',
        () {
      final tracker = AutoPauseTracker(stillnessThresholdSeconds: 30);

      tracker.observe(
        sampleTimeUtc: start,
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      final trigger = tracker.observe(
        sampleTimeUtc: start.add(const Duration(seconds: 30)),
        latitude: anchorLat,
        longitude: anchorLon,
        speedMps: 0.0,
      );
      expect(trigger.triggered, isTrue);
    });
  });
}
