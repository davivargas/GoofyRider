import 'package:dio/dio.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_error.dart';
import '../../../core/storage/drift_local_database.dart';
import '../domain/weather_models.dart';
import '../domain/weather_repository.dart';
import 'weather_api.dart';

class WeatherRepositoryImpl implements WeatherRepository {
  WeatherRepositoryImpl({
    required WeatherApi api,
    required DriftLocalDatabase localDatabase,
  })  : _api = api,
        _localDatabase = localDatabase;

  final WeatherApi _api;
  final DriftLocalDatabase _localDatabase;

  @override
  Future<ResortWeather?> getResortWeather(String resortId) async {
    try {
      final Map<String, dynamic> payload = await _api.getResortWeather(resortId);
      await _localDatabase.upsertCachedWeather(resortId, payload);
      return ResortWeather.fromJson(payload, fromCache: false, stale: false);
    } on DioException {
      final Map<String, dynamic>? cached = await _localDatabase.readCachedWeather(resortId);
      if (cached == null) {
        return null;
      }
      final DateTime fetchedAt = DateTime.parse(cached['cached_fetched_at'] as String).toUtc();
      final bool stale = DateTime.now().toUtc().difference(fetchedAt) > AppConstants.weatherCacheTtl;
      return ResortWeather.fromJson(cached, fromCache: true, stale: stale);
    }
  }

  @override
  Future<ResortWeather?> refreshResortWeatherIfStale(String resortId) async {
    final Map<String, dynamic>? cached = await _localDatabase.readCachedWeather(resortId);
    if (cached != null) {
      final DateTime fetchedAt = DateTime.parse(cached['cached_fetched_at'] as String).toUtc();
      final bool stale = DateTime.now().toUtc().difference(fetchedAt) > AppConstants.weatherCacheTtl;
      if (!stale) {
        return ResortWeather.fromJson(cached, fromCache: true, stale: false);
      }
    }

    try {
      final Map<String, dynamic> payload = await _api.getResortWeather(resortId);
      await _localDatabase.upsertCachedWeather(resortId, payload);
      return ResortWeather.fromJson(payload, fromCache: false, stale: false);
    } on DioException catch (exception) {
      if (cached != null) {
        return ResortWeather.fromJson(cached, fromCache: true, stale: true);
      }
      throw mapDioException(exception);
    }
  }
}
