import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../storage/app_preferences.dart';
import '../utils/speed_unit.dart';
import 'enum_preference_controller.dart';

const Map<SpeedUnit, String> speedUnitWireValues = <SpeedUnit, String>{
  SpeedUnit.kilometersPerHour: 'kmh',
  SpeedUnit.metersPerSecond: 'mps',
  SpeedUnit.milesPerHour: 'mph',
};

class SpeedUnitPreferenceController
    extends EnumPreferenceController<SpeedUnit> {
  SpeedUnitPreferenceController({required super.preferences})
      : super(
          key: AppPreferences.speedUnitKey,
          initial: SpeedUnit.kilometersPerHour,
          wireValues: speedUnitWireValues,
        );

  Future<void> setSpeedUnit(SpeedUnit unit) => set(unit);
}

final speedUnitPreferenceProvider =
    StateNotifierProvider<SpeedUnitPreferenceController, SpeedUnit>(
  (Ref ref) => SpeedUnitPreferenceController(
    preferences: ref.watch(appPreferencesProvider),
  ),
);
