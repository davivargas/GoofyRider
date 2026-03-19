import 'dart:collection';
import 'dart:math' as math;

import '../../../core/constants/session_constants.dart';
import 'location_tracking_repository.dart';
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
  final bool lowAccuracy;
  final MotionState motionState;
  final TrackingMode trackingMode;
  final bool acceptedForReplay;
  final double? routeLatitude;
  final double? routeLongitude;
}

class TrackingPipelineEngine {
  TrackingPipelineEngine();

  DateTime? _lastObservedTimestampUtc;
  int? _lastObservedElapsedRealtimeNs;
  DateTime? _lastAcceptedTimestampUtc;
  double? _lastAcceptedLatitude;
  double? _lastAcceptedLongitude;
  double? _lastFilteredLatitude;
  double? _lastFilteredLongitude;
  double? _lastFilteredAltitude;
  double _distanceMeters = 0;
  double _maxSpeedMps = 0;
  int _elevationGainMeters = 0;
  int _elevationLossMeters = 0;
  double? _smoothedLiveSpeedMps;
  int _stableFixSamples = 0;
  MotionState _motionState = MotionState.initializingFix;
  MotionState? _pendingMotionState;
  double _pendingMotionSeconds = 0;
  final Queue<_SpeedWindowSample> _speedWindow = Queue<_SpeedWindowSample>();
  final Queue<_HeadingWindowSample> _headingWindow =
      Queue<_HeadingWindowSample>();

  MotionState get motionState => _motionState;

  void reset() {
    _lastObservedTimestampUtc = null;
    _lastObservedElapsedRealtimeNs = null;
    _lastAcceptedTimestampUtc = null;
    _lastAcceptedLatitude = null;
    _lastAcceptedLongitude = null;
    _lastFilteredLatitude = null;
    _lastFilteredLongitude = null;
    _lastFilteredAltitude = null;
    _distanceMeters = 0;
    _maxSpeedMps = 0;
    _elevationGainMeters = 0;
    _elevationLossMeters = 0;
    _smoothedLiveSpeedMps = null;
    _stableFixSamples = 0;
    _motionState = MotionState.initializingFix;
    _pendingMotionState = null;
    _pendingMotionSeconds = 0;
    _speedWindow.clear();
    _headingWindow.clear();
  }

  void seedFromPersistedPoints({
    required List<LocalSessionPoint> points,
    required SessionStats stats,
  }) {
    reset();
    _distanceMeters = stats.distanceM;
    _maxSpeedMps = stats.maxSpeedMps;
    _elevationGainMeters = stats.elevationGainM ?? 0;
    _elevationLossMeters = stats.elevationLossM ?? 0;

    if (points.isEmpty) {
      return;
    }

    for (final LocalSessionPoint point in points) {
      _lastObservedTimestampUtc = point.recordedAt.toUtc();
      _lastObservedElapsedRealtimeNs = point.elapsedRealtimeNs;
      if (!point.acceptedForAnalytics) {
        continue;
      }

      _lastAcceptedTimestampUtc = point.recordedAt.toUtc();
      _lastAcceptedLatitude = point.latitude;
      _lastAcceptedLongitude = point.longitude;
      _lastFilteredLatitude = point.filteredLatitude ?? point.latitude;
      _lastFilteredLongitude = point.filteredLongitude ?? point.longitude;
      _lastFilteredAltitude = point.filteredAltitudeM ?? point.altitudeM;
      _smoothedLiveSpeedMps =
          point.fusedSpeedMps ?? point.derivedSpeedMps ?? point.speedMps;
      if (_stableFixSamples < SessionConstants.initialFixStableSamples) {
        _stableFixSamples += 1;
      }
    }

    final LocalSessionPoint? last = points.isEmpty ? null : points.last;
    if (last?.motionState != null) {
      _motionState = _parseMotionState(last!.motionState!);
    }
  }

