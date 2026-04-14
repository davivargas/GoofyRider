import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../constants/app_constants.dart';

class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key, required this.config});

  final MapTileProviderConfig config;

  @override
  Widget build(BuildContext context) {
    return RichAttributionWidget(
      alignment: AttributionAlignment.bottomRight,
      attributions: <SourceAttribution>[
        for (final String line in config.attributionLines)
          TextSourceAttribution(line),
      ],
    );
  }
}
