import '../tracking_pipeline.dart';

/// Quality classification result for a single location sample.
class QualityDecision {
  const QualityDecision({
    required this.qualityClass,
    required this.reason,
    required this.score,
  });

  final TrackingQualityClass qualityClass;
  final TrackingQualityReason reason;
  final double score;
}

/// Trust level assigned to the platform-reported speed value.
enum PlatformSpeedTrust {
  strong,
  moderate,
  weak,
  untrusted,
}

/// Result of fusing platform and geometry-derived speeds.
class FusedSpeedResult {
  const FusedSpeedResult({
    required this.speedMps,
    required this.platformTrust,
  });

  final double speedMps;
  final PlatformSpeedTrust platformTrust;
}

/// Filtered altitude and vertical delta for a single sample.
class VerticalResult {
  const VerticalResult({
    required this.filteredAltitudeM,
    required this.deltaM,
  });

  final double? filteredAltitudeM;
  final double deltaM;
}

/// A single speed observation used in the max-speed sliding window.
class SpeedWindowSample {
  const SpeedWindowSample({
    required this.time,
    required this.speedMps,
  });

  final DateTime time;
  final double speedMps;
}

/// A single heading observation used in the lift-detection heading window.
class HeadingWindowSample {
  const HeadingWindowSample({
    required this.time,
    required this.headingRad,
  });

  final DateTime time;
  final double headingRad;
}
