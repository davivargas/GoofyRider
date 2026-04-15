class SessionConstants {
  SessionConstants._();

  static const int maxLiveRoutePoints = 3000;
  static const double speedHardCapMetersPerSecond = 45;
  static const int maxDeltaSeconds = 20;
  static const int uploadBatchSize = 250;

  static const double qualityAcceptHorizontalAccuracyMeters = 35;
  static const double activeDescentAcceptHorizontalAccuracyMeters = 25;
  static const double qualityLowConfidenceHorizontalAccuracyMeters = 80;
  static const double distanceNoiseRatio = 0.35;
  static const double minimumDistanceDeltaMeters = 2.5;

  static const double verticalAccuracyStrongThresholdMeters = 20;
  static const double verticalAccuracyWeakThresholdMeters = 45;
  static const double verticalSmoothingAlphaStrong = 0.35;
  static const double verticalSmoothingAlphaWeak = 0.15;
  static const double verticalHysteresisFloorMeters = 2.5;
  static const double verticalHysteresisAccuracyFactor = 0.25;

  static const double stoppedSpeedThresholdMetersPerSecond = 0.8;
  static const int stoppedPersistenceSeconds = 12;
  static const double descentSpeedThresholdMetersPerSecond = 4.0;
  static const int descentPersistenceSeconds = 6;
  static const double liftMinSpeedThresholdMetersPerSecond = 1.2;
  static const double liftMaxSpeedThresholdMetersPerSecond = 8.0;
  static const int liftPersistenceSeconds = 15;
  static const int liftHeadingWindowSamples = 8;
  static const double liftHeadingStabilityThreshold = 0.85;
  static const double headingAccuracyStrongThresholdDeg = 30;
  static const int recoveryPersistenceSeconds = 4;

  /// A `stoppedIdle` interval bracketed by prior descent stays bucketed as
  /// descent only while the stop is shorter than this, so brief falls and
  /// quick rests don't steal from descent time.
  static const int fallMaxStopDurationSeconds = 90;

  /// Maximum horizontal drift from the stop-start anchor tolerated while a
  /// stop is still treated as an in-run fall/rest rather than true idle.
  static const double fallMaxDriftMeters = 15;

  /// Auto-pause fires after this many seconds of contiguous stillness.
  /// §4.2 of the GPS overhaul plan: 5 min covers the restaurant-break case
  /// without false-pausing slow lift-line shuffles.
  static const int autoPauseStillnessThresholdSeconds = 300;

  /// Maximum horizontal drift from the auto-pause anchor tolerated before
  /// the stillness window resets. Wider than the fall-rule drift because
  /// this governs lodge-scale stationarity, not mid-run falls.
  static const double autoPauseMaxDriftMeters = 30;

  static const int maxSpeedWindowSeconds = 5;
  static const int maxSpeedPersistenceSamples = 3;
  static const int staleSampleThresholdSeconds = 30;

  static const double platformSpeedStrongAccuracyMps = 1.6;
  static const double platformSpeedUsableAccuracyMps = 3.5;
  static const double platformSpeedModerateMismatchFloorMps = 4.5;
  static const double platformSpeedModerateMismatchRatio = 0.85;
  static const double platformSpeedSevereMismatchFloorMps = 7.0;
  static const double platformSpeedSevereMismatchRatio = 1.2;
  static const double platformSpeedModerateBlendWeight = 0.85;
  static const double platformSpeedWeakBlendWeight = 0.65;
  static const double geometryCoherenceMinSpeedMps = 2.0;
  static const double geometryCoherenceMinDeltaSeconds = 0.8;

  static const double liveSpeedTauInitializingRiseSeconds = 2.2;
  static const double liveSpeedTauInitializingFallSeconds = 1.2;
  static const double liveSpeedTauActiveDescentRiseSeconds = 1.2;
  static const double liveSpeedTauActiveDescentFallSeconds = 0.8;
  static const double liveSpeedTauLiftRiseSeconds = 5.0;
  static const double liveSpeedTauLiftFallSeconds = 2.4;
  static const double liveSpeedTauStoppedRiseSeconds = 18.0;
  static const double liveSpeedTauStoppedFallSeconds = 4.0;
  static const double liveSpeedTauRecoveryRiseSeconds = 1.6;
  static const double liveSpeedTauRecoveryFallSeconds = 1.0;
}
