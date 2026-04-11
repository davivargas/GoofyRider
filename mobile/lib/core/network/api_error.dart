import 'package:dio/dio.dart';

import '../errors/failures.dart';

AppFailure mapDioException(DioException exception) {
  final Object? payload = exception.response?.data;
  final String? machineMessage = _extractMessage(payload);
  final String fallback = exception.message ?? 'Network request failed.';
  final int? statusCode = exception.response?.statusCode;
  final String? timeoutMessage = _timeoutFriendlyMessage(exception);
  final String? connectionMessage = _connectionFriendlyMessage(exception);

  if (statusCode == 401) {
    return AuthFailure(machineMessage ?? 'Authentication required.',
        details: payload);
  }

  return NetworkFailure(
    machineMessage ?? timeoutMessage ?? connectionMessage ?? fallback,
    details: payload,
  );
}

String? _extractMessage(Object? payload) {
  if (payload is Map<String, dynamic>) {
    final Object? errorNode = payload['error'];
    if (errorNode is Map<String, dynamic>) {
      final Object? message = errorNode['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }

    final Object? detail = payload['detail'];
    if (detail is String && detail.isNotEmpty) {
      return detail;
    }
    if (detail is List) {
      for (final Object? item in detail) {
        if (item is Map<String, dynamic>) {
          final Object? message = item['msg'];
          if (message is String && message.isNotEmpty) {
            return message;
          }
        }
        if (item is String && item.isNotEmpty) {
          return item;
        }
      }
    }
  }
  return null;
}

String? _timeoutFriendlyMessage(DioException exception) {
  if (exception.type != DioExceptionType.connectionTimeout &&
      exception.type != DioExceptionType.sendTimeout &&
      exception.type != DioExceptionType.receiveTimeout) {
    return null;
  }

  final String host = exception.requestOptions.uri.host;
  final int port = exception.requestOptions.uri.port;
  return 'Cannot reach the server at $host:$port. '
      'Make sure the backend and database are running and API_BASE_URL is correct.';
}

String? _connectionFriendlyMessage(DioException exception) {
  if (exception.type != DioExceptionType.connectionError) {
    return null;
  }

  final String host = exception.requestOptions.uri.host;
  final int port = exception.requestOptions.uri.port;
  return 'Could not connect to $host:$port. '
      'Check that the API is running and reachable from this device.';
}
