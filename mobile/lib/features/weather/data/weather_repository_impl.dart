import 'package:dio/dio.dart';

import '../../../core/network/api_error.dart';
import '../../../core/storage/drift_local_database.dart';
import '../domain/weather_models.dart';
import '../domain/weather_repository.dart';
import 'weather_api.dart';
import 'weather_cache_freshness.dart';

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
      final payload =
          await _api.getResortWeather(resortId);
      await _localDatabase.upsertCachedWeather(resortId, payload);
      return ResortWeather.fromJson(payload, fromCache: false, stale: false);
    } on DioException {
      final cached =
          await _localDatabase.readCachedWeather(resortId);
      if (cached == null) {
        return null;
      }
      final stale = isCachedWeatherStale(cached);
      return ResortWeather.fromJson(cached, fromCache: true, stale: stale);
    }
  }

  @override
  Future<ResortWeather?> refreshResortWeatherIfStale(String resortId) async {
    final cached =
        await _localDatabase.readCachedWeather(resortId);
    if (cached != null) {
      final stale = isCachedWeatherStale(cached);
      if (!stale) {
        return ResortWeather.fromJson(cached, fromCache: true, stale: false);
      }
    }

    try {
      final payload =
          await _api.getResortWeather(resortId);
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
