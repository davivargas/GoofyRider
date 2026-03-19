import 'dart:math' as math;

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
    this.elapsedRealtimeNs,
    this.verticalAccuracyM,
    this.speedAccuracyMps,
    this.bearingAccuracyDeg,
    this.provider,
    this.isMocked,
    this.qualityClass,
    this.qualityScore,
    this.qualityReason,
    this.filteredLatitude,
    this.filteredLongitude,
    this.filteredAltitudeM,
    this.fusedSpeedMps,
    this.derivedSpeedMps,
    this.distanceDeltaM,
    this.motionState,
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
  final int? elapsedRealtimeNs;
  final double? verticalAccuracyM;
  final double? speedAccuracyMps;
  final double? bearingAccuracyDeg;
  final String? provider;
  final bool? isMocked;
  final String? qualityClass;
  final double? qualityScore;
  final String? qualityReason;
  final double? filteredLatitude;
  final double? filteredLongitude;
  final double? filteredAltitudeM;
  final double? fusedSpeedMps;
  final double? derivedSpeedMps;
  final double? distanceDeltaM;
  final String? motionState;
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
    this.elapsedRealtimeNs,
    this.verticalAccuracyM,
    this.speedAccuracyMps,
    this.bearingAccuracyDeg,
    this.provider,
    this.isMocked,
    this.qualityClass,
    this.qualityScore,
    this.qualityReason,
    this.filteredLatitude,
    this.filteredLongitude,
    this.filteredAltitudeM,
    this.fusedSpeedMps,
    this.derivedSpeedMps,
    this.distanceDeltaM,
    this.motionState,
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
  final int? elapsedRealtimeNs;
  final double? verticalAccuracyM;
  final double? speedAccuracyMps;
  final double? bearingAccuracyDeg;
  final String? provider;
  final bool? isMocked;
  final String? qualityClass;
  final double? qualityScore;
  final String? qualityReason;
  final double? filteredLatitude;
  final double? filteredLongitude;
  final double? filteredAltitudeM;
  final double? fusedSpeedMps;
  final double? derivedSpeedMps;
  final double? distanceDeltaM;
  final String? motionState;
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
