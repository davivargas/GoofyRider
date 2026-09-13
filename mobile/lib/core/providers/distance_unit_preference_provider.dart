import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../storage/app_preferences.dart';
import '../utils/distance_unit.dart';
import 'enum_preference_controller.dart';

const Map<DistanceUnit, String> distanceUnitWireValues = <DistanceUnit, String>{
  DistanceUnit.meters: 'm',
  DistanceUnit.feet: 'ft',
};

class DistanceUnitPreferenceController
    extends EnumPreferenceController<DistanceUnit> {
  DistanceUnitPreferenceController({required super.preferences})
      : super(
          key: AppPreferences.distanceUnitKey,
          initial: DistanceUnit.meters,
          wireValues: distanceUnitWireValues,
        );

  Future<void> setDistanceUnit(DistanceUnit unit) => set(unit);
}

final distanceUnitPreferenceProvider =
    StateNotifierProvider<DistanceUnitPreferenceController, DistanceUnit>(
  (Ref ref) => DistanceUnitPreferenceController(
    preferences: ref.watch(appPreferencesProvider),
  ),
);
