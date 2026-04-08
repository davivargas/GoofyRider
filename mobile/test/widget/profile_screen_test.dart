import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/providers/distance_unit_preference_provider.dart';
import 'package:goofyrider_mobile/core/providers/speed_unit_preference_provider.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_models.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_repository.dart';
import 'package:goofyrider_mobile/features/auth/presentation/auth_controller.dart';
import 'package:goofyrider_mobile/features/auth/presentation/auth_providers.dart';
import 'package:goofyrider_mobile/features/profile/presentation/profile_screen.dart';

class _FakeAuthRepository implements AuthRepository {
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
      : super(_FakeAuthRepository()) {
    state = initialState;
  }
}

void main() {
  testWidgets('export debug info shows success snackbar when export completes',
      (WidgetTester tester) async {
    final AuthState authState = AuthState(
      status: AuthStatus.authenticated,
      session: AuthSession(
        accessToken: 'access',
        refreshToken: 'refresh',
        user: const UserProfile(
          id: 'user-1',
          email: 'rider@example.com',
          displayName: 'Rider',
        ),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider
              .overrideWith((_) => _FakeAuthController(initialState: authState)),
          speedUnitPreferenceProvider
              .overrideWith((_) => SpeedUnitPreferenceController()),
          distanceUnitPreferenceProvider
              .overrideWith((_) => DistanceUnitPreferenceController()),
          debugExportActionProvider.overrideWithValue(
            ({
              required String ownerUserId,
              required String? userEmail,
              required speedUnit,
              required distanceUnit,
            }) async => r'C:\tmp\goofyrider_debug.json',
          ),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.tap(find.text('Export debug info'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Debug info exported to'), findsOneWidget);
    expect(find.textContaining(r'C:\tmp\goofyrider_debug.json'), findsOneWidget);
  });

  testWidgets('export debug info shows sign-in snackbar when signed out',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider.overrideWith(
            (_) => _FakeAuthController(
              initialState: const AuthState(status: AuthStatus.unauthenticated),
            ),
          ),
          speedUnitPreferenceProvider
              .overrideWith((_) => SpeedUnitPreferenceController()),
          distanceUnitPreferenceProvider
              .overrideWith((_) => DistanceUnitPreferenceController()),
          debugExportActionProvider.overrideWithValue(
            ({
              required String ownerUserId,
              required String? userEmail,
              required speedUnit,
              required distanceUnit,
            }) async => r'C:\tmp\should_not_be_used.json',
          ),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.tap(find.text('Export debug info'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to export debug info.'), findsOneWidget);
  });

  testWidgets('export debug info shows failure snackbar on export error',
      (WidgetTester tester) async {
    final AuthState authState = AuthState(
      status: AuthStatus.authenticated,
      session: AuthSession(
        accessToken: 'access',
        refreshToken: 'refresh',
        user: const UserProfile(
          id: 'user-1',
          email: 'rider@example.com',
          displayName: 'Rider',
        ),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider
              .overrideWith((_) => _FakeAuthController(initialState: authState)),
          speedUnitPreferenceProvider
              .overrideWith((_) => SpeedUnitPreferenceController()),
          distanceUnitPreferenceProvider
              .overrideWith((_) => DistanceUnitPreferenceController()),
          debugExportActionProvider.overrideWithValue(
            ({
              required String ownerUserId,
              required String? userEmail,
              required speedUnit,
              required distanceUnit,
            }) async => throw Exception('disk full'),
          ),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.tap(find.text('Export debug info'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Debug export failed:'), findsOneWidget);
    expect(find.textContaining('disk full'), findsOneWidget);
  });
}
