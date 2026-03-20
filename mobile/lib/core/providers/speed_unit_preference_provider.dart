import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/speed_unit.dart';

const String _speedUnitStorageKey = 'goofyrider_speed_unit';
const String _speedUnitKmhValue = 'kmh';
const String _speedUnitMpsValue = 'mps';
const String _speedUnitMphValue = 'mph';

class SpeedUnitPreferenceController extends StateNotifier<SpeedUnit> {
  SpeedUnitPreferenceController({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(),
        super(SpeedUnit.kilometersPerHour) {
    unawaited(_restorePreference());
  }

  final FlutterSecureStorage _storage;

  Future<void> setSpeedUnit(SpeedUnit unit) async {
    if (state == unit) {
      return;
    }

    state = unit;
    await _writeSafe(_encode(unit));
  }

  Future<void> _restorePreference() async {
    final String? rawValue = await _readSafe();
    if (rawValue == null) {
      return;
    }

    final SpeedUnit? parsed = _decode(rawValue);
    if (parsed != null) {
      state = parsed;
    }
  }

  SpeedUnit? _decode(String value) {
    switch (value) {
      case _speedUnitKmhValue:
        return SpeedUnit.kilometersPerHour;
      case _speedUnitMpsValue:
        return SpeedUnit.metersPerSecond;
      case _speedUnitMphValue:
        return SpeedUnit.milesPerHour;
      default:
        return null;
    }
  }

  String _encode(SpeedUnit unit) {
    switch (unit) {
      case SpeedUnit.kilometersPerHour:
        return _speedUnitKmhValue;
      case SpeedUnit.metersPerSecond:
        return _speedUnitMpsValue;
      case SpeedUnit.milesPerHour:
        return _speedUnitMphValue;
    }
  }

  Future<String?> _readSafe() async {
    try {
      return _storage.read(key: _speedUnitStorageKey);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _writeSafe(String value) async {
    try {
      await _storage.write(key: _speedUnitStorageKey, value: value);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}

final speedUnitPreferenceProvider =
    StateNotifierProvider<SpeedUnitPreferenceController, SpeedUnit>(
  (Ref ref) => SpeedUnitPreferenceController(),
);
