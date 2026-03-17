import 'package:dio/dio.dart';

class ResortsApi {
  ResortsApi(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> listResorts({
    required String query,
    String? region,
  }) async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      '/resorts',
      queryParameters: <String, dynamic>{
        if (query.trim().isNotEmpty) 'query': query.trim(),
        if (region != null && region.trim().isNotEmpty) 'region': region.trim(),
        'page': 1,
        'page_size': 50,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getResortDetail(String resortId) async {
    final Response<dynamic> response = await _dio.get<dynamic>('/resorts/$resortId');
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listFavoriteResorts() async {
    final Response<dynamic> response = await _dio.get<dynamic>('/users/me/favorites');
    final List<dynamic> payload = response.data as List<dynamic>;
    return payload.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> addFavorite(String resortId) async {
    final Response<dynamic> response = await _dio.post<dynamic>('/users/me/favorites/$resortId');
    return response.data as Map<String, dynamic>;
  }

  Future<void> removeFavorite(String resortId) async {
    await _dio.delete<dynamic>('/users/me/favorites/$resortId');
  }
}
