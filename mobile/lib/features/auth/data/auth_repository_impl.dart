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
      return await _hydrateSessionFromAccessToken(
        accessToken: storedTokens.accessToken,
        refreshToken: storedTokens.refreshToken,
      );
    } on DioException catch (exception) {
      final bool allowOfflineFallback = _isConnectivityIssue(exception);
      if (allowOfflineFallback && storedTokens.hasCachedUserProfile) {
        return _sessionFromStoredTokens(storedTokens);
      }

      final String? newAccessToken =
          await refreshAccessToken(storedTokens.refreshToken);
      if (newAccessToken == null) {
        if (allowOfflineFallback) {
          return storedTokens.hasCachedUserProfile
              ? _sessionFromStoredTokens(storedTokens)
              : null;
        }
        await _tokenStorage.clear();
        return null;
      }

      try {
        return await _hydrateSessionFromAccessToken(
          accessToken: newAccessToken,
          refreshToken: storedTokens.refreshToken,
        );
      } on DioException catch (refreshException) {
        if (_isConnectivityIssue(refreshException) &&
            storedTokens.hasCachedUserProfile) {
          return _sessionFromStoredTokens(
            storedTokens,
            accessToken: newAccessToken,
          );
        }
        if (_isConnectivityIssue(refreshException)) {
          return null;
        }
        await _tokenStorage.clear();
        return null;
      }
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
            userId: existing.userId,
            email: existing.email,
            displayName: existing.displayName,
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

    await _tokenStorage.write(
      StoredTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      ),
    );

    final Map<String, dynamic> mePayload =
        await _authApi.me(accessToken: accessToken);
    final AuthSession session = AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: UserProfile.fromJson(mePayload),
    );

    await _tokenStorage.write(
      StoredTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        userId: session.user.id,
        email: session.user.email,
        displayName: session.user.displayName,
      ),
    );
    return session;
  }

  Future<AuthSession> _hydrateSessionFromAccessToken({
    required String accessToken,
    required String refreshToken,
  }) async {
    final Map<String, dynamic> mePayload = await _authApi.me(
      accessToken: accessToken,
    );
    final AuthSession session = AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: UserProfile.fromJson(mePayload),
    );

    await _tokenStorage.write(
      StoredTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        userId: session.user.id,
        email: session.user.email,
        displayName: session.user.displayName,
      ),
    );
    return session;
  }

  AuthSession _sessionFromStoredTokens(
    StoredTokens tokens, {
    String? accessToken,
  }) {
    return AuthSession(
      accessToken: accessToken ?? tokens.accessToken,
      refreshToken: tokens.refreshToken,
      user: UserProfile(
        id: tokens.userId!,
        email: tokens.email!,
        displayName: tokens.displayName!,
      ),
    );
  }

  bool _isConnectivityIssue(DioException exception) {
    return exception.type == DioExceptionType.connectionError ||
        exception.type == DioExceptionType.connectionTimeout ||
        exception.type == DioExceptionType.sendTimeout ||
        exception.type == DioExceptionType.receiveTimeout;
  }
}
