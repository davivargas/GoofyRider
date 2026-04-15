import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/weather/data/weather_cache_freshness.dart';

void main() {
  group('isCachedWeatherStale', () {
    test('returns false when cached weather is still within the ttl', () {
      final now = DateTime.utc(2026, 4, 10, 12, 0);
      final payload = <String, dynamic>{
        'cached_fetched_at':
            now.subtract(const Duration(minutes: 59)).toIso8601String(),
      };

      expect(isCachedWeatherStale(payload, now: now), isFalse);
    });

    test('returns false exactly at the ttl boundary', () {
      final now = DateTime.utc(2026, 4, 10, 12, 0);
      final payload = <String, dynamic>{
        'cached_fetched_at':
            now.subtract(const Duration(minutes: 60)).toIso8601String(),
      };

      expect(isCachedWeatherStale(payload, now: now), isFalse);
    });

    test('returns true when cached weather is older than the ttl', () {
      final now = DateTime.utc(2026, 4, 10, 12, 0);
      final payload = <String, dynamic>{
        'cached_fetched_at': now
            .subtract(const Duration(minutes: 60, seconds: 1))
            .toIso8601String(),
      };

      expect(isCachedWeatherStale(payload, now: now), isTrue);
    });
  });
}
