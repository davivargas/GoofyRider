import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../../core/constants/session_constants.dart';
import '../domain/location_tracking_repository.dart';
import '../domain/tracking_mode_profiles.dart';

class GeolocatorTrackingRepository implements LocationTrackingRepository {
  GeolocatorTrackingRepository({
    DateTime Function()? nowUtc,
  }) : _nowUtc = nowUtc ?? _defaultNowUtc;

  TrackingMode _trackingMode = TrackingMode.acquiring;
  StreamController<LocationSample>? _controller;
  StreamSubscription<Position>? _positionSubscription;
  final DateTime Function() _nowUtc;

  static DateTime _defaultNowUtc() => DateTime.now().toUtc();

  @override
  Future<LocationPermissionState> checkPermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return LocationPermissionState.serviceDisabled;
    }

    final permission = await Geolocator.checkPermission();
    return _toPermissionState(permission);
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return LocationPermissionState.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }

    return _toPermissionState(permission);
  }

  @override
  Future<LocationPermissionState> ensureForegroundPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return LocationPermissionState.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();
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
  Future<String?> checkRecordingReadiness() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return 'Location services are turned off. Turn on GPS to record your session.';
    }
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.whileInUse) {
      return 'Location is set to "Allow only while using the app". Choose "Allow all the time" so recording works in the background.';
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return 'Location permission is required before recording.';
    }
    return null;
  }

  @override
  Future<LocationSample?> getCurrentLocationSample() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return null;
    }

    final permission = await Geolocator.checkPermission();
    final permissionState =
        _toPermissionState(permission);
    if (permissionState != LocationPermissionState.granted &&
        permissionState != LocationPermissionState.grantedForegroundOnly) {
      return null;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return _toLocationSample(position);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<LocationSample> watchPosition() {
    _controller ??= StreamController<LocationSample>.broadcast(
      onListen: _startOrRestartPositionStream,
      onCancel: () async {
        if (!(_controller?.hasListener ?? false)) {
          await _stopPositionStream();
        }
      },
    );

    return _controller!.stream;
  }

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {
    if (_trackingMode == mode) {
      return;
    }
    _trackingMode = mode;
    if (_controller?.hasListener ?? false) {
      await _startOrRestartPositionStream();
    }
  }

  Future<void> _startOrRestartPositionStream() async {
    final streamStartedAtUtc = _nowUtc();
    await _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: _locationSettingsForMode(_trackingMode),
    ).listen(
      (Position position) {
        if (_isStalePreSessionSample(
          position: position,
          streamStartedAtUtc: streamStartedAtUtc,
        )) {
          return;
        }
        _controller?.add(_toLocationSample(position));
      },
      onError: (Object error, StackTrace stackTrace) {
        _controller?.addError(error, stackTrace);
      },
    );
  }

  Future<void> _stopPositionStream() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  bool _isStalePreSessionSample({
    required Position position,
    required DateTime streamStartedAtUtc,
  }) {
    final sampleTimeUtc = position.timestamp.toUtc();
    if (!sampleTimeUtc.isBefore(streamStartedAtUtc)) {
      return false;
    }
    final age = streamStartedAtUtc.difference(sampleTimeUtc);
    return age.inSeconds >= SessionConstants.staleSampleThresholdSeconds;
  }

  LocationSettings _locationSettingsForMode(TrackingMode mode) {
    final profile = TrackingModeProfiles.forMode(mode);
    return _androidSettings(
      accuracy: _mapAccuracy(profile.priority),
      distanceFilter: profile.minDistanceM.round(),
      intervalMs: profile.intervalMs,
    );
  }

  LocationAccuracy _mapAccuracy(TrackingModePriority priority) {
    switch (priority) {
      case TrackingModePriority.highAccuracy:
        return LocationAccuracy.bestForNavigation;
      case TrackingModePriority.balancedPower:
        return LocationAccuracy.high;
    }
  }

  AndroidSettings _androidSettings({
    required LocationAccuracy accuracy,
    required int distanceFilter,
    required int intervalMs,
  }) {
    return AndroidSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      intervalDuration: Duration(milliseconds: intervalMs),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'GoofyRider is recording your session',
        notificationText: 'Tracking route in the background',
        enableWakeLock: true,
      ),
    );
  }

  LocationSample _toLocationSample(Position position) {
    return LocationSample(
      timestamp: position.timestamp.toUtc(),
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyM: position.accuracy,
      altitudeM: position.altitude,
      speedMps: position.speed,
      headingDeg: position.heading,
      verticalAccuracyM: _readVerticalAccuracy(position),
      speedAccuracyMps: _readSpeedAccuracy(position),
      bearingAccuracyDeg: _readBearingAccuracy(position),
      provider: _readProvider(position),
      isMocked: _readIsMocked(position),
    );
  }

  double? _readVerticalAccuracy(Position position) {
    final dynamic dynamicPosition = position;
    try {
      final dynamic value = dynamicPosition.altitudeAccuracy;
      if (value is num) {
        return value.toDouble();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  double? _readSpeedAccuracy(Position position) {
    final dynamic dynamicPosition = position;
    try {
      final dynamic value = dynamicPosition.speedAccuracy;
      if (value is num) {
        return value.toDouble();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  double? _readBearingAccuracy(Position position) {
    final dynamic dynamicPosition = position;
    try {
      final dynamic value = dynamicPosition.headingAccuracy;
      if (value is num) {
        return value.toDouble();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String? _readProvider(Position position) {
    final dynamic dynamicPosition = position;
    try {
      final dynamic value = dynamicPosition.provider;
      if (value is String) {
        return value;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool? _readIsMocked(Position position) {
    final dynamic dynamicPosition = position;
    try {
      final dynamic value = dynamicPosition.isMocked;
      if (value is bool) {
        return value;
      }
      return null;
    } catch (_) {
      return null;
    }
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
