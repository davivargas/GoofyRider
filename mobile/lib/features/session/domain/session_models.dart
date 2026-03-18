import 'dart:math' as math;

import '../../../core/constants/session_constants.dart';

enum LocalSessionState {
  idle,
  recording,
  paused,
  locallyCompleted,
  syncPending,
  syncing,
  synced,
  syncFailed,
}

extension LocalSessionStateCodec on LocalSessionState {
  String get wireValue {
    switch (this) {
      case LocalSessionState.idle:
        return 'idle';
      case LocalSessionState.recording:
        return 'recording';
      case LocalSessionState.paused:
        return 'paused';
      case LocalSessionState.locallyCompleted:
        return 'locallyCompleted';
      case LocalSessionState.syncPending:
        return 'syncPending';
      case LocalSessionState.syncing:
        return 'syncing';
      case LocalSessionState.synced:
        return 'synced';
      case LocalSessionState.syncFailed:
        return 'syncFailed';
    }
  }

  static LocalSessionState fromWire(String value) {
    return LocalSessionState.values.firstWhere(
      (LocalSessionState state) => state.wireValue == value,
      orElse: () => LocalSessionState.idle,
    );
  }
}

class LocalRideSession {
  const LocalRideSession({
    required this.localId,
    required this.remoteId,
    required this.resortId,
    required this.startedAt,
    required this.endedAt,
    required this.activeDurationS,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.elevationGainM,
    required this.elevationLossM,
    required this.state,
    required this.pointCount,
    required this.syncAttemptCount,
    required this.lastSyncError,
    required this.createdAt,
    required this.updatedAt,
  });

  final int localId;
  final String? remoteId;
  final String? resortId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int activeDurationS;
  final double distanceM;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final int? elevationGainM;
  final int? elevationLossM;
  final LocalSessionState state;
  final int pointCount;
  final int syncAttemptCount;
  final String? lastSyncError;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isUnsynced =>
      state == LocalSessionState.syncPending ||
      state == LocalSessionState.syncing ||
      state == LocalSessionState.syncFailed ||
      state == LocalSessionState.locallyCompleted;

  bool get isInProgress =>
      state == LocalSessionState.recording || state == LocalSessionState.paused;
}

class LocalSessionPoint {
  const LocalSessionPoint({
    required this.id,
    required this.localSessionId,
    required this.recordedAt,
    required this.tOffsetMs,
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.altitudeM,
    required this.speedMps,
    required this.headingDeg,
    required this.acceptedForAnalytics,
  });

  final int id;
  final int localSessionId;
  final DateTime recordedAt;
  final int tOffsetMs;
  final double latitude;
  final double longitude;
  final double? accuracyM;
  final double? altitudeM;
  final double? speedMps;
  final double? headingDeg;
  final bool acceptedForAnalytics;
}

class NewSessionPoint {
  const NewSessionPoint({
    required this.recordedAt,
    required this.tOffsetMs,
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.altitudeM,
    required this.speedMps,
    required this.headingDeg,
    required this.acceptedForAnalytics,
  });

  final DateTime recordedAt;
  final int tOffsetMs;
  final double latitude;
  final double longitude;
  final double? accuracyM;
  final double? altitudeM;
  final double? speedMps;
  final double? headingDeg;
  final bool acceptedForAnalytics;
}

class SessionStats {
  const SessionStats({
    required this.durationS,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.elevationGainM,
    required this.elevationLossM,
  });

  final int durationS;
  final double distanceM;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final int? elevationGainM;
  final int? elevationLossM;

  static const SessionStats zero = SessionStats(
    durationS: 0,
    distanceM: 0,
    maxSpeedMps: 0,
    avgSpeedMps: 0,
    elevationGainM: null,
    elevationLossM: null,
  );
}

class PointAcceptanceResult {
  const PointAcceptanceResult({
    required this.acceptedForAnalytics,
    required this.acceptedForReplay,
    required this.reason,
  });

  final bool acceptedForAnalytics;
  final bool acceptedForReplay;
  final String reason;
}

class SessionAnalyticsEngine {
  const SessionAnalyticsEngine();

