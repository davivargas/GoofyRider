import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/constants/session_constants.dart';
import 'package:goofyrider_mobile/features/session/data/geolocator_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/data/native_android_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';

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
    expect(activeDescentConfig['minDistanceM'], 1.0);
    expect(activeDescentConfig['waitForAccurate'], isFalse);
    expect(
      activeDescentPayload['staleSampleThresholdSeconds'],
      SessionConstants.staleSampleThresholdSeconds,
    );

    final Map<String, dynamic> liftPayload =
        Map<String, dynamic>.from(byMode['lift_uphill'] as Map);
    final Map<String, dynamic> liftConfig =
        Map<String, dynamic>.from(liftPayload['config'] as Map);
    expect(liftConfig['priority'], 'balanced_power');
    expect(liftConfig['intervalMs'], 4000);
    expect(liftConfig['minIntervalMs'], 2500);
    expect(liftConfig['maxDelayMs'], 12000);
    expect(liftConfig['minDistanceM'], 6.0);
    expect(
      liftPayload['staleSampleThresholdSeconds'],
      SessionConstants.staleSampleThresholdSeconds,
    );

    final Map<String, dynamic> stoppedPayload =
        Map<String, dynamic>.from(byMode['stopped_idle'] as Map);
    final Map<String, dynamic> stoppedConfig =
        Map<String, dynamic>.from(stoppedPayload['config'] as Map);
    expect(stoppedConfig['intervalMs'], 12000);
    expect(stoppedConfig['minIntervalMs'], 8000);
    expect(stoppedConfig['maxDelayMs'], 45000);
    expect(stoppedConfig['waitForAccurate'], isFalse);
    expect(stoppedPayload['staleSampleThresholdSeconds'], 60);

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
      SessionConstants.staleSampleThresholdSeconds,
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
  });

  final LocationPermissionState ensureResult;
  final LocationPermissionState checkResult;

  int ensureCallCount = 0;
  int checkCallCount = 0;

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
}
