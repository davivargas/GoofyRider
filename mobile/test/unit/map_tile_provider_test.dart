import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fall_line_mobile/core/providers.dart';

TileLayer _layerFrom(ProviderContainer container) => TileLayer(
      urlTemplate: 'https://example.invalid/{z}/{x}/{y}.png',
      tileProvider: container.read(mapTileProviderProvider),
    );

void main() {
  group('mapTileProviderProvider', () {
    test('leaves tile-provider ownership to each TileLayer', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // A shared, container-scoped instance would be disposed by whichever
      // TileLayer is torn down first; TileLayer builds its own when given null.
      expect(container.read(mapTileProviderProvider), isNull);
    });

    test('never hands two TileLayers the same provider instance', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final first = _layerFrom(container);
      final second = _layerFrom(container);
      addTearDown(second.tileProvider.dispose);

      expect(identical(first.tileProvider, second.tileProvider), isFalse);

      // `TileLayerState.dispose()` calls `tileProvider.dispose()`, which closes
      // a NetworkTileProvider's HTTP client for good. Tearing the first map
      // screen down must leave the second screen's provider usable.
      first.tileProvider.dispose();
      expect(
        () => second.tileProvider
            .getImage(const TileCoordinates(0, 0, 0), second),
        returnsNormally,
      );
    });
  });
}
