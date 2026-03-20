import 'package:flutter/services.dart';

import '../../../core/constants/session_constants.dart';
import '../domain/location_tracking_repository.dart';
import '../domain/tracking_mode_profiles.dart';
import 'geolocator_tracking_repository.dart';

class NativeAndroidTrackingRepository implements LocationTrackingRepository {
  NativeAndroidTrackingRepository({
    EventChannel eventChannel = const EventChannel(_eventChannelName),
    MethodChannel controlChannel = const MethodChannel(_controlChannelName),
    GeolocatorTrackingRepository? permissionsDelegate,
  })  : _eventChannel = eventChannel,
        _controlChannel = controlChannel,
        _permissionsDelegate =
            permissionsDelegate ?? GeolocatorTrackingRepository();

  static const String _eventChannelName = 'goofyrider/location_events';
  static const String _controlChannelName = 'goofyrider/location_control';

  final EventChannel _eventChannel;
  final MethodChannel _controlChannel;
  final GeolocatorTrackingRepository _permissionsDelegate;

  @override
  Future<LocationPermissionState> checkPermissions() {
    return _permissionsDelegate.checkPermissions();
  }

  @override
  Future<LocationPermissionState> ensurePermissions() {
    return _permissionsDelegate.ensurePermissions();
  }

  @override
  Future<bool> isServiceEnabled() {
    return _permissionsDelegate.isServiceEnabled();
  }

  @override
  Future<bool> openAppSettings() {
    return _permissionsDelegate.openAppSettings();
  }

  @override
  Future<bool> openLocationSettings() {
    return _permissionsDelegate.openLocationSettings();
  }

  @override
  Future<LocationSample?> getCurrentLocationSample() {
    return _permissionsDelegate.getCurrentLocationSample();
  }

  @override
  Stream<LocationSample> watchPosition() async* {
    await for (final dynamic event in _eventChannel.receiveBroadcastStream()) {
      final List<Map<String, dynamic>> rawSamples = _extractRawSamples(event);
      rawSamples.sort(_sampleSortComparator);
      for (final Map<String, dynamic> raw in rawSamples) {
        yield _mapSample(raw);
      }
    }
  }

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {
    final TrackingModeProfile profile = TrackingModeProfiles.forMode(mode);
    await _controlChannel.invokeMethod<void>(
      'setTrackingMode',
      <String, dynamic>{
        'mode': mode.wireValue,
        'config': profile.toChannelPayload(),
        'staleSampleThresholdSeconds':
            SessionConstants.staleSampleThresholdSeconds,
      },
    );
  }

  int _sampleSortComparator(Map<String, dynamic> a, Map<String, dynamic> b) {
    final int? elapsedA = _asNullableInt(a['elapsedRealtimeNanos']);
    final int? elapsedB = _asNullableInt(b['elapsedRealtimeNanos']);
    if (elapsedA != null && elapsedB != null) {
      return elapsedA.compareTo(elapsedB);
    }
    final DateTime tsA = _parseTimestamp(a['timestampUtc']);
    final DateTime tsB = _parseTimestamp(b['timestampUtc']);
    return tsA.compareTo(tsB);
  }

  List<Map<String, dynamic>> _extractRawSamples(dynamic event) {
    if (event is Map) {
      final dynamic samples = event['samples'];
      if (samples is List) {
        return samples
            .whereType<Map>()
            .map(
              (Map item) => item.map(
                (dynamic key, dynamic value) => MapEntry(key.toString(), value),
              ),
            )
            .toList(growable: false);
      }
      return <Map<String, dynamic>>[
        event.map(
          (dynamic key, dynamic value) => MapEntry(key.toString(), value),
        ),
      ];
    }

    if (event is List) {
      return event
          .whereType<Map>()
          .map(
            (Map item) => item.map(
              (dynamic key, dynamic value) => MapEntry(key.toString(), value),
            ),
          )
          .toList(growable: false);
    }

    return <Map<String, dynamic>>[];
  }

  LocationSample _mapSample(Map<String, dynamic> raw) {
    return LocationSample(
      timestamp: _parseTimestamp(raw['timestampUtc']),
      latitude: _asDouble(raw['latitude']) ?? 0,
      longitude: _asDouble(raw['longitude']) ?? 0,
      accuracyM: _asDouble(raw['horizontalAccuracyM']),
      altitudeM: _asDouble(raw['altitudeM']),
      speedMps: _asDouble(raw['platformSpeedMps']),
      headingDeg: _asDouble(raw['bearingDeg']),
      elapsedRealtimeNs: _asNullableInt(raw['elapsedRealtimeNanos']),
      verticalAccuracyM: _asDouble(raw['verticalAccuracyM']),
      speedAccuracyMps: _asDouble(raw['speedAccuracyMps']),
      bearingAccuracyDeg: _asDouble(raw['bearingAccuracyDeg']),
      provider: raw['provider'] as String?,
      isMocked: raw['isMocked'] as bool?,
    );
  }

  DateTime _parseTimestamp(dynamic value) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is String) {
      return DateTime.parse(value).toUtc();
    }
    return DateTime.now().toUtc();
  }

  double? _asDouble(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString());
  }

  int? _asNullableInt(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }
}
