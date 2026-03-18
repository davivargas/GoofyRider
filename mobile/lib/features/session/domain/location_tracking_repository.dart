class LocationSample {
  const LocationSample({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.altitudeM,
    required this.speedMps,
    required this.headingDeg,
  });

  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final double? accuracyM;
  final double? altitudeM;
  final double? speedMps;
  final double? headingDeg;
}

enum LocationPermissionState {
  granted,
  grantedForegroundOnly,
  denied,
  deniedForever,
  serviceDisabled,
}

abstract class LocationTrackingRepository {
  Future<LocationPermissionState> checkPermissions();
  Future<LocationPermissionState> ensurePermissions();
  Future<bool> isServiceEnabled();
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
  Stream<LocationSample> watchPosition();
}
