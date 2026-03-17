import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../domain/location_tracking_repository.dart';

class GeolocatorTrackingRepository implements LocationTrackingRepository {
  GeolocatorTrackingRepository();

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

    if (permission == LocationPermission.denied) {
      return LocationPermissionState.denied;
    }

    if (permission == LocationPermission.deniedForever) {
      return LocationPermissionState.deniedForever;
    }

    return LocationPermissionState.granted;
  }

  @override
  Future<bool> isServiceEnabled() {
    return Geolocator.isLocationServiceEnabled();
  }

  @override
  Stream<LocationSample> watchPosition() {
    final LocationSettings locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5,
      intervalDuration: const Duration(seconds: 2),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'GoofyRider is recording your session',
        notificationText: 'Tracking route in the background',
        enableWakeLock: true,
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
}
