import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/data/geolocator_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/data/native_android_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/tracking_mode_profiles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel controlChannel =
      MethodChannel('goofyrider/test/location_control');
  const EventChannel eventChannel =
      EventChannel('goofyrider/test/location_events');

  final List<MethodCall> methodCalls = <MethodCall>[];

  setUp(() {
    methodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (MethodCall call) async {
      methodCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, null);
  });

  test('setTrackingMode sends expected native payload on mode switches',
      () async {
    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
    );

    await repository.setTrackingMode(TrackingMode.initializingFix);
    await repository.setTrackingMode(TrackingMode.activeDescent);
    await repository.setTrackingMode(TrackingMode.liftUphill);
    await repository.setTrackingMode(TrackingMode.stoppedIdle);
    await repository.setTrackingMode(TrackingMode.lowConfidenceRecovery);

    expect(methodCalls, hasLength(5));
    expect(
      methodCalls.map((MethodCall call) => call.method),
      everyElement('setTrackingMode'),
    );

    final List<Map<String, dynamic>> payloads = methodCalls
        .map((MethodCall call) =>
            Map<String, dynamic>.from(call.arguments as Map))
        .toList(growable: false);

    final Map<String, dynamic> byMode = <String, dynamic>{
      for (final Map<String, dynamic> payload in payloads)
        payload['mode'] as String: payload,
    };

    final Map<String, dynamic> activeDescentPayload =
        Map<String, dynamic>.from(byMode['active_descent'] as Map);
    final Map<String, dynamic> activeDescentConfig =
        Map<String, dynamic>.from(activeDescentPayload['config'] as Map);
    expect(activeDescentConfig['priority'], 'high_accuracy');
    expect(activeDescentConfig['intervalMs'], 900);
    expect(activeDescentConfig['minIntervalMs'], 250);
    expect(activeDescentConfig['maxDelayMs'], 900);
    expect(activeDescentConfig['minDistanceM'], 5.0);
    expect(activeDescentConfig['waitForAccurate'], isFalse);
    expect(
      activeDescentPayload['staleSampleThresholdSeconds'],
      TrackingModeProfiles.forMode(TrackingMode.activeDescent)
          .staleSampleThresholdSeconds,
    );

    final Map<String, dynamic> liftPayload =
        Map<String, dynamic>.from(byMode['lift_uphill'] as Map);
    final Map<String, dynamic> liftConfig =
        Map<String, dynamic>.from(liftPayload['config'] as Map);
    expect(liftConfig['priority'], 'high_accuracy');
    expect(liftConfig['intervalMs'], 2500);
    expect(liftConfig['minIntervalMs'], 1500);
    expect(liftConfig['maxDelayMs'], 2500);
    expect(liftConfig['minDistanceM'], 10.0);
    expect(
      liftPayload['staleSampleThresholdSeconds'],
      TrackingModeProfiles.forMode(TrackingMode.liftUphill)
          .staleSampleThresholdSeconds,
    );

    final Map<String, dynamic> stoppedPayload =
        Map<String, dynamic>.from(byMode['stopped_idle'] as Map);
    final Map<String, dynamic> stoppedConfig =
        Map<String, dynamic>.from(stoppedPayload['config'] as Map);
    expect(stoppedConfig['intervalMs'], 15000);
    expect(stoppedConfig['minIntervalMs'], 10000);
    expect(stoppedConfig['maxDelayMs'], 15000);
    expect(stoppedConfig['waitForAccurate'], isFalse);
    expect(
      stoppedPayload['staleSampleThresholdSeconds'],
      TrackingModeProfiles.forMode(TrackingMode.stoppedIdle)
          .staleSampleThresholdSeconds,
    );

    final Map<String, dynamic> recoveryPayload =
        Map<String, dynamic>.from(byMode['low_confidence_recovery'] as Map);
    final Map<String, dynamic> recoveryConfig =
        Map<String, dynamic>.from(recoveryPayload['config'] as Map);
    expect(recoveryConfig['priority'], 'high_accuracy');
    expect(recoveryConfig['intervalMs'], 1000);
    expect(recoveryConfig['minIntervalMs'], 500);
    expect(recoveryConfig['maxDelayMs'], 0);
    expect(recoveryConfig['waitForAccurate'], isTrue);
    expect(
      recoveryPayload['staleSampleThresholdSeconds'],
      TrackingModeProfiles.forMode(TrackingMode.lowConfidenceRecovery)
          .staleSampleThresholdSeconds,
    );
  });

  test('setTrackingMode falls back to geolocator delegate when bridge fails',
      () async {
    final _FakeGeolocatorTrackingRepository permissionsDelegate =
        _FakeGeolocatorTrackingRepository(
      ensureResult: LocationPermissionState.granted,
      checkResult: LocationPermissionState.granted,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (MethodCall call) async {
      methodCalls.add(call);
      if (call.method == 'setTrackingMode') {
        throw PlatformException(code: 'not_available');
      }
      return null;
    });

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
      permissionsDelegate: permissionsDelegate,
    );

    await repository.setTrackingMode(TrackingMode.activeDescent);

    expect(methodCalls.map((MethodCall call) => call.method), <String>[
      'setTrackingMode',
    ]);
    expect(permissionsDelegate.setTrackingModeCallCount, 1);
    expect(
      permissionsDelegate.lastTrackingMode,
      TrackingMode.activeDescent,
    );
  });

  test('watchPosition drops malformed native events and keeps valid samples',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          events.success(<String, Object?>{
            'samples': <Object?>[
              <String, Object?>{
                'timestampUtc': 3000,
                'elapsedRealtimeNanos': 30,
                'latitude': 49.30,
                'longitude': -123.30,
                'horizontalAccuracyM': 4.5,
              },
              <String, Object?>{
                'timestampUtc': 2000,
                'elapsedRealtimeNanos': 20,
                'latitude': 'not-a-number',
                'longitude': -123.20,
              },
              <String, Object?>{
                'timestampUtc': 1000,
                'elapsedRealtimeNanos': 10,
                'latitude': 49.10,
                'longitude': -123.10,
                'provider': 'fused',
                'isMocked': false,
              },
              <String, Object?>{
                'timestampUtc': 4000,
                'elapsedRealtimeNanos': 40,
                'latitude': 49.40,
                'longitude': -123.40,
                'horizontalAccuracyM': 'bad-accuracy',
              },
            ],
          });
          events.success(<String, Object?>{'samples': 'bad-envelope'});
          events.endOfStream();
        },
      ),
    );

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
    );

    final List<LocationSample> samples =
        await repository.watchPosition().toList();

    expect(samples, hasLength(2));

    expect(samples[0].timestamp,
        DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true));
    expect(samples[0].elapsedRealtimeNs, 10);
    expect(samples[0].latitude, 49.10);
    expect(samples[0].longitude, -123.10);
    expect(samples[0].provider, 'fused');
    expect(samples[0].isMocked, isFalse);

    expect(samples[1].timestamp,
        DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true));
    expect(samples[1].elapsedRealtimeNs, 30);
    expect(samples[1].latitude, 49.30);
    expect(samples[1].longitude, -123.30);
    expect(samples[1].accuracyM, 4.5);
  });

  test(
      'watchPosition keeps waiting for native startup when first sample is slow',
      () async {
    final LocationSample fallbackSample = LocationSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true),
      latitude: 49.50,
      longitude: -123.50,
      accuracyM: 3.0,
      altitudeM: null,
      speedMps: null,
      headingDeg: null,
    );
    final _FakeGeolocatorTrackingRepository permissionsDelegate =
        _FakeGeolocatorTrackingRepository(
      ensureResult: LocationPermissionState.granted,
      checkResult: LocationPermissionState.granted,
      watchSamples: <LocationSample>[fallbackSample],
    );
    final List<String> fallbackReasons = <String>[];
    final LocationSample nativeSample = LocationSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(1234, isUtc: true),
      latitude: 49.12,
      longitude: -123.12,
      accuracyM: 2.0,
      altitudeM: null,
      speedMps: null,
      headingDeg: null,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          Timer(const Duration(milliseconds: 35), () {
            events.success(<String, Object?>{
              'timestampUtc': nativeSample.timestamp.millisecondsSinceEpoch,
              'latitude': nativeSample.latitude,
              'longitude': nativeSample.longitude,
              'horizontalAccuracyM': nativeSample.accuracyM,
            });
            events.endOfStream();
          });
        },
      ),
    );

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
      permissionsDelegate: permissionsDelegate,
      nativeStreamStartupTimeout: const Duration(milliseconds: 20),
      onFallbackActivated: (String reason, Object? error) {
        fallbackReasons.add(reason);
      },
    );

    final List<LocationSample> samples =
        await repository.watchPosition().toList();

    expect(permissionsDelegate.watchPositionCallCount, 0);
    expect(fallbackReasons, isEmpty);
    expect(samples, hasLength(1));
    expect(samples.first.timestamp, nativeSample.timestamp);
    expect(samples.first.latitude, nativeSample.latitude);
    expect(samples.first.longitude, nativeSample.longitude);
  });

  test(
      'watchPosition reports fallback reason when native stream closes before first event',
      () async {
    final LocationSample fallbackSample = LocationSample(
      timestamp: DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true),
      latitude: 49.50,
      longitude: -123.50,
      accuracyM: 3.0,
      altitudeM: null,
      speedMps: null,
      headingDeg: null,
    );
    final _FakeGeolocatorTrackingRepository permissionsDelegate =
        _FakeGeolocatorTrackingRepository(
      ensureResult: LocationPermissionState.granted,
      checkResult: LocationPermissionState.granted,
      watchSamples: <LocationSample>[fallbackSample],
    );
    final List<String> fallbackReasons = <String>[];
    Object? fallbackError;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          events.endOfStream();
        },
      ),
    );

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
      permissionsDelegate: permissionsDelegate,
      onFallbackActivated: (String reason, Object? error) {
        fallbackReasons.add(reason);
        fallbackError = error;
      },
    );

    final List<LocationSample> samples =
        await repository.watchPosition().take(1).toList();

    expect(permissionsDelegate.watchPositionCallCount, 1);
    expect(fallbackReasons, <String>['native_stream_closed_before_first_event']);
    expect(fallbackError, isNull);
    expect(samples, hasLength(1));
    expect(samples.first.timestamp, fallbackSample.timestamp);
  });

  test('checkRecordingReadiness returns native permission readiness message',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (MethodCall call) async {
      methodCalls.add(call);
      if (call.method == 'checkLocationSettings') {
        return <String, Object?>{
          'ok': false,
          'message':
              'Background location is required for recording. Set location access to Allow all the time.',
        };
      }
      return null;
    });

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
    );

    final String? readiness = await repository.checkRecordingReadiness();

    expect(readiness, isNotNull);
    expect(readiness, contains('Allow all the time'));
    expect(methodCalls.map((MethodCall call) => call.method), <String>[
      'checkLocationSettings',
    ]);
  });

  test(
      'ensurePermissions escalates foreground-only permission through native handoff',
      () async {
    final _FakeGeolocatorTrackingRepository permissionsDelegate =
        _FakeGeolocatorTrackingRepository(
      ensureResult: LocationPermissionState.grantedForegroundOnly,
      checkResult: LocationPermissionState.granted,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (MethodCall call) async {
      methodCalls.add(call);
      if (call.method == 'ensureBackgroundLocationPermission') {
        return <String, Object?>{
          'status': 'granted',
          'openedSettings': false,
        };
      }
      return null;
    });

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
      permissionsDelegate: permissionsDelegate,
    );

    final LocationPermissionState state = await repository.ensurePermissions();

    expect(state, LocationPermissionState.granted);
    expect(permissionsDelegate.ensureCallCount, 1);
    expect(permissionsDelegate.checkCallCount, 1);
    expect(methodCalls.map((MethodCall call) => call.method), <String>[
      'ensureBackgroundLocationPermission',
    ]);
  });

  test('ensurePermissions keeps foreground-only state if native handoff fails',
      () async {
    final _FakeGeolocatorTrackingRepository permissionsDelegate =
        _FakeGeolocatorTrackingRepository(
      ensureResult: LocationPermissionState.grantedForegroundOnly,
      checkResult: LocationPermissionState.granted,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (MethodCall call) async {
      methodCalls.add(call);
      if (call.method == 'ensureBackgroundLocationPermission') {
        throw PlatformException(code: 'not_available');
      }
      return null;
    });

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
      permissionsDelegate: permissionsDelegate,
    );

    final LocationPermissionState state = await repository.ensurePermissions();

    expect(state, LocationPermissionState.grantedForegroundOnly);
    expect(permissionsDelegate.ensureCallCount, 1);
    expect(permissionsDelegate.checkCallCount, 0);
    expect(methodCalls.map((MethodCall call) => call.method), <String>[
      'ensureBackgroundLocationPermission',
    ]);
  });

  test(
      'ensurePermissions re-checks permission state after native settings handoff remains incomplete',
      () async {
    final _FakeGeolocatorTrackingRepository permissionsDelegate =
        _FakeGeolocatorTrackingRepository(
      ensureResult: LocationPermissionState.grantedForegroundOnly,
      checkResult: LocationPermissionState.grantedForegroundOnly,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (MethodCall call) async {
      methodCalls.add(call);
      if (call.method == 'ensureBackgroundLocationPermission') {
        return <String, Object?>{
          'status': 'needs_settings',
          'openedSettings': true,
        };
      }
      return null;
    });

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
      permissionsDelegate: permissionsDelegate,
    );

    final LocationPermissionState state = await repository.ensurePermissions();

    expect(state, LocationPermissionState.grantedForegroundOnly);
    expect(permissionsDelegate.ensureCallCount, 1);
    expect(permissionsDelegate.checkCallCount, 1);
    expect(permissionsDelegate.openAppSettingsCallCount, 0);
    expect(methodCalls.map((MethodCall call) => call.method), <String>[
      'ensureBackgroundLocationPermission',
    ]);
  });

  test(
      'ensurePermissions opens app settings fallback when native settings deep-link is unavailable',
      () async {
    final _FakeGeolocatorTrackingRepository permissionsDelegate =
        _FakeGeolocatorTrackingRepository(
      ensureResult: LocationPermissionState.grantedForegroundOnly,
      checkResult: LocationPermissionState.grantedForegroundOnly,
      openAppSettingsResult: true,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(controlChannel, (MethodCall call) async {
      methodCalls.add(call);
      if (call.method == 'ensureBackgroundLocationPermission') {
        return <String, Object?>{
          'status': 'settings_unavailable',
          'openedSettings': false,
        };
      }
      return null;
    });

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
      permissionsDelegate: permissionsDelegate,
    );

    final LocationPermissionState state = await repository.ensurePermissions();

    expect(state, LocationPermissionState.grantedForegroundOnly);
    expect(permissionsDelegate.ensureCallCount, 1);
    expect(permissionsDelegate.openAppSettingsCallCount, 1);
    expect(permissionsDelegate.checkCallCount, 1);
    expect(methodCalls.map((MethodCall call) => call.method), <String>[
      'ensureBackgroundLocationPermission',
    ]);
  });

  test(
      'ensurePermissions skips native handoff when delegate does not return foreground-only',
      () async {
    final _FakeGeolocatorTrackingRepository permissionsDelegate =
        _FakeGeolocatorTrackingRepository(
      ensureResult: LocationPermissionState.denied,
      checkResult: LocationPermissionState.granted,
    );

    final NativeAndroidTrackingRepository repository =
        NativeAndroidTrackingRepository(
      eventChannel: eventChannel,
      controlChannel: controlChannel,
      permissionsDelegate: permissionsDelegate,
    );

    final LocationPermissionState state = await repository.ensurePermissions();

    expect(state, LocationPermissionState.denied);
    expect(permissionsDelegate.ensureCallCount, 1);
    expect(permissionsDelegate.checkCallCount, 0);
    expect(methodCalls, isEmpty);
  });
}

class _FakeGeolocatorTrackingRepository extends GeolocatorTrackingRepository {
  _FakeGeolocatorTrackingRepository({
    required this.ensureResult,
    required this.checkResult,
    this.watchSamples = const <LocationSample>[],
    this.openAppSettingsResult = true,
  });

  final LocationPermissionState ensureResult;
  final LocationPermissionState checkResult;
  final List<LocationSample> watchSamples;
  final bool openAppSettingsResult;

  int ensureCallCount = 0;
  int checkCallCount = 0;
  int setTrackingModeCallCount = 0;
  int watchPositionCallCount = 0;
  int openAppSettingsCallCount = 0;
  TrackingMode? lastTrackingMode;

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    ensureCallCount += 1;
    return ensureResult;
  }

  @override
  Future<LocationPermissionState> checkPermissions() async {
    checkCallCount += 1;
    return checkResult;
  }

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {
    setTrackingModeCallCount += 1;
    lastTrackingMode = mode;
  }

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCallCount += 1;
    return openAppSettingsResult;
  }

  @override
  Stream<LocationSample> watchPosition() {
    watchPositionCallCount += 1;
    return Stream<LocationSample>.fromIterable(watchSamples);
  }
}
