import 'package:dio/dio.dart';

import '../../../core/network/api_error.dart';
import '../../../core/storage/token_storage.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';
import 'auth_api.dart';

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl({
    required AuthApi authApi,
    required TokenStorage tokenStorage,
  })  : _authApi = authApi,
        _tokenStorage = tokenStorage;

  final AuthApi _authApi;
  final TokenStorage _tokenStorage;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async {
    try {
      final Map<String, dynamic> tokenPayload = await _authApi.login(
        email: email.trim().toLowerCase(),
        password: password,
      );
      return _hydrateAndPersistSession(tokenPayload);
    } on DioException catch (exception) {
      throw mapDioException(exception);
    }
  }

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final Map<String, dynamic> tokenPayload = await _authApi.register(
        email: email.trim().toLowerCase(),
        password: password,
        displayName: displayName.trim(),
      );
      return _hydrateAndPersistSession(tokenPayload);
    } on DioException catch (exception) {
      throw mapDioException(exception);
    }
  }

  @override
  Future<AuthSession?> restoreSession() async {
    final StoredTokens? storedTokens = await _tokenStorage.read();
    if (storedTokens == null || !storedTokens.isValid) {
      return null;
    }

    try {
      final Map<String, dynamic> mePayload = await _authApi.me(
        accessToken: storedTokens.accessToken,
      );
      return AuthSession(
        accessToken: storedTokens.accessToken,
        refreshToken: storedTokens.refreshToken,
        user: UserProfile.fromJson(mePayload),
      );
    } on DioException {
      final String? newAccessToken =
          await refreshAccessToken(storedTokens.refreshToken);
      if (newAccessToken == null) {
        await _tokenStorage.clear();
        return null;
      }

      final Map<String, dynamic> mePayload =
          await _authApi.me(accessToken: newAccessToken);
      final AuthSession session = AuthSession(
        accessToken: newAccessToken,
        refreshToken: storedTokens.refreshToken,
        user: UserProfile.fromJson(mePayload),
      );
      await _tokenStorage.write(
        StoredTokens(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
        ),
      );
      return session;
    }
  }

  @override
  Future<void> logout() async {
    final StoredTokens? tokens = await _tokenStorage.read();
    if (tokens != null) {
      try {
        await _authApi.logout(refreshToken: tokens.refreshToken);
      } on DioException {
        // Stateless backend logout in v1. Local clear is authoritative.
      }
    }
    await _tokenStorage.clear();
  }

  @override
  Future<String?> refreshAccessToken(String refreshToken) async {
    try {
      final Map<String, dynamic> payload =
          await _authApi.refresh(refreshToken: refreshToken);
      final String accessToken = payload['access_token'] as String;
      final StoredTokens? existing = await _tokenStorage.read();
      if (existing != null) {
        await _tokenStorage.write(
          StoredTokens(
            accessToken: accessToken,
            refreshToken:
                payload['refresh_token'] as String? ?? existing.refreshToken,
          ),
        );
      }
      return accessToken;
    } on DioException {
      return null;
    }
  }

  @override
  Future<String?> currentAccessToken() async {
    return (await _tokenStorage.read())?.accessToken;
  }

  @override
  Future<String?> currentRefreshToken() async {
    return (await _tokenStorage.read())?.refreshToken;
  }

  Future<AuthSession> _hydrateAndPersistSession(
    Map<String, dynamic> tokenPayload,
  ) async {
    final String accessToken = tokenPayload['access_token'] as String;
    final String refreshToken = tokenPayload['refresh_token'] as String;

    final Map<String, dynamic> mePayload =
        await _authApi.me(accessToken: accessToken);
    final AuthSession session = AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: UserProfile.fromJson(mePayload),
    );

    await _tokenStorage.write(
      StoredTokens(accessToken: accessToken, refreshToken: refreshToken),
    );
    return session;
  }
}
