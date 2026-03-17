import 'auth_models.dart';

abstract class AuthRepository {
  Future<AuthSession> login({
    required String email,
    required String password,
  });

  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  });

  Future<AuthSession?> restoreSession();
  Future<void> logout();
  Future<String?> refreshAccessToken(String refreshToken);
  Future<String?> currentAccessToken();
  Future<String?> currentRefreshToken();
}
