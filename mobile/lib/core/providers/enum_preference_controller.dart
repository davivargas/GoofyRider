import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/app_preferences.dart';

/// Persists an enum-valued preference through [AppPreferences].
/// [wireValues] maps each enum member to the string stored on disk.
class EnumPreferenceController<T extends Enum> extends StateNotifier<T> {
  EnumPreferenceController({
    required AppPreferences preferences,
    required String key,
    required T initial,
    required Map<T, String> wireValues,
  })  : _preferences = preferences,
        _key = key,
        _wireValues = wireValues,
        super(initial) {
    _restore();
  }

  final AppPreferences _preferences;
  final String _key;
  final Map<T, String> _wireValues;

  /// Completes after the stored value (if any) has been applied.
  /// Restoration is synchronous today, but callers await this so the store
  /// can become asynchronous without touching them.
  Future<void> get restored => Future<void>.value();

  Future<void> set(T value) async {
    if (state == value) {
      return;
    }
    state = value;
    final wire = _wireValues[value];
    if (wire != null) {
      await _preferences.setString(_key, wire);
    }
  }

  void _restore() {
    final raw = _preferences.getString(_key);
    if (raw == null) {
      return;
    }
    for (final entry in _wireValues.entries) {
      if (entry.value == raw) {
        state = entry.key;
        return;
      }
    }
  }
}
