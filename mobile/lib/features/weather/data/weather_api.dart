import 'package:dio/dio.dart';

class WeatherApi {
  WeatherApi(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> getResortWeather(String resortId) async {
    final response =
        await _dio.get<dynamic>('/weather/resorts/$resortId');
    return response.data as Map<String, dynamic>;
  }
}
