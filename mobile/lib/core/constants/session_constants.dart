class SessionConstants {
  SessionConstants._();

  static const int targetIntervalSeconds = 2;
  static const double distanceFilterMeters = 5;
  static const double analyticsAccuracyThresholdMeters = 35;
  static const double softAccuracyThresholdMeters = 60;
  static const double maxSpeedMetersPerSecond = 40;
  static const int minDeltaSeconds = 1;
  static const int maxDeltaSeconds = 20;
  static const int uploadBatchSize = 250;
  static const int minElevationDeltaMeters = 3;
  static const int elevationWindow = 5;
}
