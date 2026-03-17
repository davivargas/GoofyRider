import 'weather_models.dart';
import 'weather_repository.dart';

class GetResortWeather {
  const GetResortWeather(this._repository);

  final WeatherRepository _repository;

  Future<ResortWeather?> call(String resortId) {
    return _repository.getResortWeather(resortId);
  }
}

class RefreshResortWeatherIfStale {
  const RefreshResortWeatherIfStale(this._repository);

  final WeatherRepository _repository;

  Future<ResortWeather?> call(String resortId) {
    return _repository.refreshResortWeatherIfStale(resortId);
  }
}
