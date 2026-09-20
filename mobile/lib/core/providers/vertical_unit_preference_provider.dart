import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../storage/app_preferences.dart';
import '../utils/vertical_unit.dart';
import 'enum_preference_controller.dart';

const Map<VerticalUnit, String> verticalUnitWireValues = <VerticalUnit, String>{
  VerticalUnit.meters: 'm',
  VerticalUnit.feet: 'ft',
};

class VerticalUnitPreferenceController
    extends EnumPreferenceController<VerticalUnit> {
  VerticalUnitPreferenceController({required super.preferences})
      : super(
          key: AppPreferences.verticalUnitKey,
          initial: VerticalUnit.meters,
          wireValues: verticalUnitWireValues,
        );

  Future<void> setVerticalUnit(VerticalUnit unit) => set(unit);
}

final verticalUnitPreferenceProvider =
    StateNotifierProvider<VerticalUnitPreferenceController, VerticalUnit>(
  (Ref ref) => VerticalUnitPreferenceController(
    preferences: ref.watch(appPreferencesProvider),
  ),
);
