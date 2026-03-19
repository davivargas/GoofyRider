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
  static const int initialFixStableSamples = 3;

  static const int maxSpeedWindowSeconds = 5;
  static const int maxSpeedPersistenceSamples = 3;
  static const int staleSampleThresholdSeconds = 30;
}
