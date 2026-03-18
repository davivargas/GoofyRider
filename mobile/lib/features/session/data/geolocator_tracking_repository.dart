import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../../core/constants/session_constants.dart';
import '../domain/location_tracking_repository.dart';

class GeolocatorTrackingRepository implements LocationTrackingRepository {
  GeolocatorTrackingRepository();

  @override
  Future<LocationPermissionState> checkPermissions() async {
    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return LocationPermissionState.serviceDisabled;
    }

    final LocationPermission permission = await Geolocator.checkPermission();
    return _toPermissionState(permission);
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return LocationPermissionState.serviceDisabled;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    return _toPermissionState(permission);
  }

  @override
  Future<bool> isServiceEnabled() {
    return Geolocator.isLocationServiceEnabled();
  }

  @override
  Future<bool> openAppSettings() {
    return Geolocator.openAppSettings();
  }

  @override
  Future<bool> openLocationSettings() {
    return Geolocator.openLocationSettings();
  }

  @override
  Stream<LocationSample> watchPosition() {
    final LocationSettings locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: SessionConstants.distanceFilterMeters.round(),
      intervalDuration:
          const Duration(seconds: SessionConstants.targetIntervalSeconds),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'GoofyRider is recording your session',
        notificationText: 'Tracking route in the background',
        enableWakeLock: false,
      ),
    );

    return Geolocator.getPositionStream(locationSettings: locationSettings).map(
      (Position position) {
        return LocationSample(
          timestamp: position.timestamp.toUtc(),
          latitude: position.latitude,
          longitude: position.longitude,
          accuracyM: position.accuracy,
          altitudeM: position.altitude,
          speedMps: position.speed,
          headingDeg: position.heading,
        );
      },
    );
  }

  LocationPermissionState _toPermissionState(LocationPermission permission) {
    if (permission == LocationPermission.denied) {
      return LocationPermissionState.denied;
    }

    if (permission == LocationPermission.deniedForever) {
      return LocationPermissionState.deniedForever;
    }

    if (permission == LocationPermission.whileInUse) {
      return LocationPermissionState.grantedForegroundOnly;
    }

    return LocationPermissionState.granted;
  }
}
