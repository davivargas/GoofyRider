import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/location_tracking_repository.dart';
import '../domain/tracking_mode_profiles.dart';
import 'geolocator_tracking_repository.dart';

class NativeAndroidTrackingRepository implements LocationTrackingRepository {
  NativeAndroidTrackingRepository({
    EventChannel eventChannel = const EventChannel(_eventChannelName),
    MethodChannel controlChannel = const MethodChannel(_controlChannelName),
    GeolocatorTrackingRepository? permissionsDelegate,
    Duration nativeStreamStartupTimeout = const Duration(seconds: 12),
    void Function(String reason, Object? error)? onFallbackActivated,
  })  : _eventChannel = eventChannel,
        _controlChannel = controlChannel,
        _permissionsDelegate =
            permissionsDelegate ?? GeolocatorTrackingRepository(),
        _nativeStreamStartupTimeout = nativeStreamStartupTimeout,
        _onFallbackActivated = onFallbackActivated;

  static const String _eventChannelName = 'goofyrider/location_events';
  static const String _controlChannelName = 'goofyrider/location_control';

  final EventChannel _eventChannel;
  final MethodChannel _controlChannel;
  final GeolocatorTrackingRepository _permissionsDelegate;
  final Duration _nativeStreamStartupTimeout;
  final void Function(String reason, Object? error)? _onFallbackActivated;

