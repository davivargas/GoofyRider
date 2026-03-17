class ResortSummary {
  const ResortSummary({
    required this.id,
    required this.name,
    required this.country,
    required this.region,
    required this.city,
    required this.latitude,
    required this.longitude,
    required this.elevationBaseM,
    required this.elevationTopM,
    required this.isFavorite,
    required this.cachedWeatherText,
    required this.cachedWeatherTempC,
    required this.isStale,
  });

  factory ResortSummary.fromJson(Map<String, dynamic> json,
      {bool isFavorite = false}) {
    return ResortSummary(
      id: json['id'] as String,
      name: json['name'] as String,
      country: json['country'] as String,
      region: json['region'] as String,
      city: json['city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      elevationBaseM: json['elevation_base_m'] as int?,
      elevationTopM: json['elevation_top_m'] as int?,
      isFavorite: isFavorite,
      cachedWeatherText: null,
      cachedWeatherTempC: null,
      isStale: false,
    );
  }

  final String id;
  final String name;
  final String country;
  final String region;
  final String? city;
  final double? latitude;
  final double? longitude;
  final int? elevationBaseM;
  final int? elevationTopM;
  final bool isFavorite;
  final String? cachedWeatherText;
  final double? cachedWeatherTempC;
  final bool isStale;

  ResortSummary copyWith({
    bool? isFavorite,
    String? cachedWeatherText,
    double? cachedWeatherTempC,
    bool? isStale,
  }) {
    return ResortSummary(
      id: id,
      name: name,
      country: country,
      region: region,
      city: city,
      latitude: latitude,
      longitude: longitude,
      elevationBaseM: elevationBaseM,
      elevationTopM: elevationTopM,
      isFavorite: isFavorite ?? this.isFavorite,
      cachedWeatherText: cachedWeatherText ?? this.cachedWeatherText,
      cachedWeatherTempC: cachedWeatherTempC ?? this.cachedWeatherTempC,
      isStale: isStale ?? this.isStale,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'country': country,
      'region': region,
      'city': city,
      'latitude': latitude,
      'longitude': longitude,
      'elevation_base_m': elevationBaseM,
      'elevation_top_m': elevationTopM,
      'is_favorite': isFavorite,
      'cached_weather_text': cachedWeatherText,
      'cached_weather_temp_c': cachedWeatherTempC,
    };
  }
}

class ResortListResult {
  const ResortListResult({
    required this.items,
    required this.total,
    required this.usedCache,
    required this.isStale,
  });

  final List<ResortSummary> items;
  final int total;
  final bool usedCache;
  final bool isStale;
}
