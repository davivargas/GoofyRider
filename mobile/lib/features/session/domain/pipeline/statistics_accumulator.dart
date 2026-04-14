import 'dart:math' as math;

import '../../../../core/constants/session_constants.dart';
import '../session_models.dart';
import '../tracking_pipeline.dart';
import 'pipeline_types.dart';

/// Pipeline stage 6: accumulates distance, activity-type durations, and
/// activity-type distances, and builds the final [SessionStats].
class StatisticsAccumulator {
  double _distanceMeters = 0;
  int _descentDurationMs = 0;
  int _liftDurationMs = 0;
  int _idleDurationMs = 0;
  double _descentDistanceM = 0;
  double _liftDistanceM = 0;
  double _idleDistanceM = 0;

  double get distanceMeters => _distanceMeters;

  void reset() {
    _distanceMeters = 0;
    _descentDurationMs = 0;
    _liftDurationMs = 0;
    _idleDurationMs = 0;
    _descentDistanceM = 0;
    _liftDistanceM = 0;
    _idleDistanceM = 0;
  }

  void seedFromPersistedPoints({required SessionStats stats}) {
    _distanceMeters = stats.distanceM;
    _descentDurationMs = stats.descentDurationS * 1000;
    _liftDurationMs = stats.liftDurationS * 1000;
    _idleDurationMs = stats.idleDurationS * 1000;
    _descentDistanceM = stats.descentDistanceM;
    _liftDistanceM = stats.liftDistanceM;
    _idleDistanceM = stats.idleDistanceM;
  }

  /// Compute the distance delta for this sample.
  ///
  /// [lastFilteredLatitude] / [lastFilteredLongitude] are the previous
  /// committed filtered coordinates from the coordinate filter stage.
  /// [motionState] is the current motion state from the detector.
  double distanceDelta({
    required QualityDecision quality,
    required double? filteredLatitude,
    required double? filteredLongitude,
    required double? lastFilteredLatitude,
    required double? lastFilteredLongitude,
    required double speedMps,
    required double? accuracyM,
    required MotionState motionState,
  }) {
    if (quality.qualityClass == TrackingQualityClass.reject) {
      return 0;
    }
    if (lastFilteredLatitude == null ||
        lastFilteredLongitude == null ||
        filteredLatitude == null ||
        filteredLongitude == null) {
      return 0;
    }

    final segmentDistanceM = haversineDistanceMeters(
      lastFilteredLatitude,
      lastFilteredLongitude,
      filteredLatitude,
      filteredLongitude,
    );
    final double movementThreshold = math.max(
      SessionConstants.minimumDistanceDeltaMeters,
      (accuracyM ?? SessionConstants.qualityAcceptHorizontalAccuracyMeters) *
          SessionConstants.distanceNoiseRatio,
    );

    if (motionState == MotionState.stoppedIdle &&
        speedMps < SessionConstants.stoppedSpeedThresholdMetersPerSecond) {
      return 0;
    }

    if (segmentDistanceM < movementThreshold) {
      return 0;
    }

    return segmentDistanceM;
  }

  /// Add [distanceDeltaM] to the running total.
  void addDistance(double distanceDeltaM) {
    _distanceMeters += distanceDeltaM;
  }

  /// Accumulate duration and distance into the appropriate activity bucket.
  void accumulateActivityTotals({
    required bool acceptedForAnalytics,
    required double deltaSeconds,
    required double distanceDeltaM,
    required SessionActivityType activityType,
  }) {
    if (!acceptedForAnalytics ||
        deltaSeconds <= 0 ||
        deltaSeconds > SessionConstants.maxDeltaSeconds) {
      return;
    }

    final deltaMilliseconds = (deltaSeconds * 1000).round();

    switch (activityType) {
      case SessionActivityType.descent:
        _descentDurationMs += deltaMilliseconds;
        _descentDistanceM += distanceDeltaM;
        break;
      case SessionActivityType.lift:
        _liftDurationMs += deltaMilliseconds;
        _liftDistanceM += distanceDeltaM;
        break;
      case SessionActivityType.idle:
        _idleDurationMs += deltaMilliseconds;
        _idleDistanceM += distanceDeltaM;
        break;
    }
  }

  /// Build the final [SessionStats] snapshot.
  SessionStats buildStats({
    required int activeDurationS,
    required double maxSpeedMps,
    required int elevationGainMeters,
    required int elevationLossMeters,
  }) {
    return SessionStats(
      durationS: activeDurationS,
      distanceM: _distanceMeters,
      maxSpeedMps: maxSpeedMps,
      avgSpeedMps:
          activeDurationS == 0 ? 0 : _distanceMeters / activeDurationS,
      elevationGainM: elevationGainMeters == 0 ? null : elevationGainMeters,
      elevationLossM: elevationLossMeters == 0 ? null : elevationLossMeters,
      descentDurationS: _millisecondsToSeconds(_descentDurationMs),
      liftDurationS: _millisecondsToSeconds(_liftDurationMs),
      idleDurationS: _millisecondsToSeconds(_idleDurationMs),
      descentDistanceM: _descentDistanceM,
      liftDistanceM: _liftDistanceM,
      idleDistanceM: _idleDistanceM,
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  int _millisecondsToSeconds(int milliseconds) {
    return (milliseconds / 1000).round();
  }
}
