import 'weather_models.dart';

abstract class WeatherRepository {
  Future<ResortWeather?> getResortWeather(String resortId);
  Future<ResortWeather?> refreshResortWeatherIfStale(String resortId);
}
