import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fall_line_mobile/app/theme/app_theme.dart';
import 'package:fall_line_mobile/core/constants/app_constants.dart';
import 'package:fall_line_mobile/core/providers.dart';
import 'package:fall_line_mobile/core/providers/distance_unit_preference_provider.dart';
import 'package:fall_line_mobile/core/providers/vertical_unit_preference_provider.dart';
import 'package:fall_line_mobile/core/providers/speed_unit_preference_provider.dart';
import 'package:fall_line_mobile/core/storage/app_preferences.dart';
import 'package:fall_line_mobile/features/auth/domain/auth_models.dart';
import 'package:fall_line_mobile/features/auth/domain/auth_repository.dart';
import 'package:fall_line_mobile/features/auth/presentation/auth_controller.dart';
import 'package:fall_line_mobile/features/auth/presentation/auth_providers.dart';
import 'package:fall_line_mobile/features/profile/presentation/profile_screen.dart';

class _FakeAuthRepository implements AuthRepository {
  const _FakeAuthRepository();

  @override
  Future<String?> currentAccessToken() async => 'access';

  @override
  Future<String?> currentRefreshToken() async => 'refresh';

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() async {}

  @override
  Future<String?> refreshAccessToken(String refreshToken) async => 'access';

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession?> restoreSession() async => null;
}

class _FakeAuthController extends AuthController {
  _FakeAuthController({required AuthState initialState})
      : super(const _FakeAuthRepository()) {
    state = initialState;
  }
}

void main() {
  testWidgets('shows the OpenSkiData attribution', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (_) => _FakeAuthController(
              initialState: const AuthState(status: AuthStatus.unauthenticated),
            ),
          ),
          speedUnitPreferenceProvider.overrideWith((_) =>
              SpeedUnitPreferenceController(
                  preferences: AppPreferences.inMemory())),
          distanceUnitPreferenceProvider.overrideWith((_) =>
              DistanceUnitPreferenceController(
                  preferences: AppPreferences.inMemory())),
          verticalUnitPreferenceProvider.overrideWith((_) =>
              VerticalUnitPreferenceController(
                  preferences: AppPreferences.inMemory())),
          activeMapTileProviderConfigProvider
              .overrideWithValue(MapTileProviderConfig.devFallback),
          debugExportActionProvider.overrideWithValue(
            ({
              required String ownerUserId,
              required String? userEmail,
              required speedUnit,
              required verticalUnit,
              required distanceUnit,
            }) async =>
                r'C:\tmp\goofyrider_debug.json',
          ),
        ],
        child: MaterialApp(theme: AppTheme.dark(), home: const ProfileScreen()),
      ),
    );

    await tester.scrollUntilVisible(
      find.text(CatalogAttribution.openSkiData),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(CatalogAttribution.openSkiData), findsOneWidget);
  });

  testWidgets('units card offers separate vertical and distance toggles',
      (WidgetTester tester) async {
    final preferences = AppPreferences.inMemory();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (_) => _FakeAuthController(
              initialState: const AuthState(status: AuthStatus.unauthenticated),
            ),
          ),
          appPreferencesProvider.overrideWithValue(preferences),
          activeMapTileProviderConfigProvider
              .overrideWithValue(MapTileProviderConfig.devFallback),
          debugExportActionProvider.overrideWithValue(
            ({
              required String ownerUserId,
              required String? userEmail,
              required speedUnit,
              required verticalUnit,
              required distanceUnit,
            }) async =>
                r'C:	mp\goofyrider_debug.json',
          ),
        ],
        child: MaterialApp(theme: AppTheme.dark(), home: const ProfileScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Vertical'), findsOneWidget);
    expect(find.text('Distance'), findsOneWidget);
    // Vertical keeps m/ft; distance is the new km/mi choice.
    expect(find.text('M'), findsOneWidget);
    expect(find.text('FT'), findsOneWidget);
    expect(find.text('KM'), findsOneWidget);
    expect(find.text('MI'), findsOneWidget);

    await tester.tap(find.text('MI'));
    await tester.pumpAndSettle();

    expect(preferences.getString(AppPreferences.distanceUnitKey), 'mi');
    expect(preferences.getString(AppPreferences.verticalUnitKey), isNull);
  });
}
