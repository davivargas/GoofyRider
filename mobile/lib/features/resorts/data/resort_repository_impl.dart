import 'package:dio/dio.dart';

import '../../../core/network/api_error.dart';
import '../../../core/storage/drift_local_database.dart';
import '../../weather/domain/weather_models.dart';
import '../../weather/data/weather_cache_freshness.dart';
import '../domain/resort_models.dart';
import '../domain/resort_repository.dart';
import 'resorts_api.dart';

class ResortRepositoryImpl implements ResortRepository {
  ResortRepositoryImpl({
    required ResortsApi api,
    required DriftLocalDatabase localDatabase,
    required String? Function() currentUserIdGetter,
  })  : _api = api,
        _localDatabase = localDatabase,
        _currentUserIdGetter = currentUserIdGetter;

  final ResortsApi _api;
  final DriftLocalDatabase _localDatabase;
  final String? Function() _currentUserIdGetter;

  @override
  Future<ResortListResult> searchResorts({
    required String query,
    String? region,
  }) async {
    try {
      final Map<String, dynamic> payload = await _api.listResorts(
        query: query,
        region: region,
      );

      final Set<String> favoriteIds = await _favoriteIdsBestEffort();

      final List<dynamic> items = payload['items'] as List<dynamic>;
      final List<ResortSummary> resorts = items.map((dynamic raw) {
        final Map<String, dynamic> resortJson = raw as Map<String, dynamic>;
        return ResortSummary.fromJson(
          resortJson,
          isFavorite: favoriteIds.contains(resortJson['id']),
        );
      }).toList(growable: false);

      for (final ResortSummary resort in resorts) {
        await _cacheResortPayload(resort.id, resort.toJson());
      }

      return ResortListResult(
        items: await _withCachedWeather(resorts),
        total: payload['total'] as int? ?? resorts.length,
        usedCache: false,
        isStale: false,
      );
    } on DioException {
      final List<Map<String, dynamic>> cached =
          await _localDatabase.readCachedResorts(
        ownerUserId: _currentUserIdOrNull,
      );
      final List<ResortSummary> resorts = cached
          .map((Map<String, dynamic> raw) => _fromCached(raw, isStale: true))
          .where((ResortSummary resort) {
        final bool queryMatch = query.trim().isEmpty ||
            resort.name.toLowerCase().contains(query.trim().toLowerCase());
        final bool regionMatch = region == null ||
            region.trim().isEmpty ||
            resort.region.toLowerCase() == region.trim().toLowerCase();
        return queryMatch && regionMatch;
      }).toList(growable: false);

      return ResortListResult(
        items: resorts,
        total: resorts.length,
        usedCache: true,
        isStale: true,
      );
    }
  }

  @override
  Future<ResortSummary> getResortDetail(String resortId) async {
    try {
      final Map<String, dynamic> payload = await _api.getResortDetail(resortId);
      final bool isFavorite = await _isFavoriteBestEffort(resortId);

      final ResortSummary resort =
          ResortSummary.fromJson(payload, isFavorite: isFavorite);
      await _cacheResortPayload(resort.id, resort.toJson());
      return (await _withCachedWeather(<ResortSummary>[resort])).first;
    } on DioException catch (exception) {
      final Map<String, dynamic>? cached =
          await _localDatabase.readCachedResort(
        resortId,
        ownerUserId: _currentUserIdOrNull,
      );
      if (cached != null) {
        return _fromCached(cached, isStale: true);
      }
      throw mapDioException(exception);
    }
  }

  @override
  Future<ResortSummary> toggleFavoriteResort(ResortSummary resort) async {
    try {
      if (resort.isFavorite) {
        await _api.removeFavorite(resort.id);
      } else {
        await _api.addFavorite(resort.id);
      }
      final ResortSummary updated =
          resort.copyWith(isFavorite: !resort.isFavorite);
      await _cacheResortPayload(updated.id, updated.toJson());
      return updated;
    } on DioException catch (exception) {
      throw mapDioException(exception);
    }
  }

