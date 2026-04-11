import '../../../core/constants/app_constants.dart';

bool isCachedWeatherStale(
  Map<String, dynamic> payload, {
  DateTime? now,
}) {
  final DateTime fetchedAt =
      DateTime.parse(payload['cached_fetched_at'] as String).toUtc();
  final DateTime currentTime = (now ?? DateTime.now()).toUtc();
  return currentTime.difference(fetchedAt) > AppConstants.weatherCacheTtl;
}
