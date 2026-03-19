import 'location_tracking_repository.dart';

enum TrackingModePriority {
  highAccuracy,
  balancedPower,
}

class TrackingModeProfile {
  const TrackingModeProfile({
    required this.priority,
    required this.intervalMs,
    required this.minIntervalMs,
    required this.maxDelayMs,
    required this.minDistanceM,
    required this.waitForAccurate,
  });

  final TrackingModePriority priority;
  final int intervalMs;
  final int minIntervalMs;
  final int maxDelayMs;
  final double minDistanceM;
  final bool waitForAccurate;

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
    };
  }
}

class TrackingModeProfiles {
  TrackingModeProfiles._();

  // Downhill: target >=1Hz with room for bursts up to 5Hz.
  static const TrackingModeProfile activeDescent = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 1000,
    minIntervalMs: 200,
    maxDelayMs: 1000,
    minDistanceM: 1,
    waitForAccurate: false,
  );

  static const TrackingModeProfile initializingFix = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 1000,
    minIntervalMs: 500,
    maxDelayMs: 0,
    minDistanceM: 0,
    waitForAccurate: true,
  );

  static const TrackingModeProfile liftUphill = TrackingModeProfile(
    priority: TrackingModePriority.balancedPower,
    intervalMs: 3000,
    minIntervalMs: 2000,
    maxDelayMs: 10000,
    minDistanceM: 5,
    waitForAccurate: false,
  );

  static const TrackingModeProfile stoppedIdle = TrackingModeProfile(
    priority: TrackingModePriority.balancedPower,
    intervalMs: 8000,
    minIntervalMs: 5000,
    maxDelayMs: 30000,
    minDistanceM: 8,
    waitForAccurate: false,
  );

  static const TrackingModeProfile lowConfidenceRecovery = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 1200,
    minIntervalMs: 600,
    maxDelayMs: 0,
    minDistanceM: 0,
    waitForAccurate: true,
  );

  static TrackingModeProfile forMode(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.initializingFix:
        return initializingFix;
      case TrackingMode.activeDescent:
        return activeDescent;
      case TrackingMode.liftUphill:
        return liftUphill;
      case TrackingMode.stoppedIdle:
        return stoppedIdle;
      case TrackingMode.lowConfidenceRecovery:
        return lowConfidenceRecovery;
    }
  }
}
