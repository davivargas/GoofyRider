import 'package:dio/dio.dart';

import 'auth_api_models.dart';

class AuthApi {
  AuthApi(this._dio);

  final Dio _dio;

  Future<TokenPairResponse> login({
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
    return TokenPairResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<TokenPairResponse> register({
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
    return TokenPairResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<TokenPairResponse> refresh({required String refreshToken}) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/auth/refresh',
      data: <String, dynamic>{'refresh_token': refreshToken},
      options: Options(
        headers: <String, String>{
          'Authorization': '',
        },
      ),
    );
    return TokenPairResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<UserProfileResponse> me({required String accessToken}) async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      '/auth/me',
      options: Options(
        headers: <String, String>{
          'Authorization': 'Bearer $accessToken',
        },
      ),
    );
    return UserProfileResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> logout({required String refreshToken}) async {
    await _dio.post<dynamic>(
      '/auth/logout',
      data: <String, dynamic>{'refresh_token': refreshToken},
    );
  }
}
