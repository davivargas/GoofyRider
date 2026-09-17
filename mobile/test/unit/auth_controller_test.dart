import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:fall_line_mobile/core/errors/failures.dart';
import 'package:fall_line_mobile/features/auth/domain/auth_models.dart';
import 'package:fall_line_mobile/features/auth/domain/auth_repository.dart';
import 'package:fall_line_mobile/features/auth/presentation/auth_controller.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  const user = UserProfile(
    id: 'user-1',
    email: 'test@example.com',
    displayName: 'Tester',
  );
  const session = AuthSession(
    accessToken: 'access-0',
    refreshToken: 'refresh-0',
    user: user,
  );

  Future<AuthController> authenticatedController(
    MockAuthRepository repository,
  ) async {
    when(() => repository.restoreSession()).thenAnswer((_) async => session);
    final controller = AuthController(repository);
    await controller.bootstrap();
    expect(controller.state.status, AuthStatus.authenticated);
    return controller;
  }

  test('a transient refresh failure leaves the session authenticated',
      () async {
    final repository = MockAuthRepository();
    final controller = await authenticatedController(repository);
    when(() => repository.refreshAccessToken('refresh-0'))
        .thenAnswer((_) async => null);

    final refreshed = await controller.refreshAccessToken('refresh-0');

    expect(refreshed, isNull);
    expect(controller.state.status, AuthStatus.authenticated);
    expect(controller.state.session?.accessToken, 'access-0');
    expect(controller.state.session?.refreshToken, 'refresh-0');
  });

  test('a rejected refresh token unauthenticates and rethrows', () async {
    final repository = MockAuthRepository();
    final controller = await authenticatedController(repository);
    when(() => repository.refreshAccessToken('refresh-0')).thenThrow(
      const AuthFailure('Session expired. Please sign in again.'),
    );

    await expectLater(
      controller.refreshAccessToken('refresh-0'),
      throwsA(isA<AuthFailure>()),
    );
    expect(controller.state.status, AuthStatus.unauthenticated);
    expect(controller.state.session, isNull);
  });

  test('a successful refresh adopts the rotated refresh token', () async {
    final repository = MockAuthRepository();
    final controller = await authenticatedController(repository);
    when(() => repository.refreshAccessToken('refresh-0'))
        .thenAnswer((_) async => 'access-1');
    when(() => repository.currentRefreshToken())
        .thenAnswer((_) async => 'refresh-1');

    final refreshed = await controller.refreshAccessToken('refresh-0');

    expect(refreshed, 'access-1');
    expect(controller.state.status, AuthStatus.authenticated);
    expect(controller.state.session?.accessToken, 'access-1');
    expect(controller.state.session?.refreshToken, 'refresh-1');
  });
}
