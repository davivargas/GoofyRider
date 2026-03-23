import 'dart:async';

import 'package:dio/dio.dart';

typedef AccessTokenGetter = Future<String?> Function();
typedef RefreshTokenGetter = Future<String?> Function();
typedef TokenRefreshCallback = Future<String?> Function(String refreshToken);
typedef AuthResetCallback = Future<void> Function();

class AuthTokenInterceptor extends Interceptor {
  AuthTokenInterceptor({
    required Dio dio,
    required AccessTokenGetter accessTokenGetter,
    required RefreshTokenGetter refreshTokenGetter,
    required TokenRefreshCallback refreshCallback,
    required AuthResetCallback onAuthReset,
  })  : _dio = dio,
        _accessTokenGetter = accessTokenGetter,
        _refreshTokenGetter = refreshTokenGetter,
        _refreshCallback = refreshCallback,
        _onAuthReset = onAuthReset;

  /// Keeps a request failure from clearing local auth state immediately.
  ///
  /// This is used for flows that can tolerate a surfaced server failure while
  /// the app waits for the next authenticated retry opportunity.
  static const String preserveAuthOnFailureExtraKey =
      'preserve_auth_on_failure';
  /// Opts a preserved-auth request into a single retry after token refresh even
  /// when the original HTTP method is not inherently idempotent.
  static const String retryPreservedAuthOnUnauthorizedExtraKey =
      'retry_preserved_auth_on_unauthorized';

  final Dio _dio;
  final AccessTokenGetter _accessTokenGetter;
  final RefreshTokenGetter _refreshTokenGetter;
  final TokenRefreshCallback _refreshCallback;
  final AuthResetCallback _onAuthReset;

  Future<String?>? _refreshInFlight;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final String? token = await _accessTokenGetter();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final RequestOptions original = err.requestOptions;
    final int? statusCode = err.response?.statusCode;
    final bool isRefreshPath = original.path.endsWith('/auth/refresh');
    final bool preserveAuthOnFailure =
        original.extra[preserveAuthOnFailureExtraKey] == true;

    if (statusCode != 401 || isRefreshPath) {
      handler.next(err);
      return;
    }

    if (preserveAuthOnFailure && !_canRetryPreservedAuthFailure(original)) {
      handler.next(err);
      return;
    }

    final bool alreadyRetried = original.extra['retry_after_refresh'] == true;
    if (alreadyRetried) {
      await _resetAuthIfNeeded(preserveAuthOnFailure);
      handler.next(err);
      return;
    }

    final String? refreshToken = await _refreshTokenGetter();
    if (refreshToken == null || refreshToken.isEmpty) {
      await _resetAuthIfNeeded(preserveAuthOnFailure);
      handler.next(err);
      return;
    }

    try {
      _refreshInFlight ??= _refreshCallback(refreshToken);
      final String? newAccessToken = await _refreshInFlight;
      _refreshInFlight = null;

      if (newAccessToken == null || newAccessToken.isEmpty) {
        await _resetAuthIfNeeded(preserveAuthOnFailure);
        handler.next(err);
        return;
      }

      final RequestOptions cloned = original.copyWith(
        headers: <String, dynamic>{
          ...original.headers,
          'Authorization': 'Bearer $newAccessToken',
        },
        extra: <String, dynamic>{
          ...original.extra,
          'retry_after_refresh': true,
        },
      );

      final Response<dynamic> response = await _dio.fetch(cloned);
      handler.resolve(response);
    } catch (_) {
      _refreshInFlight = null;
      await _resetAuthIfNeeded(preserveAuthOnFailure);
      handler.next(err);
    }
  }

  /// Limits preserved-auth refresh retries to safe methods unless a caller
  /// explicitly opts in for one replay on `401 Unauthorized`.
  bool _canRetryPreservedAuthFailure(RequestOptions options) {
    if (options.extra[retryPreservedAuthOnUnauthorizedExtraKey] == true) {
      return true;
    }

    switch (options.method.toUpperCase()) {
      case 'GET':
      case 'HEAD':
      case 'OPTIONS':
        return true;
      default:
        return false;
    }
  }

  Future<void> _resetAuthIfNeeded(bool preserveAuthOnFailure) async {
    if (preserveAuthOnFailure) {
      return;
    }
    await _onAuthReset();
  }
}
