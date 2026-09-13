import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goofyrider_mobile/core/storage/app_preferences.dart';

class MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migrates legacy secure-storage values once and deletes them', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final legacy = MockSecureStorage();
    when(() => legacy.read(key: 'goofyrider_speed_unit'))
        .thenAnswer((_) async => 'mph');
    when(() => legacy.read(key: 'goofyrider_distance_unit'))
        .thenAnswer((_) async => null);
    when(() => legacy.read(key: 'gps_warmup.foreground_permission_requested'))
        .thenAnswer((_) async => 'true');
    when(() => legacy.delete(key: any(named: 'key'))).thenAnswer((_) async {});

    final prefs = await AppPreferences.load(legacyStorage: legacy);

    expect(prefs.getString(AppPreferences.speedUnitKey), 'mph');
    expect(prefs.getString(AppPreferences.distanceUnitKey), isNull);
    expect(prefs.getBool(AppPreferences.locationOnboardingSeenKey), isTrue);
    verify(() => legacy.delete(key: 'goofyrider_speed_unit')).called(1);
    verify(() =>
            legacy.delete(key: 'gps_warmup.foreground_permission_requested'))
        .called(1);

    final again = await AppPreferences.load(legacyStorage: legacy);
    expect(again.getString(AppPreferences.speedUnitKey), 'mph');
    // Exactly one read per legacy key across both loads: the second load is
    // short-circuited by the migrated flag.
    verify(() => legacy.read(key: 'goofyrider_distance_unit')).called(1);
  });

  test('load survives a secure storage that throws', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final legacy = MockSecureStorage();
    when(() => legacy.read(key: any(named: 'key')))
        .thenThrow(PlatformException(code: 'unavailable'));

    final prefs = await AppPreferences.load(legacyStorage: legacy);

    expect(prefs.getBool(AppPreferences.locationOnboardingSeenKey), isFalse);
  });

  test('a failed legacy read leaves migration pending for the next load',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final failing = MockSecureStorage();
    when(() => failing.read(key: any(named: 'key')))
        .thenThrow(PlatformException(code: 'unavailable'));

    final first = await AppPreferences.load(legacyStorage: failing);
    expect(first.getString(AppPreferences.speedUnitKey), isNull);

    final working = MockSecureStorage();
    when(() => working.read(key: 'goofyrider_speed_unit'))
        .thenAnswer((_) async => 'mph');
    when(() => working.read(key: 'goofyrider_distance_unit'))
        .thenAnswer((_) async => 'mi');
    when(() => working.read(key: 'gps_warmup.foreground_permission_requested'))
        .thenAnswer((_) async => 'true');
    when(() => working.delete(key: any(named: 'key'))).thenAnswer((_) async {});

    final second = await AppPreferences.load(legacyStorage: working);

    expect(second.getString(AppPreferences.speedUnitKey), 'mph');
    expect(second.getString(AppPreferences.distanceUnitKey), 'mi');
    expect(second.getBool(AppPreferences.locationOnboardingSeenKey), isTrue);
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
