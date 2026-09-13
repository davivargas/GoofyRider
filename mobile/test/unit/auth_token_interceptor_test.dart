import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:goofyrider_mobile/core/errors/failures.dart';
import 'package:goofyrider_mobile/core/network/auth_token_interceptor.dart';

class MockErrorInterceptorHandler extends Mock
    implements ErrorInterceptorHandler {}

/// Answers every retried request with 200 so no test touches the network.
class _StubHttpAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString('{}', 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      Response<dynamic>(requestOptions: RequestOptions(path: '/')),
    );
  });

  test('does not force logout for preserved session sync failures', () async {
    var authResetCalled = false;
    final interceptor = AuthTokenInterceptor(
      dio: Dio(),
      accessTokenGetter: () async => 'access-token',
      refreshTokenGetter: () async => 'refresh-token',
      refreshCallback: (_) async => null,
      onAuthReset: () async {
        authResetCalled = true;
      },
    );
    final handler = MockErrorInterceptorHandler();
    final requestOptions = RequestOptions(
      path: '/sessions/remote-1/points:batch',
      extra: <String, dynamic>{
        AuthTokenInterceptor.preserveAuthOnFailureExtraKey: true,
      },
    );
    final exception = DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 401,
        data: <String, dynamic>{'detail': 'Authentication required.'},
      ),
      type: DioExceptionType.badResponse,
    );

    await interceptor.onError(exception, handler);

    verify(() => handler.next(exception)).called(1);
    expect(authResetCalled, isFalse);
  });

  test(
      'resets auth when refresh reports a revoked token even for preserved requests',
      () async {
    var authResetCalled = false;
    final interceptor = AuthTokenInterceptor(
      dio: Dio(),
      accessTokenGetter: () async => 'access-token',
      refreshTokenGetter: () async => 'refresh-token',
      refreshCallback: (_) async =>
          throw const AuthFailure('Session expired. Please sign in again.'),
      onAuthReset: () async {
        authResetCalled = true;
      },
    );
    final handler = MockErrorInterceptorHandler();
    final requestOptions = RequestOptions(
      path: '/sessions/remote-1/points:batch',
      extra: <String, dynamic>{
        AuthTokenInterceptor.preserveAuthOnFailureExtraKey: true,
        AuthTokenInterceptor.retryPreservedAuthOnUnauthorizedExtraKey: true,
      },
    );
    final exception = DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 401,
        data: <String, dynamic>{'detail': 'Authentication required.'},
      ),
      type: DioExceptionType.badResponse,
    );

    await interceptor.onError(exception, handler);

    verify(() => handler.next(exception)).called(1);
    expect(authResetCalled, isTrue);
  });

  test('concurrent 401s read and send the refresh token exactly once',
      () async {
    final dio = Dio()..httpClientAdapter = _StubHttpAdapter();
    final gate = Completer<void>();
    var refreshTokenReads = 0;
    var refreshCallbackCalls = 0;
    final interceptor = AuthTokenInterceptor(
      dio: dio,
      accessTokenGetter: () async => 'access-token',
      refreshTokenGetter: () async {
        refreshTokenReads += 1;
        await gate.future;
        return 'refresh-token';
      },
      refreshCallback: (_) async {
        refreshCallbackCalls += 1;
        return 'new-access-token';
      },
      onAuthReset: () async {},
    );

    DioException unauthorized() {
      final requestOptions = RequestOptions(
        path: '/sessions',
        baseUrl: 'https://example.invalid/v1',
      );
      return DioException(
        requestOptions: requestOptions,
        response: Response<dynamic>(
          requestOptions: requestOptions,
          statusCode: 401,
        ),
        type: DioExceptionType.badResponse,
      );
    }

    final firstHandler = MockErrorInterceptorHandler();
    final secondHandler = MockErrorInterceptorHandler();
    final first = interceptor.onError(unauthorized(), firstHandler);
    final second = interceptor.onError(unauthorized(), secondHandler);
    gate.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(refreshTokenReads, 1);
    expect(refreshCallbackCalls, 1);
    verify(() => firstHandler.resolve(any<Response<dynamic>>())).called(1);
    verify(() => secondHandler.resolve(any<Response<dynamic>>())).called(1);
  });
}
