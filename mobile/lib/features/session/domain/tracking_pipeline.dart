import 'location_tracking_repository.dart';
import 'pipeline/coordinate_filter.dart';
import 'pipeline/elevation_tracker.dart';
import 'pipeline/motion_state_detector.dart';
import 'pipeline/quality_classifier.dart';
import 'pipeline/speed_fusion.dart';
import 'pipeline/statistics_accumulator.dart';
import 'session_models.dart';

enum TrackingQualityClass {
  accept,
  acceptLowConfidence,
  reject,
}

extension TrackingQualityClassWire on TrackingQualityClass {
  String get wireValue {
    switch (this) {
      case TrackingQualityClass.accept:
        return 'accept';
      case TrackingQualityClass.acceptLowConfidence:
        return 'accept_low_confidence';
      case TrackingQualityClass.reject:
        return 'reject';
    }
  }
}

enum TrackingQualityReason {
  accepted,
  invalidCoordinate,
  nonMonotonicTimestamp,
  duplicateMonotonicTime,
  poorHorizontalAccuracy,
  unstableInitialFix,
  implausibleJump,
  implausibleSpeedSpike,
}

extension TrackingQualityReasonWire on TrackingQualityReason {
  String get wireValue {
    switch (this) {
      case TrackingQualityReason.accepted:
        return 'accepted';
      case TrackingQualityReason.invalidCoordinate:
        return 'invalid_coordinate';
      case TrackingQualityReason.nonMonotonicTimestamp:
        return 'non_monotonic_timestamp';
      case TrackingQualityReason.duplicateMonotonicTime:
        return 'duplicate_monotonic_time';
      case TrackingQualityReason.poorHorizontalAccuracy:
        return 'poor_horizontal_accuracy';
      case TrackingQualityReason.unstableInitialFix:
        return 'unstable_initial_fix';
      case TrackingQualityReason.implausibleJump:
        return 'implausible_jump';
      case TrackingQualityReason.implausibleSpeedSpike:
        return 'implausible_speed_spike';
    }
  }
}

enum MotionState {
  initializingFix,
  activeDescent,
  liftUphill,
  stoppedIdle,
  lowConfidenceRecovery,
}

extension MotionStateWire on MotionState {
  String get wireValue {
    switch (this) {
      case MotionState.initializingFix:
        return 'initializing_fix';
      case MotionState.activeDescent:
        return 'active_descent';
      case MotionState.liftUphill:
        return 'lift_uphill';
      case MotionState.stoppedIdle:
        return 'stopped_idle';
      case MotionState.lowConfidenceRecovery:
        return 'low_confidence_recovery';
    }
  }
}

class TrackingProcessResult {
  const TrackingProcessResult({
    required this.point,
    required this.stats,
    required this.liveSpeedMps,
    required this.currentAltitudeM,
    required this.lowAccuracy,
    required this.motionState,
    required this.trackingMode,
    required this.acceptedForReplay,
    required this.routeLatitude,
    required this.routeLongitude,
  });

  final NewSessionPoint point;
  final SessionStats stats;
  final double liveSpeedMps;
  final double? currentAltitudeM;
  final bool lowAccuracy;
  final MotionState motionState;
  final TrackingMode trackingMode;
  final bool acceptedForReplay;
  final double? routeLatitude;
  final double? routeLongitude;
}

/// Coordinates the six pipeline stages that process each [LocationSample]
/// into a [TrackingProcessResult].
///
/// The public API ([processSample], [reset], [seedFromPersistedPoints],
/// [motionState]) is unchanged from the original monolithic implementation.
class TrackingPipelineEngine {
  TrackingPipelineEngine();

  final QualityClassifier _qualityClassifier = QualityClassifier();
  final CoordinateFilter _coordinateFilter = CoordinateFilter();
  final SpeedFusion _speedFusion = SpeedFusion();
  final MotionStateDetector _motionStateDetector = MotionStateDetector();
  final ElevationTracker _elevationTracker = ElevationTracker();
  final StatisticsAccumulator _statisticsAccumulator = StatisticsAccumulator();

  MotionState get motionState => _motionStateDetector.motionState;

  void reset() {
    _qualityClassifier.reset();
    _coordinateFilter.reset();
    _speedFusion.reset();
    _motionStateDetector.reset();
    _elevationTracker.reset();
    _statisticsAccumulator.reset();
  }

