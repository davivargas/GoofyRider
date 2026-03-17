import 'package:dio/dio.dart';

class AuthApi {
  AuthApi(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/auth/login',
      data: <String, dynamic>{
        'email': email,
        'password': password,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/auth/register',
      data: <String, dynamic>{
        'email': email,
        'password': password,
        'display_name': displayName,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refresh({required String refreshToken}) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/auth/refresh',
      data: <String, dynamic>{'refresh_token': refreshToken},
      options: Options(
        headers: <String, String>{
          'Authorization': '',
        },
      ),
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> me({required String accessToken}) async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      '/auth/me',
      options: Options(
        headers: <String, String>{
          'Authorization': 'Bearer $accessToken',
        },
      ),
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> logout({required String refreshToken}) async {
    await _dio.post<dynamic>(
      '/auth/logout',
      data: <String, dynamic>{'refresh_token': refreshToken},
    );
  }
}
