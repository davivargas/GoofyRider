import 'dart:collection';
import 'dart:math' as math;

import '../../../../core/constants/session_constants.dart';
import '../location_tracking_repository.dart';
import '../session_models.dart';
import '../tracking_pipeline.dart';
import 'pipeline_types.dart';

/// Pipeline stage 3: derives geometry speed, fuses with platform speed,
/// manages the max-speed sliding window, and smooths the live-speed display
/// value.
class SpeedFusion {
  DateTime? _lastAcceptedTimestampUtc;
  double? _lastAcceptedLatitude;
  double? _lastAcceptedLongitude;
  final Queue<SpeedWindowSample> _speedWindow = Queue<SpeedWindowSample>();
  double _maxSpeedMps = 0;
  double? _smoothedLiveSpeedMps;
  DateTime? _lastLiveSpeedTimestampUtc;

  double get maxSpeedMps => _maxSpeedMps;
  DateTime? get lastAcceptedTimestampUtc => _lastAcceptedTimestampUtc;
  double? get lastAcceptedLatitude => _lastAcceptedLatitude;
  double? get lastAcceptedLongitude => _lastAcceptedLongitude;

  void reset() {
    _lastAcceptedTimestampUtc = null;
    _lastAcceptedLatitude = null;
    _lastAcceptedLongitude = null;
    _speedWindow.clear();
    _maxSpeedMps = 0;
    _smoothedLiveSpeedMps = null;
    _lastLiveSpeedTimestampUtc = null;
  }

  void seedFromPersistedPoints({
    required List<LocalSessionPoint> points,
    required SessionStats stats,
  }) {
    _maxSpeedMps = stats.maxSpeedMps;
    for (final LocalSessionPoint point in points) {
      if (!point.acceptedForAnalytics) {
        continue;
      }
      _lastAcceptedTimestampUtc = point.recordedAt.toUtc();
      _lastAcceptedLatitude = point.latitude;
      _lastAcceptedLongitude = point.longitude;
      _smoothedLiveSpeedMps =
          point.fusedSpeedMps ?? point.derivedSpeedMps ?? point.speedMps;
      _lastLiveSpeedTimestampUtc = point.recordedAt.toUtc();
    }
  }

  /// Derive speed from geometry (filtered coordinates).
  double deriveSpeed({
    required LocationSample sample,
    required double? filteredLatitude,
    required double? filteredLongitude,
    required double? lastFilteredLatitude,
    required double? lastFilteredLongitude,
  }) {
    if (_lastAcceptedTimestampUtc == null ||
        lastFilteredLatitude == null ||
        lastFilteredLongitude == null ||
        filteredLatitude == null ||
        filteredLongitude == null) {
      return 0;
    }

    final Duration deltaDuration =
        sample.timestamp.toUtc().difference(_lastAcceptedTimestampUtc!);
    if (deltaDuration.inMilliseconds <= 0) {
      return 0;
    }

    final double deltaSeconds = deltaDuration.inMilliseconds / 1000;
    final double distanceM = haversineDistanceMeters(
      lastFilteredLatitude,
      lastFilteredLongitude,
      filteredLatitude,
      filteredLongitude,
    );
    return (distanceM / deltaSeconds)
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
  }

  /// Fuse platform speed with geometry-derived speed.
  FusedSpeedResult fuseSpeed({
    required LocationSample sample,
    required double derivedSpeedMps,
    required MotionState motionState,
  }) {
    final double derivedSpeed = derivedSpeedMps
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
    final double? platformSpeedRaw = sample.speedMps;
    if (platformSpeedRaw == null) {
      return FusedSpeedResult(
        speedMps: derivedSpeed,
        platformTrust: PlatformSpeedTrust.untrusted,
      );
    }

    if (!platformSpeedRaw.isFinite ||
        platformSpeedRaw < 0 ||
        platformSpeedRaw > SessionConstants.speedHardCapMetersPerSecond) {
      return FusedSpeedResult(
        speedMps: derivedSpeed,
        platformTrust: PlatformSpeedTrust.untrusted,
      );
    }

    final double platformSpeed = platformSpeedRaw
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
    final PlatformSpeedTrust trust = _assessPlatformSpeedTrust(
      sample: sample,
      geometrySpeedMps: derivedSpeed,
      motionState: motionState,
    );

    if (derivedSpeed < SessionConstants.geometryCoherenceMinSpeedMps) {
      return FusedSpeedResult(
        speedMps: trust == PlatformSpeedTrust.untrusted
            ? derivedSpeed
            : platformSpeed,
        platformTrust: trust,
      );
    }

    final double fusedSpeed = switch (trust) {
      PlatformSpeedTrust.strong => platformSpeed,
      PlatformSpeedTrust.moderate => _blendSpeeds(
          platformSpeed: platformSpeed,
          geometrySpeed: derivedSpeed,
          platformWeight: SessionConstants.platformSpeedModerateBlendWeight,
        ),
      PlatformSpeedTrust.weak => _blendSpeeds(
          platformSpeed: platformSpeed,
          geometrySpeed: derivedSpeed,
          platformWeight: SessionConstants.platformSpeedWeakBlendWeight,
        ),
      PlatformSpeedTrust.untrusted => derivedSpeed,
    };
    return FusedSpeedResult(speedMps: fusedSpeed, platformTrust: trust);
  }

