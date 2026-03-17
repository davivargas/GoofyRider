import 'package:dio/dio.dart';

import '../errors/failures.dart';

AppFailure mapDioException(DioException exception) {
  final Object? payload = exception.response?.data;
  final String? machineMessage = _extractMessage(payload);
  final String fallback = exception.message ?? 'Network request failed.';
  final int? statusCode = exception.response?.statusCode;

  if (statusCode == 401) {
    return AuthFailure(machineMessage ?? 'Authentication required.', details: payload);
  }

  return NetworkFailure(
    machineMessage ?? fallback,
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
  }
  return null;
}