  @override
  Future<List<ResortSummary>> listFavoriteResorts() async {
    final String? ownerUserId = _currentUserIdOrNull;
    if (ownerUserId == null) {
      return const <ResortSummary>[];
    }

    try {
      final List<Map<String, dynamic>> payload =
          await _api.listFavoriteResorts();
      final List<ResortSummary> resorts = payload
          .map((Map<String, dynamic> json) =>
              ResortSummary.fromJson(json, isFavorite: true))
          .toList(growable: false);
      final Set<String> favoriteIds =
          resorts.map((ResortSummary resort) => resort.id).toSet();

      for (final ResortSummary resort in resorts) {
        await _cacheResortPayload(resort.id, resort.toJson());
      }
      await _syncCachedFavorites(favoriteIds, ownerUserId: ownerUserId);

      return await _withCachedWeather(resorts);
    } on DioException {
      final List<Map<String, dynamic>> cached =
          await _localDatabase.readCachedResorts(
        ownerUserId: ownerUserId,
      );
      return cached
          .map((Map<String, dynamic> raw) => _fromCached(raw, isStale: true))
          .where((ResortSummary resort) => resort.isFavorite)
          .toList(growable: false);
    }
  }

  Future<void> _syncCachedFavorites(
    Set<String> favoriteIds, {
    required String ownerUserId,
  }) async {
    final List<Map<String, dynamic>> cached =
        await _localDatabase.readCachedResorts(
      ownerUserId: ownerUserId,
    );
    for (final Map<String, dynamic> raw in cached) {
      final String? id = raw['id'] as String?;
      if (id == null || id.isEmpty) {
        continue;
      }

      final bool shouldBeFavorite = favoriteIds.contains(id);
      final bool isFavorite = raw['is_favorite'] as bool? ?? false;
      if (isFavorite == shouldBeFavorite) {
        continue;
      }

      final Map<String, dynamic> updated = Map<String, dynamic>.from(raw)
        ..remove('cached_fetched_at')
        ..['is_favorite'] = shouldBeFavorite;
      await _localDatabase.upsertCachedResort(
        id,
        updated,
        ownerUserId: ownerUserId,
      );
    }
  }

  Future<Set<String>> _favoriteIdsBestEffort() async {
    if (_currentUserIdOrNull == null) {
      return <String>{};
    }
    try {
      final List<ResortSummary> favorites = await listFavoriteResorts();
      return favorites.map((ResortSummary resort) => resort.id).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<bool> _isFavoriteBestEffort(String resortId) async {
    if (_currentUserIdOrNull == null) {
      return false;
    }
    try {
      final List<ResortSummary> favorites = await listFavoriteResorts();
      return favorites.any((ResortSummary resort) => resort.id == resortId);
    } catch (_) {
      return false;
    }
  }

  Future<List<ResortSummary>> _withCachedWeather(
      List<ResortSummary> resorts) async {
    final DateTime now = DateTime.now().toUtc();
    final List<ResortSummary> enriched = <ResortSummary>[];

    for (final ResortSummary resort in resorts) {
      final Map<String, dynamic>? weatherRaw =
          await _localDatabase.readCachedWeather(resort.id);
      if (weatherRaw == null) {
        enriched.add(resort);
        continue;
      }

      final bool stale = isCachedWeatherStale(weatherRaw, now: now);
      final ResortWeather weather = ResortWeather.fromJson(
        weatherRaw,
        fromCache: true,
        stale: stale,
      );

      enriched.add(
        resort.copyWith(
          cachedWeatherText: weather.conditionsText,
          cachedWeatherTempC: weather.tempC,
          isStale: stale,
        ),
      );
    }

    return enriched;
  }

  ResortSummary _fromCached(
    Map<String, dynamic> payload, {
    required bool isStale,
  }) {
    return ResortSummary(
      id: payload['id'] as String,
      name: payload['name'] as String,
      country: payload['country'] as String,
      region: payload['region'] as String,
      city: payload['city'] as String?,
      latitude: (payload['latitude'] as num?)?.toDouble(),
      longitude: (payload['longitude'] as num?)?.toDouble(),
      elevationBaseM: payload['elevation_base_m'] as int?,
      elevationTopM: payload['elevation_top_m'] as int?,
      isFavorite: payload['is_favorite'] as bool? ?? false,
      cachedWeatherText: payload['cached_weather_text'] as String?,
      cachedWeatherTempC:
          (payload['cached_weather_temp_c'] as num?)?.toDouble(),
      isStale: isStale,
    );
  }

  Future<void> _cacheResortPayload(
    String resortId,
    Map<String, dynamic> payload,
  ) {
    return _localDatabase.upsertCachedResort(
      resortId,
      payload,
      ownerUserId: _currentUserIdOrNull,
    );
  }

  String? get _currentUserIdOrNull {
    final String? currentUserId = _currentUserIdGetter();
    if (currentUserId == null || currentUserId.isEmpty) {
      return null;
    }
    return currentUserId;
  }
}