  PointAcceptanceResult evaluate(
    LocalSessionPoint? previousAcceptedPoint,
    NewSessionPoint point,
  ) {
    if (!_isValidCoordinate(point.latitude, point.longitude)) {
      return const PointAcceptanceResult(
        acceptedForAnalytics: false,
        acceptedForReplay: false,
        reason: 'invalid_coordinate',
      );
    }

    final double? accuracy = point.accuracyM;
    if (accuracy != null &&
        accuracy > SessionConstants.softAccuracyThresholdMeters) {
      return const PointAcceptanceResult(
        acceptedForAnalytics: false,
        acceptedForReplay: true,
        reason: 'accuracy_too_low',
      );
    }

    if (previousAcceptedPoint == null) {
      final bool analyticsOkay = accuracy == null ||
          accuracy <= SessionConstants.analyticsAccuracyThresholdMeters;
      return PointAcceptanceResult(
        acceptedForAnalytics: analyticsOkay,
        acceptedForReplay: true,
        reason: analyticsOkay ? 'accepted' : 'soft_accuracy_only',
      );
    }

    if (!point.recordedAt.isAfter(previousAcceptedPoint.recordedAt)) {
      return const PointAcceptanceResult(
        acceptedForAnalytics: false,
        acceptedForReplay: false,
        reason: 'timestamp_not_increasing',
      );
    }

    final int deltaS =
        point.recordedAt.difference(previousAcceptedPoint.recordedAt).inSeconds;

    if (deltaS < SessionConstants.minDeltaSeconds ||
        deltaS > SessionConstants.maxDeltaSeconds) {
      return const PointAcceptanceResult(
        acceptedForAnalytics: false,
        acceptedForReplay: true,
        reason: 'invalid_delta',
      );
    }

    final double segmentDistance = haversineDistanceMeters(
      previousAcceptedPoint.latitude,
      previousAcceptedPoint.longitude,
      point.latitude,
      point.longitude,
    );

    final double impliedSpeed = segmentDistance / deltaS;
    if (impliedSpeed > SessionConstants.maxSpeedMetersPerSecond) {
      return const PointAcceptanceResult(
        acceptedForAnalytics: false,
        acceptedForReplay: true,
        reason: 'speed_outlier',
      );
    }

    final bool analyticsOkay = accuracy == null ||
        accuracy <= SessionConstants.analyticsAccuracyThresholdMeters;

    return PointAcceptanceResult(
      acceptedForAnalytics: analyticsOkay,
      acceptedForReplay: true,
      reason: analyticsOkay ? 'accepted' : 'soft_accuracy_only',
    );
  }

  SessionStats computeStats({
    required List<LocalSessionPoint> acceptedPoints,
    required int activeDurationS,
  }) {
    if (acceptedPoints.length < 2) {
      return SessionStats(
        durationS: activeDurationS,
        distanceM: 0,
        maxSpeedMps: 0,
        avgSpeedMps: activeDurationS == 0 ? 0 : 0,
        elevationGainM: null,
        elevationLossM: null,
      );
    }

    double distance = 0;
    double maxSpeed = 0;
    final List<double> altitudeSamples = <double>[];

    for (int index = 1; index < acceptedPoints.length; index++) {
      final LocalSessionPoint previous = acceptedPoints[index - 1];
      final LocalSessionPoint current = acceptedPoints[index];
      final int deltaS =
          current.recordedAt.difference(previous.recordedAt).inSeconds;
      if (deltaS <= 0) {
        continue;
      }

      final double segmentDistance = haversineDistanceMeters(
        previous.latitude,
        previous.longitude,
        current.latitude,
        current.longitude,
      );

      final double speed = segmentDistance / deltaS;
      if (speed > SessionConstants.maxSpeedMetersPerSecond) {
        continue;
      }

      distance += segmentDistance;
      maxSpeed = math.max(maxSpeed, speed);

      if (current.altitudeM != null) {
        altitudeSamples.add(current.altitudeM!);
      }
    }

    final double avgSpeed =
        activeDurationS == 0 ? 0 : distance / activeDurationS;

    final (int? gain, int? loss) = _computeElevation(acceptedPoints);

    return SessionStats(
      durationS: activeDurationS,
      distanceM: distance,
      maxSpeedMps: maxSpeed,
      avgSpeedMps: avgSpeed,
      elevationGainM: gain,
      elevationLossM: loss,
    );
  }

  (int?, int?) _computeElevation(List<LocalSessionPoint> points) {
    final List<double> altitudes = points
        .map((LocalSessionPoint point) => point.altitudeM)
        .whereType<double>()
        .toList(growable: false);

    if (altitudes.length < SessionConstants.elevationWindow) {
      return (null, null);
    }

    int gain = 0;
    int loss = 0;
    double? previousSmoothed;

    for (int index = 0; index < altitudes.length; index++) {
      final int start =
          math.max(0, index - SessionConstants.elevationWindow + 1);
      final List<double> window = altitudes.sublist(start, index + 1);
      final double smoothed =
          window.reduce((double a, double b) => a + b) / window.length;

      if (previousSmoothed != null) {
        final double delta = smoothed - previousSmoothed;
        if (delta.abs() >= SessionConstants.minElevationDeltaMeters) {
          if (delta > 0) {
            gain += delta.round();
          } else {
            loss += delta.abs().round();
          }
        }
      }
      previousSmoothed = smoothed;
    }

    return (gain == 0 ? null : gain, loss == 0 ? null : loss);
  }

  bool _isValidCoordinate(double latitude, double longitude) {
    return latitude >= -90 &&
        latitude <= 90 &&
        longitude >= -180 &&
        longitude <= 180;
  }
}

double haversineDistanceMeters(
  double startLat,
  double startLng,
  double endLat,
  double endLng,
) {
  const double earthRadiusMeters = 6371000;

  final double dLat = _toRadians(endLat - startLat);
  final double dLng = _toRadians(endLng - startLng);
  final double radStartLat = _toRadians(startLat);
  final double radEndLat = _toRadians(endLat);

  final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(radStartLat) *
          math.cos(radEndLat) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}

double _toRadians(double degrees) => degrees * (math.pi / 180);
