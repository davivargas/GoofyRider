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

/// Location-stream configuration the native bridge understands. The stream
/// stays on `acquiring` until the quality classifier confirms a usable fix,
/// then transitions once to `active` for the rest of the session. Motion state
/// drives UI, classifier bands, and stats bucketing separately.
enum TrackingMode {
  acquiring,
  active,
}

extension TrackingModeWire on TrackingMode {
  String get wireValue {
    switch (this) {
      case TrackingMode.acquiring:
        return 'acquiring';
      case TrackingMode.active:
        return 'active';
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
