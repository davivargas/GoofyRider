import 'dart:io';

import 'package:flutter/services.dart';

/// Resolves a short human-readable device label (`Google Pixel 8 / Android 15`)
/// that the backend stores next to each refresh token so a user can tell
/// their devices apart. Never throws; falls back to the OS name.
class DeviceLabelProvider {
  DeviceLabelProvider({
    MethodChannel channel = const MethodChannel('fallline/location_control'),
  }) : _channel = channel;

  static const int maxLength = 80;

  final MethodChannel _channel;
  String? _cached;

  Future<String> resolve() async {
    final cached = _cached;
    if (cached != null) {
      return cached;
    }
    var label = Platform.operatingSystem;
    try {
      final native = await _channel.invokeMethod<String>('getDeviceLabel');
      final trimmed = native?.trim() ?? '';
      if (trimmed.isNotEmpty) {
        label = trimmed;
      }
    } on PlatformException {
      // Keep the fallback.
    } on MissingPluginException {
      // Keep the fallback (tests, non-Android platforms).
    }
    if (label.length > maxLength) {
      label = label.substring(0, maxLength);
    }
    _cached = label;
    return label;
  }
}