  /// Whether the speed value is reliable enough to update max speed.
  bool isSpeedTrustedForMax({
    required LocationSample sample,
    required PlatformSpeedTrust platformTrust,
    required double derivedSpeedMps,
    required MotionState motionState,
  }) {
    if (sample.speedMps != null) {
      return platformTrust == PlatformSpeedTrust.strong ||
          platformTrust == PlatformSpeedTrust.moderate;
    }
    return _isGeometrySpeedReliableForCoherence(
      sample: sample,
      geometrySpeedMps: derivedSpeedMps,
      motionState: motionState,
    );
  }

  /// Update the max-speed sliding window.
  void updateMaxSpeed({
    required DateTime sampleTime,
    required double speedMps,
    required QualityDecision quality,
    required bool speedTrustedForMax,
  }) {
    final bool highConfidence =
        quality.qualityClass == TrackingQualityClass.accept &&
            quality.score >= 0.65 &&
            speedTrustedForMax;
    if (!highConfidence) {
      return;
    }

    _speedWindow
        .add(SpeedWindowSample(time: sampleTime, speedMps: speedMps));

    while (_speedWindow.isNotEmpty &&
        sampleTime.difference(_speedWindow.first.time).inSeconds >
            SessionConstants.maxSpeedWindowSeconds) {
      _speedWindow.removeFirst();
    }

    if (_speedWindow.length < SessionConstants.maxSpeedPersistenceSamples) {
      return;
    }

    final List<double> speeds = _speedWindow
        .map((sample) => sample.speedMps)
        .toList(growable: false)
      ..sort();
    final int middle = speeds.length ~/ 2;
    final double median = speeds.length.isOdd
        ? speeds[middle]
        : (speeds[middle - 1] + speeds[middle]) / 2;
    if (median > _maxSpeedMps) {
      _maxSpeedMps = median;
    }
  }

  /// Smooth the live speed for UI display.
  double updateLiveSpeed({
    required double rawSpeedMps,
    required DateTime sampleTimeUtc,
    required bool acceptedForAnalytics,
    required MotionState motionState,
  }) {
    final double clampedRawSpeed = rawSpeedMps
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
    final double? previousSmoothed = _smoothedLiveSpeedMps;

    if (!acceptedForAnalytics) {
      if (_lastLiveSpeedTimestampUtc == null ||
          sampleTimeUtc.isAfter(_lastLiveSpeedTimestampUtc!)) {
        _lastLiveSpeedTimestampUtc = sampleTimeUtc;
      }
      return previousSmoothed ?? 0;
    }

    if (previousSmoothed == null) {
      _smoothedLiveSpeedMps = clampedRawSpeed;
      _lastLiveSpeedTimestampUtc = sampleTimeUtc;
      return clampedRawSpeed;
    }

    final DateTime? previousTime = _lastLiveSpeedTimestampUtc;
    if (previousTime == null) {
      _smoothedLiveSpeedMps = clampedRawSpeed;
      _lastLiveSpeedTimestampUtc = sampleTimeUtc;
      return clampedRawSpeed;
    }

    final int deltaMs = sampleTimeUtc.difference(previousTime).inMilliseconds;
    if (deltaMs <= 0) {
      return previousSmoothed;
    }

    _lastLiveSpeedTimestampUtc = sampleTimeUtc;
    final double deltaSeconds = deltaMs / 1000;
    final bool decelerating = clampedRawSpeed < previousSmoothed;
    final double tauSeconds = _liveSpeedTauSeconds(
      motionState: motionState,
      decelerating: decelerating,
    );
    final double alpha = 1 - math.exp(-deltaSeconds / tauSeconds);
    final double smoothed =
        previousSmoothed + (alpha * (clampedRawSpeed - previousSmoothed));
    _smoothedLiveSpeedMps = smoothed
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
    return _smoothedLiveSpeedMps!;
  }

