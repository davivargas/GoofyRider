import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:goofyrider_mobile/core/network/auth_token_interceptor.dart';

class MockErrorInterceptorHandler extends Mock
    implements ErrorInterceptorHandler {}

void main() {
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
}
