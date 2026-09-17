import 'package:flutter_test/flutter_test.dart';

import 'package:fall_line_mobile/core/providers/enum_preference_controller.dart';
import 'package:fall_line_mobile/core/storage/app_preferences.dart';
import 'package:fall_line_mobile/core/utils/speed_unit.dart';

void main() {
  const wire = <SpeedUnit, String>{
    SpeedUnit.kilometersPerHour: 'kmh',
    SpeedUnit.metersPerSecond: 'mps',
    SpeedUnit.milesPerHour: 'mph',
  };

  test('restores a stored value on construction', () async {
    final prefs = AppPreferences.inMemory();
    await prefs.setString(AppPreferences.speedUnitKey, 'mph');

    final controller = EnumPreferenceController<SpeedUnit>(
      preferences: prefs,
      key: AppPreferences.speedUnitKey,
      initial: SpeedUnit.kilometersPerHour,
      wireValues: wire,
    );
    await controller.restored;

    expect(controller.state, SpeedUnit.milesPerHour);
  });

  test('set persists the wire value and updates state', () async {
    final prefs = AppPreferences.inMemory();
    final controller = EnumPreferenceController<SpeedUnit>(
      preferences: prefs,
      key: AppPreferences.speedUnitKey,
      initial: SpeedUnit.kilometersPerHour,
      wireValues: wire,
    );
    await controller.restored;

    await controller.set(SpeedUnit.metersPerSecond);

    expect(controller.state, SpeedUnit.metersPerSecond);
    expect(prefs.getString(AppPreferences.speedUnitKey), 'mps');
  });

  test('unknown stored value keeps the initial state', () async {
    final prefs = AppPreferences.inMemory();
    await prefs.setString(AppPreferences.speedUnitKey, 'furlongs');

    final controller = EnumPreferenceController<SpeedUnit>(
      preferences: prefs,
      key: AppPreferences.speedUnitKey,
      initial: SpeedUnit.kilometersPerHour,
      wireValues: wire,
    );
    await controller.restored;

    expect(controller.state, SpeedUnit.kilometersPerHour);
  });
}
