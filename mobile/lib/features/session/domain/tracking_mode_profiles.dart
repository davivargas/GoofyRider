import '../../../core/constants/session_constants.dart';
import 'location_tracking_repository.dart';

const int _staleSampleSlackMs = 15000;
const int _maxStaleSampleThresholdSeconds = 120;

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

  int get expectedUpdateGapMs => maxDelayMs > 0 ? maxDelayMs : intervalMs;

  int get staleSampleThresholdSeconds {
    final int thresholdMs = expectedUpdateGapMs + _staleSampleSlackMs;
    return ((thresholdMs + 999) ~/ 1000).clamp(
      SessionConstants.staleSampleThresholdSeconds,
      _maxStaleSampleThresholdSeconds,
    );
  }

  Duration get sampleWatchdogThreshold =>
      Duration(seconds: staleSampleThresholdSeconds);

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

  // Downhill: target just over 1Hz with room for short bursts.
  static const TrackingModeProfile activeDescent = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 900,
    minIntervalMs: 250,
    maxDelayMs: 900,
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
    intervalMs: 4000,
    minIntervalMs: 2500,
    maxDelayMs: 12000,
    minDistanceM: 6,
    waitForAccurate: false,
  );

  static const TrackingModeProfile stoppedIdle = TrackingModeProfile(
    priority: TrackingModePriority.balancedPower,
    intervalMs: 12000,
    minIntervalMs: 8000,
    maxDelayMs: 45000,
    minDistanceM: 10,
    waitForAccurate: false,
  );

  static const TrackingModeProfile lowConfidenceRecovery = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 1000,
    minIntervalMs: 500,
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
