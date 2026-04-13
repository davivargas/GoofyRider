import 'dart:collection';
import 'dart:math' as math;

import '../../../../core/constants/session_constants.dart';
import '../location_tracking_repository.dart';
import '../session_models.dart';
import '../tracking_pipeline.dart';
import 'pipeline_types.dart';

/// Pipeline stage 4: detects the current motion state (descent, lift, idle,
/// etc.) using speed, vertical delta, and heading stability with hysteresis.
class MotionStateDetector {
  MotionState _motionState = MotionState.initializingFix;
  MotionState _lastStableMotionState = MotionState.stoppedIdle;
  MotionState? _pendingMotionState;
  double _pendingMotionSeconds = 0;
  final Queue<HeadingWindowSample> _headingWindow =
      Queue<HeadingWindowSample>();

  MotionState get motionState => _motionState;
  MotionState get lastStableMotionState => _lastStableMotionState;

  void reset() {
    _motionState = MotionState.initializingFix;
    _lastStableMotionState = MotionState.stoppedIdle;
    _pendingMotionState = null;
    _pendingMotionSeconds = 0;
    _headingWindow.clear();
  }

  void seedFromPersistedPoints({required List<LocalSessionPoint> points}) {
    for (final LocalSessionPoint point in points) {
      final MotionState? pointMotionState = point.motionState == null
          ? null
          : parseMotionState(point.motionState!);
      if (pointMotionState != null && isStableMotionState(pointMotionState)) {
        _lastStableMotionState = pointMotionState;
      }
    }

    if (points.isNotEmpty) {
      final LocalSessionPoint last = points.last;
      if (last.motionState != null) {
        _motionState = parseMotionState(last.motionState!);
      }
    }
  }

  /// Update the heading-stability sliding window and return the current
  /// heading stability value (0–1).
  double updateHeadingWindow({
    required LocationSample sample,
    required QualityDecision quality,
  }) {
    final DateTime sampleTime = sample.timestamp.toUtc();
    while (_headingWindow.isNotEmpty &&
        sampleTime.difference(_headingWindow.first.time).inSeconds >
            SessionConstants.liftPersistenceSeconds) {
      _headingWindow.removeFirst();
    }

    if (quality.qualityClass != TrackingQualityClass.reject &&
        _isHeadingReliable(sample)) {
      final double headingRad =
          (_normalizeHeading(sample.headingDeg!) * math.pi) / 180;
      _headingWindow.add(
        HeadingWindowSample(
          time: sampleTime,
          headingRad: headingRad,
        ),
      );
      while (
          _headingWindow.length > SessionConstants.liftHeadingWindowSamples) {
        _headingWindow.removeFirst();
      }
    }

    if (_headingWindow.length < SessionConstants.liftHeadingWindowSamples) {
      return 0;
    }

    double sumSin = 0;
    double sumCos = 0;
    for (final HeadingWindowSample sample in _headingWindow) {
      sumSin += math.sin(sample.headingRad);
      sumCos += math.cos(sample.headingRad);
    }

    return math.sqrt((sumSin * sumSin) + (sumCos * sumCos)) /
        _headingWindow.length;
  }

  /// Determine the candidate motion state and apply hysteresis to transition.
  void updateMotionState({
    required QualityDecision quality,
    required double speedMps,
    required double verticalDeltaM,
    required double headingStability,
    required double deltaSeconds,
    required int stableFixSamples,
  }) {
    final MotionState candidate = candidateMotionState(
      quality: quality,
      speedMps: speedMps,
      verticalDeltaM: verticalDeltaM,
      headingStability: headingStability,
      stableFixSamples: stableFixSamples,
    );
    if (candidate == _motionState) {
      _pendingMotionState = null;
      _pendingMotionSeconds = 0;
      return;
    }

    if (_pendingMotionState != candidate) {
      _pendingMotionState = candidate;
      _pendingMotionSeconds = 0;
    }
    _pendingMotionSeconds += math.max(0, deltaSeconds);

    final int requiredSeconds = _requiredPersistenceSeconds(candidate);
    if (_pendingMotionSeconds >= requiredSeconds) {
      _motionState = candidate;
      if (isStableMotionState(candidate)) {
        _lastStableMotionState = candidate;
      }
      _pendingMotionState = null;
      _pendingMotionSeconds = 0;
    }
  }

