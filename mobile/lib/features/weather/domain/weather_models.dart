class ResortWeather {
  const ResortWeather({
    required this.resortId,
    required this.observedAt,
    required this.tempC,
    required this.windKph,
    required this.snowfallCm24h,
    required this.conditionsText,
    required this.todayHighC,
    required this.todayLowC,
    required this.snowfallNext24hCm,
    required this.weatherCodeText,
    required this.fromCache,
    required this.stale,
  });

  factory ResortWeather.fromJson(
    Map<String, dynamic> json, {
    bool fromCache = false,
    bool stale = false,
  }) {
    final Map<String, dynamic> current =
        (json['current'] as Map<String, dynamic>? ?? <String, dynamic>{});
    final Map<String, dynamic> forecast =
        (json['forecast_summary'] as Map<String, dynamic>? ??
            <String, dynamic>{});

    return ResortWeather(
      resortId: json['resort_id'] as String,
      observedAt: DateTime.parse(json['observed_at'] as String),
      tempC: (current['temp_c'] as num?)?.toDouble(),
      windKph: (current['wind_kph'] as num?)?.toDouble(),
      snowfallCm24h: (current['snowfall_cm_24h'] as num?)?.toDouble(),
      conditionsText: current['conditions_text'] as String?,
      todayHighC: (forecast['today_high_c'] as num?)?.toDouble(),
      todayLowC: (forecast['today_low_c'] as num?)?.toDouble(),
      snowfallNext24hCm: (forecast['snowfall_next_24h_cm'] as num?)?.toDouble(),
      weatherCodeText: forecast['weather_code_text'] as String?,
      fromCache: fromCache,
      stale: stale,
    );
  }

  final String resortId;
  final DateTime observedAt;
  final double? tempC;
  final double? windKph;
  final double? snowfallCm24h;
  final String? conditionsText;
  final double? todayHighC;
  final double? todayLowC;
  final double? snowfallNext24hCm;
  final String? weatherCodeText;
  final bool fromCache;
  final bool stale;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'resort_id': resortId,
      'observed_at': observedAt.toUtc().toIso8601String(),
      'current': <String, dynamic>{
        'temp_c': tempC,
        'wind_kph': windKph,
        'snowfall_cm_24h': snowfallCm24h,
        'conditions_text': conditionsText,
      },
      'forecast_summary': <String, dynamic>{
        'today_high_c': todayHighC,
        'today_low_c': todayLowC,
        'snowfall_next_24h_cm': snowfallNext24hCm,
        'weather_code_text': weatherCodeText,
      },
    };
  }
}
