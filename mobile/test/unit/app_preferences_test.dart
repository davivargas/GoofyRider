import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fall_line_mobile/core/storage/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load reads values already in shared preferences', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPreferences.speedUnitKey: 'mph',
      AppPreferences.verticalUnitKey: 'ft',
      AppPreferences.distanceUnitKey: 'mi',
      AppPreferences.locationOnboardingSeenKey: true,
    });

    final prefs = await AppPreferences.load();

    expect(prefs.getString(AppPreferences.speedUnitKey), 'mph');
    expect(prefs.getString(AppPreferences.verticalUnitKey), 'ft');
    expect(prefs.getString(AppPreferences.distanceUnitKey), 'mi');
    expect(prefs.getBool(AppPreferences.locationOnboardingSeenKey), isTrue);
  });

  test('load round trips values written back', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final prefs = await AppPreferences.load();
    await prefs.setString(AppPreferences.distanceUnitKey, 'km');
    await prefs.setBool(AppPreferences.locationOnboardingSeenKey, true);

    expect(prefs.getString(AppPreferences.distanceUnitKey), 'km');
    expect(prefs.getBool(AppPreferences.locationOnboardingSeenKey), isTrue);
  });

  test('vertical and distance units are stored under separate keys', () {
    expect(AppPreferences.verticalUnitKey,
        isNot(equals(AppPreferences.distanceUnitKey)));
  });

  test('in-memory preferences round trip', () async {
    final prefs = AppPreferences.inMemory();
    await prefs.setString('k', 'v');
    await prefs.setBool('b', true);

    expect(prefs.getString('k'), 'v');
    expect(prefs.getBool('b'), isTrue);
    expect(prefs.getBool('missing'), isFalse);
  });
}
