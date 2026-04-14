import '../../../../core/constants/session_constants.dart';
import '../location_tracking_repository.dart';
import '../session_models.dart';
import '../tracking_pipeline.dart';
import 'pipeline_types.dart';

/// Pipeline stage 1: classifies each [LocationSample] into accept / low-confidence / reject.
class QualityClassifier {
  DateTime? _lastObservedTimestampUtc;
  int? _lastObservedElapsedRealtimeNs;
  int _stableFixSamples = 0;

  /// The number of stable initial fix samples observed so far.
  /// Used by the coordinator to pass to the motion-state detector.
  int get stableFixSamples => _stableFixSamples;

  void reset() {
    _lastObservedTimestampUtc = null;
    _lastObservedElapsedRealtimeNs = null;
    _stableFixSamples = 0;
  }

  void seedFromPersistedPoints({required List<LocalSessionPoint> points}) {
    for (final point in points) {
      _lastObservedTimestampUtc = point.recordedAt.toUtc();
      _lastObservedElapsedRealtimeNs = point.elapsedRealtimeNs;
      if (point.acceptedForAnalytics &&
          _stableFixSamples < SessionConstants.initialFixStableSamples) {
        _stableFixSamples += 1;
      }
    }
  }

  /// Classify [sample] and update observed-timestamp bookkeeping.
  ///
  /// [lastAcceptedLatitude], [lastAcceptedLongitude], and
  /// [lastAcceptedTimestampUtc] come from the coordinator (speed-fusion stage
  /// owns the accepted-position state).
  ///
  /// [motionState] is the current motion state used for accuracy thresholds.
  QualityDecision classify({
    required LocationSample sample,
    required double? lastAcceptedLatitude,
    required double? lastAcceptedLongitude,
    required DateTime? lastAcceptedTimestampUtc,
    required MotionState motionState,
  }) {
    final decision = _classifyCore(
      sample: sample,
      lastAcceptedLatitude: lastAcceptedLatitude,
      lastAcceptedLongitude: lastAcceptedLongitude,
      lastAcceptedTimestampUtc: lastAcceptedTimestampUtc,
      motionState: motionState,
    );

    // Always update observed timestamps (even for rejected samples).
    _lastObservedTimestampUtc = sample.timestamp.toUtc();
    _lastObservedElapsedRealtimeNs = sample.elapsedRealtimeNs;

    return decision;
  }

  /// Increment stable-fix counter when a sample is accepted with full
  /// confidence. Called by the coordinator after classification.
  void recordAccepted(TrackingQualityClass qualityClass) {
    if (_stableFixSamples < SessionConstants.initialFixStableSamples &&
        qualityClass == TrackingQualityClass.accept) {
      _stableFixSamples += 1;
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  QualityDecision _classifyCore({
    required LocationSample sample,
    required double? lastAcceptedLatitude,
    required double? lastAcceptedLongitude,
    required DateTime? lastAcceptedTimestampUtc,
    required MotionState motionState,
  }) {
    if (!_isValidCoordinate(sample.latitude, sample.longitude)) {
      return const QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.invalidCoordinate,
        score: 0,
      );
    }

    if (!_isTimestampMonotonic(sample)) {
      return const QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.nonMonotonicTimestamp,
        score: 0,
      );
    }

    if (!_isMonotonicClockUnique(sample)) {
      return const QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.duplicateMonotonicTime,
        score: 0,
      );
    }

