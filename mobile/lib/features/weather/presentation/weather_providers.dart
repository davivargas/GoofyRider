import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/weather_api.dart';
import '../data/weather_repository_impl.dart';
import '../domain/weather_models.dart';
import '../domain/weather_repository.dart';

final weatherApiProvider = Provider<WeatherApi>(
  (ref) => WeatherApi(ref.watch(authorizedDioProvider)),
);

final weatherRepositoryProvider = Provider<WeatherRepository>(
  (ref) => WeatherRepositoryImpl(
    api: ref.watch(weatherApiProvider),
    localDatabase: ref.watch(driftLocalDatabaseProvider),
  ),
);

final resortWeatherProvider = FutureProvider.family<ResortWeather?, String>(
  (ref, resortId) => ref.watch(weatherRepositoryProvider).refreshResortWeatherIfStale(resortId),
);
