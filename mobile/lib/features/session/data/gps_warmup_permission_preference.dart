import '../../../core/storage/app_preferences.dart';

/// Persists whether the app has already asked for foreground location
/// permission at startup. The warm-up flow should only prompt once.
class GpsWarmupPermissionPreference {
  GpsWarmupPermissionPreference(this._preferences);

  final AppPreferences _preferences;

  Future<bool> hasBeenRequested() async =>
      _preferences.getBool(AppPreferences.locationOnboardingSeenKey);

  Future<void> markRequested() =>
      _preferences.setBool(AppPreferences.locationOnboardingSeenKey, true);
}
