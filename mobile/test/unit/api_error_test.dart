import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goofyrider_mobile/core/errors/failures.dart';
import 'package:goofyrider_mobile/core/network/api_error.dart';

DioException _exception({
  required int statusCode,
  Object? data,
  Map<String, List<String>> headers = const <String, List<String>>{},
}) {
  final options = RequestOptions(path: '/auth/login');
  return DioException(
    requestOptions: options,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: statusCode,
      data: data,
      headers: Headers.fromMap(headers),
    ),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  test('429 with detail maps to NetworkFailure carrying the server message',
      () {
    final failure = mapDioException(
      _exception(
        statusCode: 429,
        data: <String, dynamic>{
          'detail': 'Too many requests. Try again in 42 seconds.'
        },
        headers: <String, List<String>>{
          'retry-after': <String>['42']
        },
      ),
    );

    expect(failure, isA<NetworkFailure>());
    expect(failure.message, 'Too many requests. Try again in 42 seconds.');
  });

  test('429 without detail builds a message from Retry-After', () {
    final failure = mapDioException(
      _exception(
        statusCode: 429,
        headers: <String, List<String>>{
          'retry-after': <String>['7']
        },
      ),
    );

    expect(failure, isA<NetworkFailure>());
    expect(failure.message, 'Too many requests. Try again in 7 seconds.');
  });

  test('401 still maps to AuthFailure', () {
    final failure = mapDioException(
      _exception(
          statusCode: 401, data: <String, dynamic>{'detail': 'Invalid token.'}),
    );

    expect(failure, isA<AuthFailure>());
  });
}