  void seedFromPersistedPoints({
    required List<LocalSessionPoint> points,
    required SessionStats stats,
  }) {
    reset();

    _statisticsAccumulator.seedFromPersistedPoints(stats: stats);
    _elevationTracker.seedFromPersistedPoints(stats: stats);
    _speedFusion.seedFromPersistedPoints(points: points, stats: stats);

    if (points.isEmpty) {
      return;
    }

    _qualityClassifier.seedFromPersistedPoints(points: points);
    _coordinateFilter.seedFromPersistedPoints(points: points);
    _motionStateDetector.seedFromPersistedPoints(points: points);
  }

  TrackingProcessResult processSample({
    required LocationSample sample,
    required DateTime sessionStartedAtUtc,
    required int activeDurationS,
  }) {
    // Stage 1: Quality classification
    final quality = _qualityClassifier.classify(
      sample: sample,
      lastAcceptedLatitude: _speedFusion.lastAcceptedLatitude,
      lastAcceptedLongitude: _speedFusion.lastAcceptedLongitude,
      lastAcceptedTimestampUtc: _speedFusion.lastAcceptedTimestampUtc,
      motionState: _motionStateDetector.motionState,
    );

    // Stage 2: Coordinate filtering
    final filtered =
        _coordinateFilter.filter(
      latitude: sample.latitude,
      longitude: sample.longitude,
      accuracyM: sample.accuracyM,
    );
    final filteredLatitude = filtered.latitude;
    final filteredLongitude = filtered.longitude;

    // Stage 3: Speed derivation and fusion
    final derivedSpeedMps = _speedFusion.deriveSpeed(
      sample: sample,
      filteredLatitude: filteredLatitude,
      filteredLongitude: filteredLongitude,
      lastFilteredLatitude: _coordinateFilter.lastFilteredLatitude,
      lastFilteredLongitude: _coordinateFilter.lastFilteredLongitude,
    );
    final fusedSpeed = _speedFusion.fuseSpeed(
      sample: sample,
      derivedSpeedMps: derivedSpeedMps,
      motionState: _motionStateDetector.motionState,
    );
    final fusedSpeedMps = fusedSpeed.speedMps;

    final acceptedForAnalytics =
        quality.qualityClass != TrackingQualityClass.reject;
    final acceptedForReplay = acceptedForAnalytics;

    // Stage 6 (partial): Distance delta
    final distanceDeltaM = _statisticsAccumulator.distanceDelta(
      quality: quality,
      filteredLatitude: filteredLatitude,
      filteredLongitude: filteredLongitude,
      lastFilteredLatitude: _coordinateFilter.lastFilteredLatitude,
      lastFilteredLongitude: _coordinateFilter.lastFilteredLongitude,
      speedMps: fusedSpeedMps,
      accuracyM: sample.accuracyM,
      motionState: _motionStateDetector.motionState,
    );
    _statisticsAccumulator.addDistance(distanceDeltaM);

    // Stage 5: Elevation tracking
    final vertical = _elevationTracker.updateVertical(
      sample: sample,
      quality: quality,
      lastFilteredAltitude: _coordinateFilter.lastFilteredAltitude,
    );

    // Stage 4: Motion state detection
    final headingStability = _motionStateDetector.updateHeadingWindow(
      sample: sample,
      quality: quality,
    );
    final deltaSeconds =
        _speedFusion.deltaSecondsFromLastAccepted(sample);
    final smoothingMotionState = _motionStateDetector.motionState;
    _motionStateDetector.updateMotionState(
      quality: quality,
      speedMps: fusedSpeedMps,
      verticalDeltaM: vertical.deltaM,
      headingStability: headingStability,
      deltaSeconds: deltaSeconds,
      stableFixSamples: _stableFixSamplesFromClassifier,
    );

    // Stage 6 (continued): Accumulate activity totals
    _statisticsAccumulator.accumulateActivityTotals(
      acceptedForAnalytics: acceptedForAnalytics,
      deltaSeconds: deltaSeconds,
      distanceDeltaM: distanceDeltaM,
      activityType: _motionStateDetector.activityTypeForMotionState(
        _motionStateDetector.motionState,
      ),
    );

    // Stage 3 (continued): Max speed
    _speedFusion.updateMaxSpeed(
      sampleTime: sample.timestamp.toUtc(),
      speedMps: fusedSpeedMps,
      quality: quality,
      speedTrustedForMax: _speedFusion.isSpeedTrustedForMax(
        sample: sample,
        platformTrust: fusedSpeed.platformTrust,
        derivedSpeedMps: derivedSpeedMps,
        motionState: _motionStateDetector.motionState,
      ),
    );

    // Commit accepted state across stages
    if (acceptedForAnalytics) {
      _speedFusion.commitAccepted(
        timestampUtc: sample.timestamp.toUtc(),
        latitude: sample.latitude,
        longitude: sample.longitude,
      );
      _coordinateFilter.commitFiltered(
        latitude: filteredLatitude,
        longitude: filteredLongitude,
      );
      _qualityClassifier.recordAccepted(quality.qualityClass);
    }

    // Commit filtered altitude (accepted samples update the filter baseline)
    if (acceptedForAnalytics) {
      _coordinateFilter.commitFilteredAltitude(vertical.filteredAltitudeM);
    }

    // Stage 3 (continued): Live speed smoothing
    final liveSpeed = _speedFusion.updateLiveSpeed(
      rawSpeedMps: fusedSpeedMps,
      sampleTimeUtc: sample.timestamp.toUtc(),
      acceptedForAnalytics: acceptedForAnalytics,
      motionState: smoothingMotionState,
    );

    // Stage 6 (continued): Build stats
    final stats = _statisticsAccumulator.buildStats(
      activeDurationS: activeDurationS,
      maxSpeedMps: _speedFusion.maxSpeedMps,
      elevationGainMeters: _elevationTracker.elevationGainMeters,
      elevationLossMeters: _elevationTracker.elevationLossMeters,
    );

    // Build the output point
    final point = NewSessionPoint(
      recordedAt: sample.timestamp.toUtc(),
      tOffsetMs: sample.timestamp
          .toUtc()
          .difference(sessionStartedAtUtc.toUtc())
          .inMilliseconds,
      latitude: sample.latitude,
      longitude: sample.longitude,
      accuracyM: sample.accuracyM,
      altitudeM: sample.altitudeM,
      speedMps: sample.speedMps,
      headingDeg: sample.headingDeg,
      acceptedForAnalytics: acceptedForAnalytics,
      elapsedRealtimeNs: sample.elapsedRealtimeNs,
      verticalAccuracyM: sample.verticalAccuracyM,
      speedAccuracyMps: sample.speedAccuracyMps,
      bearingAccuracyDeg: sample.bearingAccuracyDeg,
      provider: sample.provider,
      isMocked: sample.isMocked,
      qualityClass: quality.qualityClass.wireValue,
      qualityScore: quality.score,
      qualityReason: quality.reason.wireValue,
      filteredLatitude: filteredLatitude,
      filteredLongitude: filteredLongitude,
      filteredAltitudeM: vertical.filteredAltitudeM,
      fusedSpeedMps: fusedSpeedMps,
      derivedSpeedMps: derivedSpeedMps,
      distanceDeltaM: distanceDeltaM,
      motionState: _motionStateDetector.motionState.wireValue,
    );

    return TrackingProcessResult(
      point: point,
      stats: stats,
      liveSpeedMps: liveSpeed,
      currentAltitudeM: vertical.filteredAltitudeM ?? sample.altitudeM,
      lowAccuracy:
          quality.qualityClass == TrackingQualityClass.acceptLowConfidence,
      motionState: _motionStateDetector.motionState,
      trackingMode: _toTrackingMode(_motionStateDetector.motionState),
      acceptedForReplay: acceptedForReplay,
      routeLatitude: acceptedForReplay ? filteredLatitude : null,
      routeLongitude: acceptedForReplay ? filteredLongitude : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  int get _stableFixSamplesFromClassifier =>
      _qualityClassifier.stableFixSamples;

  TrackingMode _toTrackingMode(MotionState motionState) {
    switch (motionState) {
      case MotionState.initializingFix:
        return TrackingMode.initializingFix;
      case MotionState.activeDescent:
        return TrackingMode.activeDescent;
      case MotionState.liftUphill:
        return TrackingMode.liftUphill;
      case MotionState.stoppedIdle:
        return TrackingMode.stoppedIdle;
      case MotionState.lowConfidenceRecovery:
        return TrackingMode.lowConfidenceRecovery;
    }
  }
}