  @override
  Future<LocationPermissionState> checkPermissions() {
    return _permissionsDelegate.checkPermissions();
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    final initialState =
        await _permissionsDelegate.ensurePermissions();
    if (initialState != LocationPermissionState.grantedForegroundOnly) {
      return initialState;
    }

    try {
      final response =
          await _controlChannel.invokeMapMethod<Object?, Object?>(
        'ensureBackgroundLocationPermission',
      );
      final status = response?['status'] as String?;
      switch (status) {
        case 'granted':
        case 'needs_settings':
        case 'fine_permission_required':
          return _permissionsDelegate.checkPermissions();
        case 'settings_unavailable':
          await _permissionsDelegate.openAppSettings();
          return _permissionsDelegate.checkPermissions();
        case 'denied':
          return initialState;
      }
      return _permissionsDelegate.checkPermissions();
    } on PlatformException {
      return initialState;
    } on MissingPluginException {
      return initialState;
    }
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

  /// Prefers the native bridge's settings check, but falls back to the
  /// geolocator-based readiness path when the bridge is unavailable.
  Future<String?> checkRecordingReadiness() async {
    try {
      final response =
          await _controlChannel.invokeMapMethod<Object?, Object?>(
        'checkLocationSettings',
      );
      if (response?['ok'] == true) {
        return null;
      }
      final message = response?['message'] as String?;
      if (message != null && message.isNotEmpty) {
        return message;
      }
    } on PlatformException {
      // Fall back to the geolocator path if the native bridge is unavailable.
    }
    return _permissionsDelegate.checkRecordingReadiness();
  }

  @override
  Future<LocationSample?> getCurrentLocationSample() {
    return _permissionsDelegate.getCurrentLocationSample();
  }

  @override
  Stream<LocationSample> watchPosition() async* {
    StreamIterator<dynamic>? iterator;
    try {
      iterator =
          StreamIterator<dynamic>(_eventChannel.receiveBroadcastStream());
      final firstEventFuture = iterator.moveNext();
      bool hasFirstEvent;
      try {
        hasFirstEvent =
            await firstEventFuture.timeout(_nativeStreamStartupTimeout);
      } on TimeoutException {
        debugPrint(
          'NativeAndroidTrackingRepository: native startup exceeded '
          '${_nativeStreamStartupTimeout.inMilliseconds}ms; continuing to wait '
          'without geolocator fallback.',
        );
        hasFirstEvent = await firstEventFuture;
      }

      if (!hasFirstEvent) {
        _activateGeolocatorFallback(
          reason: 'native_stream_closed_before_first_event',
        );
        yield* _permissionsDelegate.watchPosition();
        return;
      }

      for (final sample in _mapSamples(iterator.current)) {
        yield sample;
      }
      while (await iterator.moveNext()) {
        for (final sample in _mapSamples(iterator.current)) {
          yield sample;
        }
      }
    } on MissingPluginException catch (error) {
      _activateGeolocatorFallback(reason: 'missing_plugin', error: error);
      yield* _permissionsDelegate.watchPosition();
    } on PlatformException catch (error) {
      _activateGeolocatorFallback(reason: 'platform_exception', error: error);
      yield* _permissionsDelegate.watchPosition();
    } finally {
      await iterator?.cancel();
    }
  }

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {
    final profile = TrackingModeProfiles.forMode(mode);
    try {
      await _controlChannel.invokeMethod<void>(
        'setTrackingMode',
        <String, dynamic>{
          'mode': mode.wireValue,
          'config': profile.toChannelPayload(),
          'staleSampleThresholdSeconds': profile.staleSampleThresholdSeconds,
        },
      );
    } on MissingPluginException {
      await _permissionsDelegate.setTrackingMode(mode);
    } on PlatformException {
      await _permissionsDelegate.setTrackingMode(mode);
    }
  }

  int _sampleSortComparator(LocationSample a, LocationSample b) {
    final elapsedA = a.elapsedRealtimeNs;
    final elapsedB = b.elapsedRealtimeNs;
    if (elapsedA != null && elapsedB != null) {
      return elapsedA.compareTo(elapsedB);
    }
    return a.timestamp.compareTo(b.timestamp);
  }

  List<LocationSample> _mapSamples(dynamic event) {
    final samples = _extractRawSamples(event)
        .map(_tryMapSample)
        .whereType<LocationSample>()
        .toList(growable: false);
    // Drop malformed native payloads instead of coercing them into default
    // coordinates/timestamps that would pollute analytics.
    samples.sort(_sampleSortComparator);
    return samples;
  }

  List<Map<String, dynamic>> _extractRawSamples(dynamic event) {
    if (event is Map) {
      final rawEvent = _normalizeMap(event);
      if (rawEvent.containsKey('samples')) {
        final dynamic samples = rawEvent['samples'];
        if (samples is! List) {
          return <Map<String, dynamic>>[];
        }
        return samples
            .whereType<Map>()
            .map(_normalizeMap)
            .toList(growable: false);
      }
      return <Map<String, dynamic>>[rawEvent];
    }

    if (event is List) {
      return event.whereType<Map>().map(_normalizeMap).toList(growable: false);
    }

    return <Map<String, dynamic>>[];
  }

  Map<String, dynamic> _normalizeMap(Map event) {
    return event.map(
      (dynamic key, dynamic value) => MapEntry(key.toString(), value),
    );
  }

  /// Parses one native payload and rejects the whole sample if any required
  /// field is malformed or out of range.
  LocationSample? _tryMapSample(Map<String, dynamic> raw) {
    try {
      return LocationSample(
        timestamp: _parseTimestamp(raw['timestampUtc']),
        latitude: _parseCoordinate(raw['latitude'], min: -90, max: 90),
        longitude: _parseCoordinate(raw['longitude'], min: -180, max: 180),
        accuracyM: _asNullableDouble(raw['horizontalAccuracyM']),
        altitudeM: _asNullableDouble(raw['altitudeM']),
        speedMps: _asNullableDouble(raw['platformSpeedMps']),
        headingDeg: _asNullableDouble(raw['bearingDeg']),
        elapsedRealtimeNs: _asNullableInt(raw['elapsedRealtimeNanos']),
        verticalAccuracyM: _asNullableDouble(raw['verticalAccuracyM']),
        speedAccuracyMps: _asNullableDouble(raw['speedAccuracyMps']),
        bearingAccuracyDeg: _asNullableDouble(raw['bearingAccuracyDeg']),
        provider: _asNullableString(raw['provider']),
        isMocked: _asNullableBool(raw['isMocked']),
      );
    } on FormatException {
      return null;
    }
  }

  /// Accepts only explicit epoch millis or ISO-8601 strings so bad timestamps
  /// cannot silently become "now" and reorder the stream.
  DateTime _parseTimestamp(dynamic value) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is String) {
      try {
        return DateTime.parse(value).toUtc();
      } on FormatException {
        throw const FormatException('Invalid timestamp');
      }
    }
    throw const FormatException('Invalid timestamp');
  }

  /// Validates numeric coordinates and bounds before they enter the pipeline.
  double _parseCoordinate(
    dynamic value, {
    required double min,
    required double max,
  }) {
    final parsed = _tryParseFiniteDouble(value);
    if (parsed == null || parsed < min || parsed > max) {
      throw const FormatException('Invalid coordinate');
    }
    return parsed;
  }

  double? _asNullableDouble(dynamic value) {
    if (value == null) {
      return null;
    }
    final parsed = _tryParseFiniteDouble(value);
    if (parsed == null) {
      throw const FormatException('Invalid double');
    }
    return parsed;
  }

  int? _asNullableInt(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      if (!value.isFinite || value.truncateToDouble() != value.toDouble()) {
        throw const FormatException('Invalid int');
      }
      return value.toInt();
    }
    final parsed = int.tryParse(value.toString());
    if (parsed == null) {
      throw const FormatException('Invalid int');
    }
    return parsed;
  }

  String? _asNullableString(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    throw const FormatException('Invalid string');
  }

  bool? _asNullableBool(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is bool) {
      return value;
    }
    throw const FormatException('Invalid bool');
  }

  double? _tryParseFiniteDouble(dynamic value) {
    if (value is num) {
      final parsed = value.toDouble();
      return parsed.isFinite ? parsed : null;
    }
    final parsed = double.tryParse(value.toString());
    if (parsed == null || !parsed.isFinite) {
      return null;
    }
    return parsed;
  }

  void _activateGeolocatorFallback({
    required String reason,
    Object? error,
  }) {
    debugPrint(
      'NativeAndroidTrackingRepository: activating geolocator fallback '
      '($reason).',
    );
    _onFallbackActivated?.call(reason, error);
  }
}