  /// Commit the accepted position. Called by the coordinator when a sample
  /// is accepted.
  void commitAccepted({
    required DateTime timestampUtc,
    required double latitude,
    required double longitude,
  }) {
    _lastAcceptedTimestampUtc = timestampUtc;
    _lastAcceptedLatitude = latitude;
    _lastAcceptedLongitude = longitude;
  }

  /// Compute delta seconds from the last accepted timestamp.
  double deltaSecondsFromLastAccepted(LocationSample sample) {
    final DateTime? previousTimestamp = _lastAcceptedTimestampUtc;
    if (previousTimestamp == null) {
      return 0;
    }
    final int milliseconds =
        sample.timestamp.toUtc().difference(previousTimestamp).inMilliseconds;
    if (milliseconds <= 0) {
      return 0;
    }
    return milliseconds / 1000;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  PlatformSpeedTrust _assessPlatformSpeedTrust({
    required LocationSample sample,
    required double geometrySpeedMps,
    required MotionState motionState,
  }) {
    final double? platformSpeed = sample.speedMps;
    if (platformSpeed == null ||
        !platformSpeed.isFinite ||
        platformSpeed < 0 ||
        platformSpeed > SessionConstants.speedHardCapMetersPerSecond) {
      return PlatformSpeedTrust.untrusted;
    }

    final double horizontalAccuracyM = sample.accuracyM ??
        SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters;
    final bool horizontalStrong = horizontalAccuracyM <=
        _horizontalAcceptThresholdForSample(sample, motionState);
    final bool horizontalUsable = horizontalAccuracyM <=
        SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters;
    if (!horizontalUsable) {
      return PlatformSpeedTrust.untrusted;
    }

    final double? speedAccuracyMps = sample.speedAccuracyMps;
    final bool speedStrong = speedAccuracyMps != null &&
        speedAccuracyMps <= SessionConstants.platformSpeedStrongAccuracyMps;
    final bool speedUsable = speedAccuracyMps == null ||
        speedAccuracyMps <= SessionConstants.platformSpeedUsableAccuracyMps;
    if (!speedUsable) {
      return PlatformSpeedTrust.untrusted;
    }

    final bool geometryReliable = _isGeometrySpeedReliableForCoherence(
      sample: sample,
      geometrySpeedMps: geometrySpeedMps,
      motionState: motionState,
    );
    final double mismatchMps = (platformSpeed - geometrySpeedMps).abs();
    final double moderateMismatchToleranceMps = math.max(
      SessionConstants.platformSpeedModerateMismatchFloorMps,
      platformSpeed * SessionConstants.platformSpeedModerateMismatchRatio,
    );
    final double severeMismatchToleranceMps = math.max(
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
  }) {
    if (geometrySpeedMps < SessionConstants.geometryCoherenceMinSpeedMps) {
      return false;
    }

    final double deltaSeconds = deltaSecondsFromLastAccepted(sample);
    if (deltaSeconds < SessionConstants.geometryCoherenceMinDeltaSeconds ||
        deltaSeconds > SessionConstants.maxDeltaSeconds) {
      return false;
    }

    final double? horizontalAccuracyM = sample.accuracyM;
    if (horizontalAccuracyM == null) {
      return false;
    }
    return horizontalAccuracyM <=
        _horizontalAcceptThresholdForSample(sample, motionState);
  }

  double _blendSpeeds({
    required double platformSpeed,
    required double geometrySpeed,
    required double platformWeight,
  }) {
    return ((platformSpeed * platformWeight) +
            (geometrySpeed * (1 - platformWeight)))
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
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

  double _liveSpeedTauSeconds({
    required MotionState motionState,
    required bool decelerating,
  }) {
    switch (motionState) {
      case MotionState.initializingFix:
        return decelerating
            ? SessionConstants.liveSpeedTauInitializingFallSeconds
            : SessionConstants.liveSpeedTauInitializingRiseSeconds;
      case MotionState.activeDescent:
        return decelerating
            ? SessionConstants.liveSpeedTauActiveDescentFallSeconds
            : SessionConstants.liveSpeedTauActiveDescentRiseSeconds;
      case MotionState.liftUphill:
        return decelerating
            ? SessionConstants.liveSpeedTauLiftFallSeconds
            : SessionConstants.liveSpeedTauLiftRiseSeconds;
      case MotionState.stoppedIdle:
        return decelerating
            ? SessionConstants.liveSpeedTauStoppedFallSeconds
            : SessionConstants.liveSpeedTauStoppedRiseSeconds;
      case MotionState.lowConfidenceRecovery:
        return decelerating
            ? SessionConstants.liveSpeedTauRecoveryFallSeconds
            : SessionConstants.liveSpeedTauRecoveryRiseSeconds;
    }
  }
}
