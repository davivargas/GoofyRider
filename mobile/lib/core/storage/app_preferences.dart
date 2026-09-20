import 'package:shared_preferences/shared_preferences.dart';

/// Non-secret app preferences (units, onboarding flags). Backed by
/// `shared_preferences` in the app and by a map in tests. Credentials never
/// go here; they stay in `TokenStorage`.
class AppPreferences {
  AppPreferences._(this._store);

  factory AppPreferences.inMemory() => AppPreferences._(_MemoryStore());

  static const String speedUnitKey = 'speed_unit';

  /// Unit for vertical measurements (elevation loss, altitude).
  static const String verticalUnitKey = 'vertical_unit';

  /// Unit for horizontal distance travelled.
  static const String distanceUnitKey = 'distance_unit';
  static const String locationOnboardingSeenKey = 'location_onboarding_seen';

  final _PreferenceStore _store;

  static Future<AppPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppPreferences._(_SharedPreferencesStore(prefs));
  }

  String? getString(String key) => _store.getString(key);

  Future<void> setString(String key, String value) =>
      _store.setString(key, value);

  bool getBool(String key, {bool defaultValue = false}) =>
      _store.getBool(key) ?? defaultValue;

  Future<void> setBool(String key, bool value) => _store.setBool(key, value);
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
