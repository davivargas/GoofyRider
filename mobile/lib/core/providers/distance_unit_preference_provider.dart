import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/distance_unit.dart';

const String _distanceUnitStorageKey = 'goofyrider_distance_unit';
const String _distanceUnitMetersValue = 'm';
const String _distanceUnitFeetValue = 'ft';

class DistanceUnitPreferenceController extends StateNotifier<DistanceUnit> {
  DistanceUnitPreferenceController({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(),
        super(DistanceUnit.meters) {
    unawaited(_restorePreference());
  }

  final FlutterSecureStorage _storage;

  Future<void> setDistanceUnit(DistanceUnit unit) async {
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

    final DistanceUnit? parsed = _decode(rawValue);
    if (parsed != null) {
      state = parsed;
    }
  }

  DistanceUnit? _decode(String value) {
    switch (value) {
      case _distanceUnitMetersValue:
        return DistanceUnit.meters;
      case _distanceUnitFeetValue:
        return DistanceUnit.feet;
      default:
        return null;
    }
  }

  String _encode(DistanceUnit unit) {
    switch (unit) {
      case DistanceUnit.meters:
        return _distanceUnitMetersValue;
      case DistanceUnit.feet:
        return _distanceUnitFeetValue;
    }
  }

  Future<String?> _readSafe() async {
    try {
      return _storage.read(key: _distanceUnitStorageKey);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _writeSafe(String value) async {
    try {
      await _storage.write(key: _distanceUnitStorageKey, value: value);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}

final distanceUnitPreferenceProvider =
    StateNotifierProvider<DistanceUnitPreferenceController, DistanceUnit>(
  (Ref ref) => DistanceUnitPreferenceController(),
);
