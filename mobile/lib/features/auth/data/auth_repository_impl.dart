import 'package:dio/dio.dart';

import '../../../core/errors/failures.dart';
import '../../../core/network/api_error.dart';
import '../../../core/storage/token_storage.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';
import 'auth_api.dart';
import 'auth_api_models.dart';
import 'device_label_provider.dart';

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl({
    required AuthApi authApi,
    required TokenStorage tokenStorage,
    DeviceLabelProvider? deviceLabelProvider,
  })  : _authApi = authApi,
        _tokenStorage = tokenStorage,
        _deviceLabelProvider = deviceLabelProvider ?? DeviceLabelProvider();

  final AuthApi _authApi;
  final TokenStorage _tokenStorage;
  final DeviceLabelProvider _deviceLabelProvider;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async {
    try {
      final tokenPayload = await _authApi.login(
        email: email.trim().toLowerCase(),
        password: password,
        deviceLabel: await _deviceLabelProvider.resolve(),
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
      final tokenPayload = await _authApi.register(
        email: email.trim().toLowerCase(),
        password: password,
        displayName: displayName.trim(),
        deviceLabel: await _deviceLabelProvider.resolve(),
      );
      return _hydrateAndPersistSession(tokenPayload);
    } on DioException catch (exception) {
      throw mapDioException(exception);
    }
  }

  @override
  Future<AuthSession?> restoreSession() async {
    final storedTokens = await _tokenStorage.read();
    if (storedTokens == null || !storedTokens.isValid) {
      return null;
    }

    try {
      return await _hydrateSessionFromAccessToken(
        accessToken: storedTokens.accessToken,
        refreshToken: storedTokens.refreshToken,
      );
    } on DioException catch (exception) {
      final allowOfflineFallback = _isConnectivityIssue(exception);
      if (allowOfflineFallback && storedTokens.hasCachedUserProfile) {
        return _sessionFromStoredTokens(storedTokens);
      }

      final TokenPairResponse? rotated;
      try {
        rotated = await _refreshTokenPair(storedTokens.refreshToken);
      } on AuthFailure {
        await _tokenStorage.clear();
        return null;
      }
      if (rotated == null) {
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
          accessToken: rotated.accessToken,
          refreshToken: rotated.refreshToken,
        );
      } on DioException catch (refreshException) {
        if (_isConnectivityIssue(refreshException) &&
            storedTokens.hasCachedUserProfile) {
          return _sessionFromStoredTokens(
            storedTokens,
            accessToken: rotated.accessToken,
            refreshToken: rotated.refreshToken,
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
    final tokens = await _tokenStorage.read();
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
    return (await _refreshTokenPair(refreshToken))?.accessToken;
  }

  /// Rotates the refresh token and persists the new pair.
  ///
  /// The backend revokes the presented refresh token, so callers must keep the
  /// returned pair and never re-send the token they passed in. Returns null on
  /// a transient failure; throws [AuthFailure] when the backend rejects the
  /// token with 401 (which also revokes the whole token family server-side).
  Future<TokenPairResponse?> _refreshTokenPair(String refreshToken) async {
    try {
      final payload = await _authApi.refresh(
        refreshToken: refreshToken,
        deviceLabel: await _deviceLabelProvider.resolve(),
      );
      final existing = await _tokenStorage.read();
      if (existing != null) {
        await _tokenStorage.write(
          StoredTokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            userId: existing.userId,
            email: existing.email,
            displayName: existing.displayName,
          ),
        );
      }
      return payload;
    } on DioException catch (exception) {
      if (exception.response?.statusCode == 401) {
        throw const AuthFailure('Session expired. Please sign in again.');
      }
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
    TokenPairResponse tokenPayload,
  ) async {
    final accessToken = tokenPayload.accessToken;
    final refreshToken = tokenPayload.refreshToken;

    await _tokenStorage.write(
      StoredTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      ),
    );

    final mePayload = await _authApi.me(accessToken: accessToken);
    final session = AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: UserProfile(
        id: mePayload.id,
        email: mePayload.email,
        displayName: mePayload.displayName,
      ),
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
    final mePayload = await _authApi.me(
      accessToken: accessToken,
    );
    final session = AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: UserProfile(
        id: mePayload.id,
        email: mePayload.email,
        displayName: mePayload.displayName,
      ),
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
    String? refreshToken,
  }) {
    return AuthSession(
      accessToken: accessToken ?? tokens.accessToken,
      refreshToken: refreshToken ?? tokens.refreshToken,
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