    if (_isImplausibleJump(
      sample: sample,
      lastAcceptedLatitude: lastAcceptedLatitude,
      lastAcceptedLongitude: lastAcceptedLongitude,
      lastAcceptedTimestampUtc: lastAcceptedTimestampUtc,
      motionState: motionState,
    )) {
      return const QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.implausibleJump,
        score: 0,
      );
    }

    if (_isImplausibleSpeedSpike(
      sample: sample,
      lastAcceptedLatitude: lastAcceptedLatitude,
      lastAcceptedLongitude: lastAcceptedLongitude,
      lastAcceptedTimestampUtc: lastAcceptedTimestampUtc,
      motionState: motionState,
    )) {
      return const QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.implausibleSpeedSpike,
        score: 0,
      );
    }

    final score = _qualityScore(
      horizontalAccuracyM: sample.accuracyM,
      speedAccuracyMps: sample.speedAccuracyMps,
      verticalAccuracyM: sample.verticalAccuracyM,
    );
    final acceptHorizontalAccuracyM =
        _horizontalAcceptThresholdForSample(sample, motionState);

    final horizontalAccuracyM = sample.accuracyM;
    if (horizontalAccuracyM != null &&
        horizontalAccuracyM >
            SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters) {
      return QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.poorHorizontalAccuracy,
        score: score,
      );
    }

    if (_stableFixSamples < SessionConstants.initialFixStableSamples &&
        (horizontalAccuracyM == null ||
            horizontalAccuracyM > acceptHorizontalAccuracyM)) {
      return QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.unstableInitialFix,
        score: score,
      );
    }

    if (horizontalAccuracyM != null &&
        horizontalAccuracyM > acceptHorizontalAccuracyM) {
      return QualityDecision(
        qualityClass: TrackingQualityClass.acceptLowConfidence,
        reason: TrackingQualityReason.poorHorizontalAccuracy,
        score: score,
      );
    }

    return QualityDecision(
      qualityClass: TrackingQualityClass.accept,
      reason: TrackingQualityReason.accepted,
      score: score,
    );
  }

  double _horizontalAcceptThresholdForSample(
    LocationSample sample,
    MotionState motionState,
  ) {
    if (motionState == MotionState.activeDescent) {
      return SessionConstants.activeDescentAcceptHorizontalAccuracyMeters;
    }
    if ((sample.speedMps ?? 0) >=
        SessionConstants.descentSpeedThresholdMetersPerSecond) {
      return SessionConstants.activeDescentAcceptHorizontalAccuracyMeters;
    }
    return SessionConstants.qualityAcceptHorizontalAccuracyMeters;
  }

  bool _isTimestampMonotonic(LocationSample sample) {
    final previousTimestamp = _lastObservedTimestampUtc;
    if (previousTimestamp == null) {
      return true;
    }
    return sample.timestamp.toUtc().isAfter(previousTimestamp);
  }

  bool _isMonotonicClockUnique(LocationSample sample) {
    if (sample.elapsedRealtimeNs == null) {
      return true;
    }
    final previousElapsedRealtimeNs = _lastObservedElapsedRealtimeNs;
    if (previousElapsedRealtimeNs == null) {
      return true;
    }
    return sample.elapsedRealtimeNs! > previousElapsedRealtimeNs;
  }

  bool _isImplausibleJump({
    required LocationSample sample,
    required double? lastAcceptedLatitude,
    required double? lastAcceptedLongitude,
    required DateTime? lastAcceptedTimestampUtc,
    required MotionState motionState,
  }) {
    if (lastAcceptedLatitude == null || lastAcceptedLongitude == null) {
      return false;
    }
    final deltaSeconds = _deltaSecondsFromLastAccepted(
      sample,
      lastAcceptedTimestampUtc,
    );
    if (deltaSeconds <= 0) {
      return false;
    }

    final distance = haversineDistanceMeters(
      lastAcceptedLatitude,
      lastAcceptedLongitude,
      sample.latitude,
      sample.longitude,
    );
    final speedFromGeometry = distance / deltaSeconds;
    if (speedFromGeometry <= SessionConstants.speedHardCapMetersPerSecond) {
      return false;
    }

    if (_assessPlatformSpeedTrust(
          sample: sample,
          geometrySpeedMps: speedFromGeometry,
          motionState: motionState,
          lastAcceptedTimestampUtc: lastAcceptedTimestampUtc,
        ) ==
        PlatformSpeedTrust.strong) {
      return false;
    }

    return speedFromGeometry >
        SessionConstants.speedHardCapMetersPerSecond * 1.4;
  }

  bool _isImplausibleSpeedSpike({
    required LocationSample sample,
    required double? lastAcceptedLatitude,
    required double? lastAcceptedLongitude,
    required DateTime? lastAcceptedTimestampUtc,
    required MotionState motionState,
  }) {
    if (lastAcceptedLatitude == null || lastAcceptedLongitude == null) {
      return false;
    }

    final deltaSeconds = _deltaSecondsFromLastAccepted(
      sample,
      lastAcceptedTimestampUtc,
    );
    if (deltaSeconds <= 0) {
      return false;
    }

    final distance = haversineDistanceMeters(
      lastAcceptedLatitude,
      lastAcceptedLongitude,
      sample.latitude,
      sample.longitude,
    );
    final speedFromGeometry = distance / deltaSeconds;
    if (speedFromGeometry <= SessionConstants.speedHardCapMetersPerSecond) {
      return false;
    }

    return _assessPlatformSpeedTrust(
          sample: sample,
          geometrySpeedMps: speedFromGeometry,
          motionState: motionState,
          lastAcceptedTimestampUtc: lastAcceptedTimestampUtc,
        ) !=
        PlatformSpeedTrust.strong;
  }

  bool _isValidCoordinate(double latitude, double longitude) {
    return latitude >= -90 &&
        latitude <= 90 &&
        longitude >= -180 &&
        longitude <= 180;
  }

  double _qualityScore({
    required double? horizontalAccuracyM,
    required double? speedAccuracyMps,
    required double? verticalAccuracyM,
  }) {
    final horizontalComponent = horizontalAccuracyM == null
        ? 0.6
        : (1 -
                (horizontalAccuracyM /
                    SessionConstants
                        .qualityLowConfidenceHorizontalAccuracyMeters))
            .clamp(0, 1)
            .toDouble();
    final speedComponent = speedAccuracyMps == null
        ? 0.5
        : (1 - (speedAccuracyMps / 4)).clamp(0, 1).toDouble();
    final verticalComponent = verticalAccuracyM == null
        ? 0.5
        : (1 -
                (verticalAccuracyM /
                    SessionConstants.verticalAccuracyWeakThresholdMeters))
            .clamp(0, 1)
            .toDouble();

    return (horizontalComponent * 0.5) +
        (speedComponent * 0.3) +
        (verticalComponent * 0.2);
  }

  // ---------------------------------------------------------------------------
  // Platform speed trust (shared with SpeedFusion — duplicated here because
  // the classifier needs it for implausible-jump / spike checks before the
  // speed-fusion stage runs).
  // ---------------------------------------------------------------------------

  PlatformSpeedTrust _assessPlatformSpeedTrust({
    required LocationSample sample,
    required double geometrySpeedMps,
    required MotionState motionState,
    required DateTime? lastAcceptedTimestampUtc,
  }) {
    final platformSpeed = sample.speedMps;
    if (platformSpeed == null ||
        !platformSpeed.isFinite ||
        platformSpeed < 0 ||
        platformSpeed > SessionConstants.speedHardCapMetersPerSecond) {
      return PlatformSpeedTrust.untrusted;
    }

    final horizontalAccuracyM = sample.accuracyM ??
        SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters;
    final horizontalStrong = horizontalAccuracyM <=
        _horizontalAcceptThresholdForSample(sample, motionState);
    final horizontalUsable = horizontalAccuracyM <=
        SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters;
    if (!horizontalUsable) {
      return PlatformSpeedTrust.untrusted;
    }

    final speedAccuracyMps = sample.speedAccuracyMps;
    final speedStrong = speedAccuracyMps != null &&
        speedAccuracyMps <= SessionConstants.platformSpeedStrongAccuracyMps;
    final speedUsable = speedAccuracyMps == null ||
        speedAccuracyMps <= SessionConstants.platformSpeedUsableAccuracyMps;
    if (!speedUsable) {
      return PlatformSpeedTrust.untrusted;
    }

    final geometryReliable = _isGeometrySpeedReliableForCoherence(
      sample: sample,
      geometrySpeedMps: geometrySpeedMps,
      motionState: motionState,
      lastAcceptedTimestampUtc: lastAcceptedTimestampUtc,
    );
    final mismatchMps = (platformSpeed - geometrySpeedMps).abs();
    final moderateMismatchToleranceMps = _max(
      SessionConstants.platformSpeedModerateMismatchFloorMps,
      platformSpeed * SessionConstants.platformSpeedModerateMismatchRatio,
    );
    final severeMismatchToleranceMps = _max(
      SessionConstants.platformSpeedSevereMismatchFloorMps,
      platformSpeed * SessionConstants.platformSpeedSevereMismatchRatio,
    );

    if (geometryReliable && mismatchMps > severeMismatchToleranceMps) {
      return PlatformSpeedTrust.untrusted;
    }

    if (speedStrong &&
        horizontalStrong &&
        (!geometryReliable || mismatchMps <= moderateMismatchToleranceMps)) {
      return PlatformSpeedTrust.strong;
    }

    if (!geometryReliable || mismatchMps <= moderateMismatchToleranceMps) {
      return PlatformSpeedTrust.moderate;
    }

    return PlatformSpeedTrust.weak;
  }

  bool _isGeometrySpeedReliableForCoherence({
    required LocationSample sample,
    required double geometrySpeedMps,
    required MotionState motionState,
    required DateTime? lastAcceptedTimestampUtc,
  }) {
    if (geometrySpeedMps < SessionConstants.geometryCoherenceMinSpeedMps) {
      return false;
    }

    final deltaSeconds =
        _deltaSecondsFromLastAccepted(sample, lastAcceptedTimestampUtc);
    if (deltaSeconds < SessionConstants.geometryCoherenceMinDeltaSeconds ||
        deltaSeconds > SessionConstants.maxDeltaSeconds) {
      return false;
    }

    final horizontalAccuracyM = sample.accuracyM;
    if (horizontalAccuracyM == null) {
      return false;
    }
    return horizontalAccuracyM <=
        _horizontalAcceptThresholdForSample(sample, motionState);
  }

  double _deltaSecondsFromLastAccepted(
    LocationSample sample,
    DateTime? lastAcceptedTimestampUtc,
  ) {
    if (lastAcceptedTimestampUtc == null) {
      return 0;
    }
    final milliseconds = sample.timestamp
        .toUtc()
        .difference(lastAcceptedTimestampUtc)
        .inMilliseconds;
    if (milliseconds <= 0) {
      return 0;
    }
    return milliseconds / 1000;
  }

  static double _max(double a, double b) => a > b ? a : b;
}