  TrackingProcessResult processSample({
    required LocationSample sample,
    required DateTime sessionStartedAtUtc,
    required int activeDurationS,
  }) {
    final _QualityDecision quality = _classify(sample);
    final double filteredLatitude = _nextFilteredCoordinate(
      previous: _lastFilteredLatitude,
      current: sample.latitude,
      accuracyM: sample.accuracyM,
    );
    final double filteredLongitude = _nextFilteredCoordinate(
      previous: _lastFilteredLongitude,
      current: sample.longitude,
      accuracyM: sample.accuracyM,
    );

    final double derivedSpeedMps = _deriveSpeed(
      sample: sample,
      filteredLatitude: filteredLatitude,
      filteredLongitude: filteredLongitude,
    );
    final double fusedSpeedMps =
        _fusedSpeed(sample: sample, derivedSpeedMps: derivedSpeedMps);
    final double distanceDeltaM = _distanceDelta(
      quality: quality,
      filteredLatitude: filteredLatitude,
      filteredLongitude: filteredLongitude,
      speedMps: fusedSpeedMps,
      accuracyM: sample.accuracyM,
    );
    _distanceMeters += distanceDeltaM;

    final _VerticalResult vertical = _updateVertical(
      sample: sample,
      quality: quality,
    );
    final double headingStability = _updateHeadingWindow(
      sample: sample,
      quality: quality,
    );
    final double deltaSeconds = _deltaSecondsFromLastAccepted(sample);
    _updateMotionState(
      quality: quality,
      speedMps: fusedSpeedMps,
      verticalDeltaM: vertical.deltaM,
      headingStability: headingStability,
      deltaSeconds: deltaSeconds,
    );

    _updateMaxSpeed(
      sampleTime: sample.timestamp.toUtc(),
      speedMps: fusedSpeedMps,
      quality: quality,
    );

    final bool acceptedForAnalytics =
        quality.qualityClass != TrackingQualityClass.reject;
    final bool acceptedForReplay =
        quality.qualityClass != TrackingQualityClass.reject;

    if (acceptedForAnalytics) {
      _lastAcceptedTimestampUtc = sample.timestamp.toUtc();
      _lastAcceptedLatitude = sample.latitude;
      _lastAcceptedLongitude = sample.longitude;
      _lastFilteredLatitude = filteredLatitude;
      _lastFilteredLongitude = filteredLongitude;
      if (_stableFixSamples < SessionConstants.initialFixStableSamples &&
          quality.qualityClass == TrackingQualityClass.accept) {
        _stableFixSamples += 1;
      }
    }

    _lastObservedTimestampUtc = sample.timestamp.toUtc();
    _lastObservedElapsedRealtimeNs = sample.elapsedRealtimeNs;

    final double liveSpeed = _smoothLiveSpeed(fusedSpeedMps);
    final SessionStats stats = SessionStats(
      durationS: activeDurationS,
      distanceM: _distanceMeters,
      maxSpeedMps: _maxSpeedMps,
      avgSpeedMps: activeDurationS == 0 ? 0 : _distanceMeters / activeDurationS,
      elevationGainM: _elevationGainMeters == 0 ? null : _elevationGainMeters,
      elevationLossM: _elevationLossMeters == 0 ? null : _elevationLossMeters,
    );

    final NewSessionPoint point = NewSessionPoint(
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
      motionState: _motionState.wireValue,
    );

    return TrackingProcessResult(
      point: point,
      stats: stats,
      liveSpeedMps: liveSpeed,
      lowAccuracy:
          quality.qualityClass == TrackingQualityClass.acceptLowConfidence,
      motionState: _motionState,
      trackingMode: _toTrackingMode(_motionState),
      acceptedForReplay: acceptedForReplay,
      routeLatitude: acceptedForReplay ? filteredLatitude : null,
      routeLongitude: acceptedForReplay ? filteredLongitude : null,
    );
  }

  _QualityDecision _classify(LocationSample sample) {
    if (!_isValidCoordinate(sample.latitude, sample.longitude)) {
      return const _QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.invalidCoordinate,
        score: 0,
      );
    }

