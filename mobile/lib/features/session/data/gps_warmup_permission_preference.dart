import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists whether the app has already asked for foreground location
/// permission at startup. The warmup flow should only prompt once; after that
/// the user's decision is respected until they reinstall or clear storage.
class GpsWarmupPermissionPreference {
  GpsWarmupPermissionPreference({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _key = 'gps_warmup.foreground_permission_requested';

  final FlutterSecureStorage _storage;

  Future<bool> hasBeenRequested() async {
    try {
      final value = await _storage.read(key: _key);
      return value == 'true';
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> markRequested() async {
    try {
      await _storage.write(key: _key, value: 'true');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}
