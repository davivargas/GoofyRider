import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fall_line_mobile/app/theme/app_theme.dart';
import 'package:fall_line_mobile/features/auth/domain/auth_models.dart';
import 'package:fall_line_mobile/features/auth/domain/auth_repository.dart';
import 'package:fall_line_mobile/features/auth/presentation/auth_providers.dart';
import 'package:fall_line_mobile/features/auth/presentation/login_screen.dart';
import 'package:fall_line_mobile/core/constants/app_constants.dart';

class FakeAuthRepository implements AuthRepository {
  @override
  Future<String?> currentAccessToken() async => null;

  @override
  Future<String?> currentRefreshToken() async => null;

  @override
  Future<AuthSession> login(
      {required String email, required String password}) async {
    return const AuthSession(
      accessToken: 'access',
      refreshToken: 'refresh',
      user: UserProfile(
          id: '1', email: 'test@example.com', displayName: 'Tester'),
    );
  }

  @override
  Future<void> logout() async {}

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<String?> refreshAccessToken(String refreshToken) async => null;

  @override
  Future<AuthSession?> restoreSession() async => null;
}

void main() {
  testWidgets('login form renders and validates empty input',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        ],
        child: MaterialApp(theme: AppTheme.dark(), home: const LoginScreen()),
      ),
    );

    expect(find.textContaining(AppConstants.brandWordmark), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));

    await tester.tap(find.text('LOG IN'));
    await tester.pump();

    expect(find.text('Email is required.'), findsOneWidget);
    expect(find.text('Password is required.'), findsOneWidget);
  });
}
