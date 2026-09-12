import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goofyrider_mobile/features/auth/data/device_label_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('goofyrider/location_control');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('uses the native label and trims it to 80 characters', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'getDeviceLabel');
      return '  ${'x' * 100}  ';
    });

    final label = await DeviceLabelProvider(channel: channel).resolve();

    expect(label.length, 80);
    expect(label, 'x' * 80);
  });

  test('falls back to the operating system name when the channel is missing',
      () async {
    final label = await DeviceLabelProvider(channel: channel).resolve();

    expect(label, isNotEmpty);
    expect(label.length, lessThanOrEqualTo(80));
  });
}
