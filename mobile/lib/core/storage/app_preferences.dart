import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-secret app preferences (units, onboarding flags). Backed by
/// `shared_preferences` in the app and by a map in tests. Credentials never
/// go here; they stay in `TokenStorage`.
class AppPreferences {
  AppPreferences._(this._store);

  factory AppPreferences.inMemory() => AppPreferences._(_MemoryStore());

  static const String speedUnitKey = 'speed_unit';
  static const String distanceUnitKey = 'distance_unit';
  static const String locationOnboardingSeenKey = 'location_onboarding_seen';
  static const String _legacyMigratedKey = 'legacy_secure_prefs_migrated';

  /// Legacy secure-storage keys (left side) and the preference key each one
  /// migrates into. Values are copied verbatim; `'true'` becomes a bool.
  static const Map<String, String> _legacyKeys = <String, String>{
    'goofyrider_speed_unit': speedUnitKey,
    'goofyrider_distance_unit': distanceUnitKey,
    'gps_warmup.foreground_permission_requested': locationOnboardingSeenKey,
  };

  final _PreferenceStore _store;

  static Future<AppPreferences> load({
    FlutterSecureStorage? legacyStorage,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final instance = AppPreferences._(_SharedPreferencesStore(prefs));
    await instance
        ._migrateLegacy(legacyStorage ?? const FlutterSecureStorage());
    return instance;
  }

  String? getString(String key) => _store.getString(key);

  Future<void> setString(String key, String value) =>
      _store.setString(key, value);

  bool getBool(String key, {bool defaultValue = false}) =>
      _store.getBool(key) ?? defaultValue;

  Future<void> setBool(String key, bool value) => _store.setBool(key, value);

  Future<void> _migrateLegacy(FlutterSecureStorage legacy) async {
    if (_store.getBool(_legacyMigratedKey) ?? false) {
      return;
    }
    for (final entry in _legacyKeys.entries) {
      String? value;
      try {
        value = await legacy.read(key: entry.key);
      } on PlatformException {
        continue;
      } on MissingPluginException {
        continue;
      }
      if (value == null) {
        continue;
      }
      if (entry.value == locationOnboardingSeenKey) {
        await _store.setBool(entry.value, value == 'true');
      } else {
        await _store.setString(entry.value, value);
      }
      try {
        await legacy.delete(key: entry.key);
      } on PlatformException {
        // Best effort; the migrated flag below stops repeat attempts.
      } on MissingPluginException {
        // Same.
      }
    }
    await _store.setBool(_legacyMigratedKey, true);
  }
}

abstract class _PreferenceStore {
  String? getString(String key);
  bool? getBool(String key);
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
}

class _SharedPreferencesStore implements _PreferenceStore {
  _SharedPreferencesStore(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);
  @override
  bool? getBool(String key) => _prefs.getBool(key);
  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
  @override
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);
}

class _MemoryStore implements _PreferenceStore {
  final Map<String, Object> _values = <String, Object>{};

  @override
  String? getString(String key) => _values[key] as String?;
  @override
  bool? getBool(String key) => _values[key] as bool?;
  @override
  Future<void> setString(String key, String value) async =>
      _values[key] = value;
  @override
  Future<void> setBool(String key, bool value) async => _values[key] = value;
}