    if (!_isTimestampMonotonic(sample)) {
      return const _QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.nonMonotonicTimestamp,
        score: 0,
      );
    }

    if (!_isMonotonicClockUnique(sample)) {
      return const _QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.duplicateMonotonicTime,
        score: 0,
      );
    }

    if (_isImplausibleJump(sample)) {
      return const _QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.implausibleJump,
        score: 0,
      );
    }

    if (_isImplausibleSpeedSpike(sample)) {
      return const _QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.implausibleSpeedSpike,
        score: 0,
      );
    }

    final double score = _qualityScore(
      horizontalAccuracyM: sample.accuracyM,
      speedAccuracyMps: sample.speedAccuracyMps,
      verticalAccuracyM: sample.verticalAccuracyM,
    );
    final double acceptHorizontalAccuracyM =
        _horizontalAcceptThresholdForSample(sample);

    final double? horizontalAccuracyM = sample.accuracyM;
    if (horizontalAccuracyM != null &&
        horizontalAccuracyM >
            SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters) {
      return _QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.poorHorizontalAccuracy,
        score: score,
      );
    }

    if (_stableFixSamples < SessionConstants.initialFixStableSamples &&
        (horizontalAccuracyM == null ||
            horizontalAccuracyM > acceptHorizontalAccuracyM)) {
      return _QualityDecision(
        qualityClass: TrackingQualityClass.reject,
        reason: TrackingQualityReason.unstableInitialFix,
        score: score,
      );
    }

    if (horizontalAccuracyM != null &&
        horizontalAccuracyM > acceptHorizontalAccuracyM) {
      return _QualityDecision(
        qualityClass: TrackingQualityClass.acceptLowConfidence,
        reason: TrackingQualityReason.poorHorizontalAccuracy,
        score: score,
      );
    }

    return _QualityDecision(
      qualityClass: TrackingQualityClass.accept,
      reason: TrackingQualityReason.accepted,
      score: score,
    );
  }

  double _horizontalAcceptThresholdForSample(LocationSample sample) {
    if (_motionState == MotionState.activeDescent) {
      return SessionConstants.activeDescentAcceptHorizontalAccuracyMeters;
    }
    if ((sample.speedMps ?? 0) >=
        SessionConstants.descentSpeedThresholdMetersPerSecond) {
      return SessionConstants.activeDescentAcceptHorizontalAccuracyMeters;
    }
    return SessionConstants.qualityAcceptHorizontalAccuracyMeters;
  }

  bool _isTimestampMonotonic(LocationSample sample) {
    final DateTime? previousTimestamp = _lastObservedTimestampUtc;
    if (previousTimestamp == null) {
      return true;
    }
    return sample.timestamp.toUtc().isAfter(previousTimestamp);
  }

  bool _isMonotonicClockUnique(LocationSample sample) {
    if (sample.elapsedRealtimeNs == null) {
      return true;
    }
    final int? previousElapsedRealtimeNs = _lastObservedElapsedRealtimeNs;
    if (previousElapsedRealtimeNs == null) {
      return true;
    }
    return sample.elapsedRealtimeNs! > previousElapsedRealtimeNs;
  }

  bool _isImplausibleJump(LocationSample sample) {
    if (_lastAcceptedLatitude == null || _lastAcceptedLongitude == null) {
      return false;
    }
    final double deltaSeconds = _deltaSecondsFromLastAccepted(sample);
    if (deltaSeconds <= 0) {
      return false;
    }

    final double distance = haversineDistanceMeters(
      _lastAcceptedLatitude!,
      _lastAcceptedLongitude!,
      sample.latitude,
      sample.longitude,
    );
    final double speedFromGeometry = distance / deltaSeconds;
    if (speedFromGeometry <= SessionConstants.speedHardCapMetersPerSecond) {
      return false;
    }

    if (_isPlatformSpeedTrusted(sample, speedFromGeometry)) {
      return false;
    }

    return speedFromGeometry >
        SessionConstants.speedHardCapMetersPerSecond * 1.4;
  }

  bool _isImplausibleSpeedSpike(LocationSample sample) {
    if (_lastAcceptedLatitude == null || _lastAcceptedLongitude == null) {
      return false;
    }

    final double deltaSeconds = _deltaSecondsFromLastAccepted(sample);
    if (deltaSeconds <= 0) {
      return false;
    }

    final double distance = haversineDistanceMeters(
      _lastAcceptedLatitude!,
      _lastAcceptedLongitude!,
      sample.latitude,
      sample.longitude,
    );
    final double speedFromGeometry = distance / deltaSeconds;
    if (speedFromGeometry <= SessionConstants.speedHardCapMetersPerSecond) {
      return false;
    }

    return !_isPlatformSpeedTrusted(sample, speedFromGeometry);
  }

  double _deriveSpeed({
    required LocationSample sample,
    required double? filteredLatitude,
    required double? filteredLongitude,
  }) {
    if (_lastAcceptedTimestampUtc == null ||
        _lastFilteredLatitude == null ||
        _lastFilteredLongitude == null ||
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
      _lastFilteredLatitude!,
      _lastFilteredLongitude!,
      filteredLatitude,
      filteredLongitude,
    );
    return (distanceM / deltaSeconds)
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
  }

  double _fusedSpeed({
    required LocationSample sample,
    required double derivedSpeedMps,
  }) {
    final double? platformSpeed = sample.speedMps;
    if (platformSpeed == null) {
      return derivedSpeedMps;
    }

    if (_isPlatformSpeedTrusted(sample, derivedSpeedMps)) {
      return platformSpeed
          .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
          .toDouble();
    }

    final double blended = (platformSpeed * 0.35) + (derivedSpeedMps * 0.65);
    return blended
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
  }

  bool _isPlatformSpeedTrusted(LocationSample sample, double geometrySpeedMps) {
    final double platformSpeed = sample.speedMps ?? geometrySpeedMps;
    if (platformSpeed > SessionConstants.speedHardCapMetersPerSecond) {
      return false;
    }

    final double horizontalAccuracy = sample.accuracyM ?? 60;
    final double requiredHorizontalAccuracyM =
        _motionState == MotionState.activeDescent
            ? SessionConstants.activeDescentAcceptHorizontalAccuracyMeters
            : SessionConstants.qualityAcceptHorizontalAccuracyMeters;
    final bool horizontalReliable =
        horizontalAccuracy <= requiredHorizontalAccuracyM;
    final double speedAccuracy = sample.speedAccuracyMps ?? 2.5;
    final bool speedReliable = speedAccuracy <= 1.8;
    final double mismatch = (platformSpeed - geometrySpeedMps).abs();
    final bool geometryCoherent = mismatch <= math.max(3, platformSpeed * 0.6);
    return horizontalReliable && speedReliable && geometryCoherent;
  }

  double _distanceDelta({
    required _QualityDecision quality,
    required double? filteredLatitude,
    required double? filteredLongitude,
    required double speedMps,
    required double? accuracyM,
  }) {
    if (quality.qualityClass == TrackingQualityClass.reject) {
      return 0;
    }
    if (_lastFilteredLatitude == null ||
        _lastFilteredLongitude == null ||
        filteredLatitude == null ||
        filteredLongitude == null) {
      return 0;
    }

    final double segmentDistanceM = haversineDistanceMeters(
      _lastFilteredLatitude!,
      _lastFilteredLongitude!,
      filteredLatitude,
      filteredLongitude,
    );
    final double movementThreshold = math.max(
      SessionConstants.minimumDistanceDeltaMeters,
      (accuracyM ?? SessionConstants.qualityAcceptHorizontalAccuracyMeters) *
          SessionConstants.distanceNoiseRatio,
    );

    if (_motionState == MotionState.stoppedIdle &&
        speedMps < SessionConstants.stoppedSpeedThresholdMetersPerSecond) {
      return 0;
    }

    if (segmentDistanceM < movementThreshold) {
      return 0;
    }

    return segmentDistanceM;
  }

  _VerticalResult _updateVertical({
    required LocationSample sample,
    required _QualityDecision quality,
  }) {
    if (sample.altitudeM == null) {
      return _VerticalResult(
        filteredAltitudeM: _lastFilteredAltitude,
        deltaM: 0,
      );
    }

    final double alpha = _verticalAlpha(sample.verticalAccuracyM);
    final double filteredAltitude = _lastFilteredAltitude == null
        ? sample.altitudeM!
        : _lastFilteredAltitude! +
            (alpha * (sample.altitudeM! - _lastFilteredAltitude!));

    final double delta = _lastFilteredAltitude == null
        ? 0
        : filteredAltitude - _lastFilteredAltitude!;
    _lastFilteredAltitude = filteredAltitude;

    final bool canAccumulate =
        quality.qualityClass != TrackingQualityClass.reject &&
            _isVerticalReliable(sample.verticalAccuracyM);
    if (!canAccumulate) {
      return _VerticalResult(
          filteredAltitudeM: filteredAltitude, deltaM: delta);
    }

    final double hysteresisThreshold = math.max(
      SessionConstants.verticalHysteresisFloorMeters,
      (sample.verticalAccuracyM ??
              SessionConstants.verticalAccuracyWeakThresholdMeters) *
          SessionConstants.verticalHysteresisAccuracyFactor,
    );

    if (delta.abs() >= hysteresisThreshold) {
      if (delta > 0) {
        _elevationGainMeters += delta.round();
      } else {
        _elevationLossMeters += delta.abs().round();
      }
    }

    return _VerticalResult(filteredAltitudeM: filteredAltitude, deltaM: delta);
  }

  bool _isVerticalReliable(double? verticalAccuracyM) {
    if (verticalAccuracyM == null) {
      return false;
    }
    return verticalAccuracyM <=
        SessionConstants.verticalAccuracyWeakThresholdMeters;
  }

  double _verticalAlpha(double? verticalAccuracyM) {
    if (verticalAccuracyM == null) {
      return SessionConstants.verticalSmoothingAlphaWeak;
    }
    if (verticalAccuracyM <=
        SessionConstants.verticalAccuracyStrongThresholdMeters) {
      return SessionConstants.verticalSmoothingAlphaStrong;
    }
    return SessionConstants.verticalSmoothingAlphaWeak;
  }

  void _updateMotionState({
    required _QualityDecision quality,
    required double speedMps,
    required double verticalDeltaM,
    required double headingStability,
    required double deltaSeconds,
  }) {
    final MotionState candidate = _candidateMotionState(
      quality: quality,
      speedMps: speedMps,
      verticalDeltaM: verticalDeltaM,
      headingStability: headingStability,
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
      _pendingMotionState = null;
      _pendingMotionSeconds = 0;
    }
  }

  MotionState _candidateMotionState({
    required _QualityDecision quality,
    required double speedMps,
    required double verticalDeltaM,
    required double headingStability,
  }) {
    if (_stableFixSamples < SessionConstants.initialFixStableSamples) {
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

    return MotionState.activeDescent;
  }

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

  void _updateMaxSpeed({
    required DateTime sampleTime,
    required double speedMps,
    required _QualityDecision quality,
  }) {
    final bool highConfidence =
        quality.qualityClass == TrackingQualityClass.accept &&
            quality.score >= 0.65;
    if (!highConfidence) {
      return;
    }

    _speedWindow.add(_SpeedWindowSample(time: sampleTime, speedMps: speedMps));

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

  double _smoothLiveSpeed(double speedMps) {
    final double previous = _smoothedLiveSpeedMps ?? speedMps;
    final double smoothed = previous + (0.35 * (speedMps - previous));
    _smoothedLiveSpeedMps = smoothed;
    return smoothed;
  }

  double _updateHeadingWindow({
    required LocationSample sample,
    required _QualityDecision quality,
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
        _HeadingWindowSample(
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
    for (final _HeadingWindowSample sample in _headingWindow) {
      sumSin += math.sin(sample.headingRad);
      sumCos += math.cos(sample.headingRad);
    }

    return math.sqrt((sumSin * sumSin) + (sumCos * sumCos)) /
        _headingWindow.length;
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

  double _qualityScore({
    required double? horizontalAccuracyM,
    required double? speedAccuracyMps,
    required double? verticalAccuracyM,
  }) {
    final double horizontalComponent = horizontalAccuracyM == null
        ? 0.6
        : (1 -
                (horizontalAccuracyM /
                    SessionConstants
                        .qualityLowConfidenceHorizontalAccuracyMeters))
            .clamp(0, 1)
            .toDouble();
    final double speedComponent = speedAccuracyMps == null
        ? 0.5
        : (1 - (speedAccuracyMps / 4)).clamp(0, 1).toDouble();
    final double verticalComponent = verticalAccuracyM == null
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

  double _deltaSecondsFromLastAccepted(LocationSample sample) {
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

  double _nextFilteredCoordinate({
    required double? previous,
    required double current,
    required double? accuracyM,
  }) {
    if (previous == null) {
      return current;
    }

    final double alpha = _horizontalAlpha(accuracyM);
    return previous + (alpha * (current - previous));
  }

  double _horizontalAlpha(double? accuracyM) {
    if (accuracyM == null) {
      return 0.35;
    }

    final double ratio = accuracyM /
        SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters;
    return (0.8 - (ratio * 0.5)).clamp(0.2, 0.75).toDouble();
  }

  bool _isValidCoordinate(double latitude, double longitude) {
    return latitude >= -90 &&
        latitude <= 90 &&
        longitude >= -180 &&
        longitude <= 180;
  }

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

  MotionState _parseMotionState(String wireValue) {
    return MotionState.values.firstWhere(
      (MotionState state) => state.wireValue == wireValue,
      orElse: () => MotionState.initializingFix,
    );
  }
}

class _QualityDecision {
  const _QualityDecision({
    required this.qualityClass,
    required this.reason,
    required this.score,
  });

  final TrackingQualityClass qualityClass;
  final TrackingQualityReason reason;
  final double score;
}

class _SpeedWindowSample {
  const _SpeedWindowSample({
    required this.time,
    required this.speedMps,
  });

  final DateTime time;
  final double speedMps;
}

class _VerticalResult {
  const _VerticalResult({
    required this.filteredAltitudeM,
    required this.deltaM,
  });

  final double? filteredAltitudeM;
  final double deltaM;
}

class _HeadingWindowSample {
  const _HeadingWindowSample({
    required this.time,
    required this.headingRad,
  });

  final DateTime time;
  final double headingRad;
}
