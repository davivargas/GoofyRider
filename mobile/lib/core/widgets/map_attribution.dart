import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../constants/app_constants.dart';

class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key, required this.config});

  static final _leadingCopyrightPattern = RegExp(
    r'^\s*(?:©|\(c\))\s*',
    caseSensitive: false,
  );

  final MapTileProviderConfig config;

  @override
  Widget build(BuildContext context) {
    return RichAttributionWidget(
      alignment: AttributionAlignment.bottomLeft,
      attributions: <SourceAttribution>[
        for (final String line in config.attributionLines)
          TextSourceAttribution(_sanitizeForOverlay(line)),
      ],
    );
  }

  String _sanitizeForOverlay(String line) {
    final sanitized = line
        .replaceFirst(_leadingCopyrightPattern, '')
        .trim();
    return sanitized.isEmpty ? line : sanitized;
  }
}
