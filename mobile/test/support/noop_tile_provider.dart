import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// A [TileProvider] that returns a 1x1 transparent image without performing
/// any network I/O.
///
/// Widget tests that render a `FlutterMap` must override
/// `mapTileProviderProvider` with an instance of this class. Without it,
/// `TileLayer` falls back to `NetworkTileProvider` and tries to fetch real
/// tiles (usually from OSM or Mapbox), which is both slow and a violation of
/// the "tests must not perform network I/O" rule.
class NoopTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(TileProvider.transparentImage);
  }
}
