import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/constants/app_constants.dart';

void main() {
  group('AppConstants.resolveMapTileProviderConfig', () {
    test('returns Mapbox config when both defines are present', () {
      final MapTileProviderConfig config =
          AppConstants.resolveMapTileProviderConfig(
        styleId: 'mapbox/outdoors-v12',
        accessToken: 'pk.test-token',
        isReleaseBuild: false,
      );

      expect(config.kind, MapTileProviderKind.mapbox);
      expect(
        config.urlTemplate,
        contains('api.mapbox.com/styles/v1/mapbox/outdoors-v12/tiles/256'),
      );
      expect(config.urlTemplate, contains('access_token=pk.test-token'));
      expect(config.urlTemplate, contains('{r}'));
      expect(config.retinaMode, isTrue);
      expect(config.attributionLines, contains('© Mapbox'));
      expect(
        config.attributionLines,
        contains('© OpenStreetMap contributors'),
      );
    });

    test(
        'returns dev fallback in debug build when Mapbox defines are absent',
        () {
      final MapTileProviderConfig config =
          AppConstants.resolveMapTileProviderConfig(
        styleId: '',
        accessToken: '',
        isReleaseBuild: false,
      );

      expect(config.kind, MapTileProviderKind.devFallback);
      expect(config, same(MapTileProviderConfig.devFallback));
      expect(config.urlTemplate, startsWith('https://tile.openstreetmap.org/'));
      expect(config.retinaMode, isFalse);
    });

    test('throws StateError in release build when Mapbox defines are absent',
        () {
      expect(
        () => AppConstants.resolveMapTileProviderConfig(
          styleId: '',
          accessToken: '',
          isReleaseBuild: true,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            allOf(
              contains('MAPBOX_STYLE_ID'),
              contains('MAPBOX_ACCESS_TOKEN'),
              contains('release build'),
            ),
          ),
        ),
      );
    });

    test('throws StateError when only MAPBOX_STYLE_ID is missing', () {
      expect(
        () => AppConstants.resolveMapTileProviderConfig(
          styleId: '',
          accessToken: 'pk.test-token',
          isReleaseBuild: false,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('MAPBOX_STYLE_ID'),
          ),
        ),
      );
    });

    test('throws StateError when only MAPBOX_ACCESS_TOKEN is missing', () {
      expect(
        () => AppConstants.resolveMapTileProviderConfig(
          styleId: 'mapbox/outdoors-v12',
          accessToken: '',
          isReleaseBuild: false,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('MAPBOX_ACCESS_TOKEN'),
          ),
        ),
      );
    });

    test('partial config throws even in release build', () {
      expect(
        () => AppConstants.resolveMapTileProviderConfig(
          styleId: 'mapbox/outdoors-v12',
          accessToken: '',
          isReleaseBuild: true,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('MAPBOX_ACCESS_TOKEN'),
          ),
        ),
      );
    });
  });

  group('MapTileProviderConfig', () {
    test('attribution joins attributionLines with spaces', () {
      const MapTileProviderConfig config = MapTileProviderConfig(
        kind: MapTileProviderKind.mapbox,
        urlTemplate: 'https://example.com/{z}/{x}/{y}',
        attributionLines: <String>['© A', '© B'],
      );

      expect(config.attribution, '© A © B');
    });

    test('devFallback is a stable OSM constant', () {
      expect(
        MapTileProviderConfig.devFallback.urlTemplate,
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      );
      expect(
        MapTileProviderConfig.devFallback.attributionLines,
        <String>['© OpenStreetMap contributors'],
      );
      expect(MapTileProviderConfig.devFallback.retinaMode, isFalse);
    });
  });
}
