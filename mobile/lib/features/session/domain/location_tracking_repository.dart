class LocationSample {
  const LocationSample({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.altitudeM,
    required this.speedMps,
    required this.headingDeg,
    this.elapsedRealtimeNs,
    this.verticalAccuracyM,
    this.speedAccuracyMps,
    this.bearingAccuracyDeg,
    this.provider,
    this.isMocked,
  });

  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final double? accuracyM;
  final double? altitudeM;
  final double? speedMps;
  final double? headingDeg;
  final int? elapsedRealtimeNs;
  final double? verticalAccuracyM;
  final double? speedAccuracyMps;
  final double? bearingAccuracyDeg;
  final String? provider;
  final bool? isMocked;
}

enum LocationPermissionState {
  granted,
  grantedForegroundOnly,
  denied,
  deniedForever,
  serviceDisabled,
}

enum TrackingMode {
  initializingFix,
  activeDescent,
  liftUphill,
  walkingSlow,
  stoppedIdle,
  lowConfidenceRecovery,
}

extension TrackingModeWire on TrackingMode {
  String get wireValue {
    switch (this) {
      case TrackingMode.initializingFix:
        return 'initializing_fix';
      case TrackingMode.activeDescent:
        return 'active_descent';
      case TrackingMode.liftUphill:
        return 'lift_uphill';
      case TrackingMode.walkingSlow:
        return 'walking_slow';
      case TrackingMode.stoppedIdle:
        return 'stopped_idle';
      case TrackingMode.lowConfidenceRecovery:
        return 'low_confidence_recovery';
    }
  }
}

abstract class LocationTrackingRepository {
  Future<LocationPermissionState> checkPermissions();
  Future<LocationPermissionState> ensurePermissions();
  Future<bool> isServiceEnabled();
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
  Future<String?> checkRecordingReadiness();
  Future<LocationSample?> getCurrentLocationSample();
  Stream<LocationSample> watchPosition();
  Future<void> setTrackingMode(TrackingMode mode);
}
