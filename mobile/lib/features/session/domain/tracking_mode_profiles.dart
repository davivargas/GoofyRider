import '../../../core/constants/session_constants.dart';
import 'location_tracking_repository.dart';

const int _maxStaleSampleThresholdSeconds = 120;

enum TrackingModePriority {
  highAccuracy,
  balancedPower,
}

/// Configuration bundle the native bridge uses to build a `LocationRequest`.
///
/// Intentionally small: the stack uses only two profiles — [TrackingMode.acquiring]
/// while waiting for the first usable fix, and [TrackingMode.active] for the rest
/// of the session. Motion state still drives UI, classifier accuracy bands, and
/// stats bucketing, but it no longer changes the location stream.
class TrackingModeProfile {
  const TrackingModeProfile({
    required this.priority,
    required this.intervalMs,
    required this.minIntervalMs,
    required this.maxDelayMs,
    required this.minDistanceM,
    required this.waitForAccurate,
    required this.watchdogThresholdMs,
  });

  final TrackingModePriority priority;
  final int intervalMs;
  final int minIntervalMs;
  final int maxDelayMs;
  final double minDistanceM;
  final bool waitForAccurate;
  final int watchdogThresholdMs;

  int get staleSampleThresholdSeconds =>
      ((watchdogThresholdMs + 999) ~/ 1000).clamp(
        SessionConstants.staleSampleThresholdSeconds,
        _maxStaleSampleThresholdSeconds,
      );

  Duration get sampleWatchdogThreshold =>
      Duration(milliseconds: watchdogThresholdMs);

  Map<String, dynamic> toChannelPayload() {
    return <String, dynamic>{
      'priority': switch (priority) {
        TrackingModePriority.highAccuracy => 'high_accuracy',
        TrackingModePriority.balancedPower => 'balanced_power',
      },
      'intervalMs': intervalMs,
      'minIntervalMs': minIntervalMs,
      'maxDelayMs': maxDelayMs,
      'minDistanceM': minDistanceM,
      'waitForAccurate': waitForAccurate,
      'watchdogThresholdMs': watchdogThresholdMs,
    };
  }
}

/// Central registry of the two location-tracking profiles used by the session
/// tracker: [acquiring] while searching for the first usable fix, then
/// [active] for the rest of the session.
///
/// Both profiles request HIGH_ACCURACY at 1 Hz with zero spatial throttling
/// and zero batching. The older per-motion-state profiles (lift, walking,
/// stopped, recovery) were removed because `setMinUpdateDistanceMeters` in
/// throttled modes looked like "GPS off" to users, and the mode-change
/// reconfigures were adding cold-start gaps at every transition.
class TrackingModeProfiles {
  TrackingModeProfiles._();

  /// Profile used from the moment the stream starts until the quality
  /// classifier returns its first accepted sample.
  ///
  /// `waitForAccurate` is deliberately `false`: the classifier, not the native
  /// provider, owns first-fix quality. Leaving it `true` at this layer would
  /// stack with the classifier guard and add ~10 s to every session start.
  static const TrackingModeProfile acquiring = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 1000,
    minIntervalMs: 500,
    maxDelayMs: 0,
    minDistanceM: 0,
    waitForAccurate: false,
    watchdogThresholdMs: 8000,
  );

  /// Profile used for the rest of the session after the first accepted fix.
  /// Same request parameters as [acquiring]; only the watchdog is tighter
  /// because we now expect samples to be arriving steadily.
  static const TrackingModeProfile active = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 1000,
    minIntervalMs: 500,
    maxDelayMs: 0,
    minDistanceM: 0,
    waitForAccurate: false,
    watchdogThresholdMs: 4000,
  );

  static TrackingModeProfile forMode(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.acquiring:
        return acquiring;
      case TrackingMode.active:
        return active;
    }
  }
}
