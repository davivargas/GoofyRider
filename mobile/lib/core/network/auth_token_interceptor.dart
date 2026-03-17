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
    final int? statusCode = err.response?.statusCode;
    final bool isRefreshPath = err.requestOptions.path.endsWith('/auth/refresh');

    if (statusCode != 401 || isRefreshPath) {
      handler.next(err);
      return;
    }

    final RequestOptions original = err.requestOptions;
    final bool alreadyRetried = original.extra['retry_after_refresh'] == true;
    if (alreadyRetried) {
      await _onAuthReset();
      handler.next(err);
      return;
    }

    final String? refreshToken = await _refreshTokenGetter();
    if (refreshToken == null || refreshToken.isEmpty) {
      await _onAuthReset();
      handler.next(err);
      return;
    }

    try {
      _refreshInFlight ??= _refreshCallback(refreshToken);
      final String? newAccessToken = await _refreshInFlight;
      _refreshInFlight = null;

      if (newAccessToken == null || newAccessToken.isEmpty) {
        await _onAuthReset();
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
      await _onAuthReset();
      handler.next(err);
    }
  }
}
