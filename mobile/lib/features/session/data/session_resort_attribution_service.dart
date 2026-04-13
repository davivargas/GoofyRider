import '../../../core/storage/drift_local_database.dart';
import '../../resorts/domain/resort_models.dart';
import '../domain/session_models.dart';

const double sessionResortAttributionThresholdMeters = 15000;
const String unknownSessionResortLabel = 'Unknown resort';

class ResolvedSessionResort {
  const ResolvedSessionResort({
    required this.label,
    this.resortId,
    this.inferred = false,
  });

  final String label;
  final String? resortId;
  final bool inferred;
}

class SessionResortAttributionService {
  SessionResortAttributionService({
    required DriftLocalDatabase localDatabase,
    String? Function()? currentUserIdGetter,
  })  : _localDatabase = localDatabase,
        _currentUserIdGetter = currentUserIdGetter;

  final DriftLocalDatabase _localDatabase;
  final String? Function()? _currentUserIdGetter;

  Future<ResolvedSessionResort> resolve(LocalRideSession session) async {
    final List<ResortSummary> resorts = await _readCachedResorts();
    final Map<String, ResortSummary> resortsById = <String, ResortSummary>{
      for (final ResortSummary resort in resorts) resort.id: resort,
    };

    final String? explicitResortId = session.resortId;
    if (explicitResortId != null && explicitResortId.isNotEmpty) {
      final ResortSummary? explicit = resortsById[explicitResortId];
      if (explicit != null) {
        return ResolvedSessionResort(
          label: explicit.name,
          resortId: explicit.id,
        );
      }
      if (!_looksLikeOpaqueResortId(explicitResortId)) {
        return ResolvedSessionResort(label: explicitResortId);
      }
    }

    final String? inferredResortId = await inferResortIdForSession(
      session,
      cachedResorts: resorts,
    );
    if (inferredResortId == null) {
      return const ResolvedSessionResort(label: unknownSessionResortLabel);
    }

    final ResortSummary? inferred = resortsById[inferredResortId];
    return ResolvedSessionResort(
      label: inferred?.name ?? unknownSessionResortLabel,
      resortId: inferredResortId,
      inferred: true,
    );
  }

  Future<String?> inferResortIdForSession(
    LocalRideSession session, {
    List<ResortSummary>? cachedResorts,
  }) async {
    if (session.localId <= 0) {
      return null;
    }
    final LocalSessionPoint? point =
        await _localDatabase.latestAcceptedPoint(session.localId);
    if (point == null) {
      return null;
    }
    return inferResortIdFromPoints(
      <LocalSessionPoint>[point],
      cachedResorts: cachedResorts,
    );
  }

  Future<String?> inferResortIdFromPoints(
    List<LocalSessionPoint> points, {
    List<ResortSummary>? cachedResorts,
  }) async {
    final List<ResortSummary> resorts =
        cachedResorts ?? await _readCachedResorts();
    if (resorts.isEmpty) {
      return null;
    }

    final LocalSessionPoint? point = _latestResolvablePoint(points);
    if (point == null) {
      return null;
    }

    final double latitude = point.filteredLatitude ?? point.latitude;
    final double longitude = point.filteredLongitude ?? point.longitude;

    ResortSummary? bestResort;
    double? bestDistanceMeters;
    for (final ResortSummary resort in resorts) {
      if (resort.latitude == null || resort.longitude == null) {
        continue;
      }
      final double distanceMeters = haversineDistanceMeters(
        latitude,
        longitude,
        resort.latitude!,
        resort.longitude!,
      );
      if (bestDistanceMeters == null || distanceMeters < bestDistanceMeters) {
        bestDistanceMeters = distanceMeters;
        bestResort = resort;
      }
    }

    if (bestResort == null ||
        bestDistanceMeters == null ||
        bestDistanceMeters > sessionResortAttributionThresholdMeters) {
      return null;
    }
    return bestResort.id;
  }

  Future<List<ResortSummary>> _readCachedResorts() async {
    final List<Map<String, dynamic>> cached =
        await _localDatabase.readCachedResorts(ownerUserId: _currentUserIdOrNull);
    return cached.map(_mapCachedResort).toList(growable: false);
  }

  String? get _currentUserIdOrNull {
    final String? currentUserId = _currentUserIdGetter?.call();
    if (currentUserId == null || currentUserId.isEmpty) {
      return null;
    }
    return currentUserId;
  }

  ResortSummary _mapCachedResort(Map<String, dynamic> payload) {
    return ResortSummary(
      id: payload['id'] as String,
      name: payload['name'] as String,
      country: payload['country'] as String? ?? '',
      region: payload['region'] as String? ?? '',
      city: payload['city'] as String?,
      latitude: (payload['latitude'] as num?)?.toDouble(),
      longitude: (payload['longitude'] as num?)?.toDouble(),
      elevationBaseM: payload['elevation_base_m'] as int?,
      elevationTopM: payload['elevation_top_m'] as int?,
      isFavorite: payload['is_favorite'] as bool? ?? false,
      cachedWeatherText: payload['cached_weather_text'] as String?,
      cachedWeatherTempC:
          (payload['cached_weather_temp_c'] as num?)?.toDouble(),
      isStale: false,
    );
  }

  LocalSessionPoint? _latestResolvablePoint(List<LocalSessionPoint> points) {
    for (int index = points.length - 1; index >= 0; index -= 1) {
      final LocalSessionPoint point = points[index];
      final double latitude = point.filteredLatitude ?? point.latitude;
      final double longitude = point.filteredLongitude ?? point.longitude;
      if (latitude.isFinite && longitude.isFinite) {
        return point;
      }
    }
    return null;
  }

  bool _looksLikeOpaqueResortId(String value) {
    return value.contains('-') && value.length >= 16;
  }
}
