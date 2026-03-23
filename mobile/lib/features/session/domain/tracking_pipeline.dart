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
  int _descentDurationMilliseconds = 0;
  int _liftDurationMilliseconds = 0;
  int _idleDurationMilliseconds = 0;
  double _descentDistanceMeters = 0;
  double _liftDistanceMeters = 0;
  double _idleDistanceMeters = 0;
  double? _smoothedLiveSpeedMps;
  DateTime? _lastLiveSpeedTimestampUtc;
  int _stableFixSamples = 0;
  MotionState _motionState = MotionState.initializingFix;
  MotionState _lastStableMotionState = MotionState.stoppedIdle;
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
    _descentDurationMilliseconds = 0;
    _liftDurationMilliseconds = 0;
    _idleDurationMilliseconds = 0;
    _descentDistanceMeters = 0;
    _liftDistanceMeters = 0;
    _idleDistanceMeters = 0;
    _smoothedLiveSpeedMps = null;
    _lastLiveSpeedTimestampUtc = null;
    _stableFixSamples = 0;
    _motionState = MotionState.initializingFix;
    _lastStableMotionState = MotionState.stoppedIdle;
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
    _descentDurationMilliseconds = stats.descentDurationS * 1000;
    _liftDurationMilliseconds = stats.liftDurationS * 1000;
    _idleDurationMilliseconds = stats.idleDurationS * 1000;
    _descentDistanceMeters = stats.descentDistanceM;
    _liftDistanceMeters = stats.liftDistanceM;
    _idleDistanceMeters = stats.idleDistanceM;

    if (points.isEmpty) {
      return;
    }

    for (final LocalSessionPoint point in points) {
      _lastObservedTimestampUtc = point.recordedAt.toUtc();
      _lastObservedElapsedRealtimeNs = point.elapsedRealtimeNs;
      final MotionState? pointMotionState = point.motionState == null
          ? null
          : _parseMotionState(point.motionState!);
      if (pointMotionState != null && _isStableMotionState(pointMotionState)) {
        _lastStableMotionState = pointMotionState;
      }
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
      _lastLiveSpeedTimestampUtc = point.recordedAt.toUtc();
      if (_stableFixSamples < SessionConstants.initialFixStableSamples) {
        _stableFixSamples += 1;
      }
    }

    final LocalSessionPoint last = points.last;
    if (last.motionState != null) {
      _motionState = _parseMotionState(last.motionState!);
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
    final _FusedSpeedResult fusedSpeed = _fusedSpeed(
      sample: sample,
      derivedSpeedMps: derivedSpeedMps,
    );
    final double fusedSpeedMps = fusedSpeed.speedMps;
    final bool acceptedForAnalytics =
        quality.qualityClass != TrackingQualityClass.reject;
    final bool acceptedForReplay = acceptedForAnalytics;
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
    final MotionState smoothingMotionState = _motionState;
    _updateMotionState(
      quality: quality,
      speedMps: fusedSpeedMps,
      verticalDeltaM: vertical.deltaM,
      headingStability: headingStability,
      deltaSeconds: deltaSeconds,
    );
    _accumulateActivityTotals(
      acceptedForAnalytics: acceptedForAnalytics,
      deltaSeconds: deltaSeconds,
      distanceDeltaM: distanceDeltaM,
    );

    _updateMaxSpeed(
      sampleTime: sample.timestamp.toUtc(),
      speedMps: fusedSpeedMps,
      quality: quality,
      speedTrustedForMax: _isSpeedTrustedForMax(
        sample: sample,
        platformTrust: fusedSpeed.platformTrust,
        derivedSpeedMps: derivedSpeedMps,
      ),
    );

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

    final double liveSpeed = _smoothLiveSpeed(
      rawSpeedMps: fusedSpeedMps,
      sampleTimeUtc: sample.timestamp.toUtc(),
      acceptedForAnalytics: acceptedForAnalytics,
      motionState: smoothingMotionState,
    );
    final SessionStats stats = SessionStats(
      durationS: activeDurationS,
      distanceM: _distanceMeters,
      maxSpeedMps: _maxSpeedMps,
      avgSpeedMps: activeDurationS == 0 ? 0 : _distanceMeters / activeDurationS,
      elevationGainM: _elevationGainMeters == 0 ? null : _elevationGainMeters,
      elevationLossM: _elevationLossMeters == 0 ? null : _elevationLossMeters,
      descentDurationS: _millisecondsToSeconds(_descentDurationMilliseconds),
      liftDurationS: _millisecondsToSeconds(_liftDurationMilliseconds),
      idleDurationS: _millisecondsToSeconds(_idleDurationMilliseconds),
      descentDistanceM: _descentDistanceMeters,
      liftDistanceM: _liftDistanceMeters,
      idleDistanceM: _idleDistanceMeters,
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

    if (_assessPlatformSpeedTrust(
          sample: sample,
          geometrySpeedMps: speedFromGeometry,
        ) ==
        _PlatformSpeedTrust.strong) {
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

    return _assessPlatformSpeedTrust(
          sample: sample,
          geometrySpeedMps: speedFromGeometry,
        ) !=
        _PlatformSpeedTrust.strong;
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

  _FusedSpeedResult _fusedSpeed({
    required LocationSample sample,
    required double derivedSpeedMps,
  }) {
    final double derivedSpeed = derivedSpeedMps
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
    final double? platformSpeedRaw = sample.speedMps;
    if (platformSpeedRaw == null) {
      return _FusedSpeedResult(
        speedMps: derivedSpeed,
        platformTrust: _PlatformSpeedTrust.untrusted,
      );
    }

    if (!platformSpeedRaw.isFinite ||
        platformSpeedRaw < 0 ||
        platformSpeedRaw > SessionConstants.speedHardCapMetersPerSecond) {
      return _FusedSpeedResult(
        speedMps: derivedSpeed,
        platformTrust: _PlatformSpeedTrust.untrusted,
      );
    }

    final double platformSpeed = platformSpeedRaw
        .clamp(0, SessionConstants.speedHardCapMetersPerSecond)
        .toDouble();
    final _PlatformSpeedTrust trust = _assessPlatformSpeedTrust(
      sample: sample,
      geometrySpeedMps: derivedSpeed,
    );

    if (derivedSpeed < SessionConstants.geometryCoherenceMinSpeedMps) {
      return _FusedSpeedResult(
        speedMps: trust == _PlatformSpeedTrust.untrusted
            ? derivedSpeed
            : platformSpeed,
        platformTrust: trust,
      );
    }

    final double fusedSpeed = switch (trust) {
      _PlatformSpeedTrust.strong => platformSpeed,
      _PlatformSpeedTrust.moderate => _blendSpeeds(
          platformSpeed: platformSpeed,
          geometrySpeed: derivedSpeed,
          platformWeight: SessionConstants.platformSpeedModerateBlendWeight,
        ),
      _PlatformSpeedTrust.weak => _blendSpeeds(
          platformSpeed: platformSpeed,
          geometrySpeed: derivedSpeed,
          platformWeight: SessionConstants.platformSpeedWeakBlendWeight,
        ),
      _PlatformSpeedTrust.untrusted => derivedSpeed,
    };
    return _FusedSpeedResult(speedMps: fusedSpeed, platformTrust: trust);
  }

  bool _isSpeedTrustedForMax({
    required LocationSample sample,
    required _PlatformSpeedTrust platformTrust,
    required double derivedSpeedMps,
  }) {
    if (sample.speedMps != null) {
      return platformTrust == _PlatformSpeedTrust.strong ||
          platformTrust == _PlatformSpeedTrust.moderate;
    }
    return _isGeometrySpeedReliableForCoherence(
      sample: sample,
      geometrySpeedMps: derivedSpeedMps,
    );
  }

  _PlatformSpeedTrust _assessPlatformSpeedTrust({
    required LocationSample sample,
    required double geometrySpeedMps,
  }) {
    final double? platformSpeed = sample.speedMps;
    if (platformSpeed == null ||
        !platformSpeed.isFinite ||
        platformSpeed < 0 ||
        platformSpeed > SessionConstants.speedHardCapMetersPerSecond) {
      return _PlatformSpeedTrust.untrusted;
    }

    final double horizontalAccuracyM = sample.accuracyM ??
        SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters;
    final bool horizontalStrong =
        horizontalAccuracyM <= _horizontalAcceptThresholdForSample(sample);
    final bool horizontalUsable = horizontalAccuracyM <=
        SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters;
    if (!horizontalUsable) {
      return _PlatformSpeedTrust.untrusted;
    }

    final double? speedAccuracyMps = sample.speedAccuracyMps;
    final bool speedStrong = speedAccuracyMps != null &&
        speedAccuracyMps <= SessionConstants.platformSpeedStrongAccuracyMps;
    final bool speedUsable = speedAccuracyMps == null ||
        speedAccuracyMps <= SessionConstants.platformSpeedUsableAccuracyMps;
    if (!speedUsable) {
      return _PlatformSpeedTrust.untrusted;
    }

    final bool geometryReliable = _isGeometrySpeedReliableForCoherence(
      sample: sample,
      geometrySpeedMps: geometrySpeedMps,
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
      return _PlatformSpeedTrust.untrusted;
    }

    if (speedStrong &&
        horizontalStrong &&
        (!geometryReliable || mismatchMps <= moderateMismatchToleranceMps)) {
      return _PlatformSpeedTrust.strong;
    }

    if (!geometryReliable || mismatchMps <= moderateMismatchToleranceMps) {
      return _PlatformSpeedTrust.moderate;
    }

    return _PlatformSpeedTrust.weak;
  }

  bool _isGeometrySpeedReliableForCoherence({
    required LocationSample sample,
    required double geometrySpeedMps,
  }) {
    if (geometrySpeedMps < SessionConstants.geometryCoherenceMinSpeedMps) {
      return false;
    }

    final double deltaSeconds = _deltaSecondsFromLastAccepted(sample);
    if (deltaSeconds < SessionConstants.geometryCoherenceMinDeltaSeconds ||
        deltaSeconds > SessionConstants.maxDeltaSeconds) {
      return false;
    }

    final double? horizontalAccuracyM = sample.accuracyM;
    if (horizontalAccuracyM == null) {
      return false;
    }
    return horizontalAccuracyM <= _horizontalAcceptThresholdForSample(sample);
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

  /// Updates the smoothed altitude state, but only commits rejected samples to
  /// the caller as zero delta so low-quality readings cannot skew later gain
  /// and loss accumulation.
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

    final double? previousFilteredAltitude = _lastFilteredAltitude;
    final double alpha = _verticalAlpha(sample.verticalAccuracyM);
    final double filteredAltitude = previousFilteredAltitude == null
        ? sample.altitudeM!
        : previousFilteredAltitude +
            (alpha * (sample.altitudeM! - previousFilteredAltitude));

    final bool acceptedForVerticalState =
        quality.qualityClass != TrackingQualityClass.reject;
    if (!acceptedForVerticalState) {
      return _VerticalResult(
        filteredAltitudeM: previousFilteredAltitude,
        deltaM: 0,
      );
    }

    final double delta = previousFilteredAltitude == null
        ? 0
        : filteredAltitude - previousFilteredAltitude;
    _lastFilteredAltitude = filteredAltitude;

    if (!_isVerticalReliable(sample.verticalAccuracyM)) {
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
      if (_isStableMotionState(candidate)) {
        _lastStableMotionState = candidate;
      }
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

    return _lastStableMotionState;
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
    required bool speedTrustedForMax,
  }) {
    final bool highConfidence =
        quality.qualityClass == TrackingQualityClass.accept &&
            quality.score >= 0.65 &&
            speedTrustedForMax;
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

  double _smoothLiveSpeed({
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

  void _accumulateActivityTotals({
    required bool acceptedForAnalytics,
    required double deltaSeconds,
    required double distanceDeltaM,
  }) {
    if (!acceptedForAnalytics ||
        deltaSeconds <= 0 ||
        deltaSeconds > SessionConstants.maxDeltaSeconds) {
      return;
    }

    final int deltaMilliseconds = (deltaSeconds * 1000).round();
    final SessionActivityType activity = _activityTypeForMotionState(
      _motionState,
    );

    switch (activity) {
      case SessionActivityType.descent:
        _descentDurationMilliseconds += deltaMilliseconds;
        _descentDistanceMeters += distanceDeltaM;
        break;
      case SessionActivityType.lift:
        _liftDurationMilliseconds += deltaMilliseconds;
        _liftDistanceMeters += distanceDeltaM;
        break;
      case SessionActivityType.idle:
        _idleDurationMilliseconds += deltaMilliseconds;
        _idleDistanceMeters += distanceDeltaM;
        break;
    }
  }

  SessionActivityType _activityTypeForMotionState(MotionState motionState) {
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

  int _millisecondsToSeconds(int milliseconds) {
    return (milliseconds / 1000).round();
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

  bool _isStableMotionState(MotionState state) {
    return state == MotionState.activeDescent ||
        state == MotionState.liftUphill ||
        state == MotionState.stoppedIdle;
  }
}

enum _PlatformSpeedTrust {
  strong,
  moderate,
  weak,
  untrusted,
}

class _FusedSpeedResult {
  const _FusedSpeedResult({
    required this.speedMps,
    required this.platformTrust,
  });

  final double speedMps;
  final _PlatformSpeedTrust platformTrust;
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
