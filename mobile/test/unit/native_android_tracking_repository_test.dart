import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/constants/session_constants.dart';
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

    for (final Map<String, dynamic> payload in payloads) {
      expect(
        payload['staleSampleThresholdSeconds'],
        SessionConstants.staleSampleThresholdSeconds,
      );
    }

    final Map<String, dynamic> byMode = <String, dynamic>{
      for (final Map<String, dynamic> payload in payloads)
        payload['mode'] as String: payload['config'],
    };

    final Map<String, dynamic> activeDescentConfig =
        Map<String, dynamic>.from(byMode['active_descent'] as Map);
    expect(activeDescentConfig['priority'], 'high_accuracy');
    expect(activeDescentConfig['intervalMs'], 900);
    expect(activeDescentConfig['minIntervalMs'], 250);
    expect(activeDescentConfig['maxDelayMs'], 900);
    expect(activeDescentConfig['minDistanceM'], 1.0);
    expect(activeDescentConfig['waitForAccurate'], isFalse);

    final Map<String, dynamic> liftConfig =
        Map<String, dynamic>.from(byMode['lift_uphill'] as Map);
    expect(liftConfig['priority'], 'balanced_power');
    expect(liftConfig['intervalMs'], 4000);
    expect(liftConfig['minIntervalMs'], 2500);
    expect(liftConfig['maxDelayMs'], 12000);
    expect(liftConfig['minDistanceM'], 6.0);

    final Map<String, dynamic> stoppedConfig =
        Map<String, dynamic>.from(byMode['stopped_idle'] as Map);
    expect(stoppedConfig['intervalMs'], 12000);
    expect(stoppedConfig['minIntervalMs'], 8000);
    expect(stoppedConfig['maxDelayMs'], 45000);
    expect(stoppedConfig['waitForAccurate'], isFalse);

    final Map<String, dynamic> recoveryConfig =
        Map<String, dynamic>.from(byMode['low_confidence_recovery'] as Map);
    expect(recoveryConfig['priority'], 'high_accuracy');
    expect(recoveryConfig['intervalMs'], 1000);
    expect(recoveryConfig['minIntervalMs'], 500);
    expect(recoveryConfig['maxDelayMs'], 0);
    expect(recoveryConfig['waitForAccurate'], isTrue);
  });
}