  /// Compute the candidate motion state from instantaneous signals.
  MotionState candidateMotionState({
    required QualityDecision quality,
    required double speedMps,
    required double verticalDeltaM,
    required double headingStability,
    required int stableFixSamples,
  }) {
    if (stableFixSamples < SessionConstants.initialFixStableSamples) {
      return MotionState.initializingFix;
    }

    if (quality.qualityClass == TrackingQualityClass.reject) {
      return MotionState.lowConfidenceRecovery;
    }

    if (speedMps < SessionConstants.stoppedSpeedThresholdMetersPerSecond) {
      return MotionState.stoppedIdle;
    }

    final bool inLiftSpeedBand =
        speedMps >= SessionConstants.liftMinSpeedThresholdMetersPerSecond &&
            speedMps <= SessionConstants.liftMaxSpeedThresholdMetersPerSecond;
    if (inLiftSpeedBand &&
        verticalDeltaM > 0.6 &&
        headingStability >= SessionConstants.liftHeadingStabilityThreshold) {
      return MotionState.liftUphill;
    }

    if (speedMps >= SessionConstants.descentSpeedThresholdMetersPerSecond &&
        verticalDeltaM < -0.6) {
      return MotionState.activeDescent;
    }

    if (_motionState == MotionState.liftUphill &&
        inLiftSpeedBand &&
        verticalDeltaM > -0.2) {
      return MotionState.liftUphill;
    }

    return _lastStableMotionState;
  }

  /// Whether [state] is a stable (non-transient) motion state.
  bool isStableMotionState(MotionState state) {
    return state == MotionState.activeDescent ||
        state == MotionState.liftUphill ||
        state == MotionState.stoppedIdle;
  }

  /// Map a motion state to its activity type, falling back to the last stable
  /// state for transient states.
  SessionActivityType activityTypeForMotionState(MotionState motionState) {
    switch (motionState) {
      case MotionState.activeDescent:
        return SessionActivityType.descent;
      case MotionState.liftUphill:
        return SessionActivityType.lift;
      case MotionState.stoppedIdle:
        return SessionActivityType.idle;
      case MotionState.initializingFix:
      case MotionState.lowConfidenceRecovery:
        return _activityTypeForStableMotionState(_lastStableMotionState);
    }
  }

  /// Parse a wire-format motion state string.
  MotionState parseMotionState(String wireValue) {
    return MotionState.values.firstWhere(
      (MotionState state) => state.wireValue == wireValue,
      orElse: () => MotionState.initializingFix,
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  int _requiredPersistenceSeconds(MotionState state) {
    switch (state) {
      case MotionState.initializingFix:
        return 1;
      case MotionState.activeDescent:
        return SessionConstants.descentPersistenceSeconds;
      case MotionState.liftUphill:
        return SessionConstants.liftPersistenceSeconds;
      case MotionState.stoppedIdle:
        return SessionConstants.stoppedPersistenceSeconds;
      case MotionState.lowConfidenceRecovery:
        return SessionConstants.recoveryPersistenceSeconds;
    }
  }

  SessionActivityType _activityTypeForStableMotionState(
      MotionState motionState) {
    switch (motionState) {
      case MotionState.activeDescent:
        return SessionActivityType.descent;
      case MotionState.liftUphill:
        return SessionActivityType.lift;
      case MotionState.stoppedIdle:
      case MotionState.initializingFix:
      case MotionState.lowConfidenceRecovery:
        return SessionActivityType.idle;
    }
  }

  bool _isHeadingReliable(LocationSample sample) {
    final double? heading = sample.headingDeg;
    if (heading == null || !heading.isFinite) {
      return false;
    }
    final double? bearingAccuracyDeg = sample.bearingAccuracyDeg;
    if (bearingAccuracyDeg != null &&
        bearingAccuracyDeg >
            SessionConstants.headingAccuracyStrongThresholdDeg) {
      return false;
    }
    return true;
  }

  double _normalizeHeading(double headingDeg) {
    final double normalized = headingDeg % 360;
    if (normalized < 0) {
      return normalized + 360;
    }
    return normalized;
  }
}
