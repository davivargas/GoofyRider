import 'package:dio/dio.dart';

import '../constants/app_constants.dart';

Dio buildBaseDio() {
  return Dio(
    BaseOptions(
      baseUrl: AppConstants.apiBaseUrl,
      connectTimeout: AppConstants.httpTimeout,
      receiveTimeout: AppConstants.httpTimeout,
      sendTimeout: AppConstants.httpTimeout,
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
    ),
  );
}
