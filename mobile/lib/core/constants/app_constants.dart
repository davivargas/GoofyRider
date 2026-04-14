import 'package:flutter/foundation.dart';

class AppConstants {
  AppConstants._();

  static const String androidEmulatorApiBaseUrl = 'http://10.0.2.2:8000/v1';

  static const String _configuredApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );
  static const String _configuredMapboxStyleId = String.fromEnvironment(
    'MAPBOX_STYLE_ID',
    defaultValue: '',
  );
  static const String _configuredMapboxAccessToken = String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
    defaultValue: '',
  );

  static String get apiBaseUrl {
    final String configuredApiBaseUrl = _configuredApiBaseUrl.trim();
    if (configuredApiBaseUrl.isNotEmpty) {
      return configuredApiBaseUrl;
    }
    throw StateError(
      'Missing API_BASE_URL. Pass --dart-define=API_BASE_URL=<url>. '
      'Android emulator example: --dart-define=API_BASE_URL=$androidEmulatorApiBaseUrl',
    );
  }

  static MapTileProviderConfig get activeMapTileProviderConfig {
    return resolveMapTileProviderConfig(
      styleId: _configuredMapboxStyleId.trim(),
      accessToken: _configuredMapboxAccessToken.trim(),
      isReleaseBuild: kReleaseMode,
    );
  }

  @visibleForTesting
  static MapTileProviderConfig resolveMapTileProviderConfig({
    required String styleId,
    required String accessToken,
    required bool isReleaseBuild,
  }) {
    final bool styleIdPresent = styleId.isNotEmpty;
    final bool accessTokenPresent = accessToken.isNotEmpty;

    if (styleIdPresent && accessTokenPresent) {
      return MapTileProviderConfig.mapbox(
        styleId: styleId,
        accessToken: accessToken,
      );
    }

    if (!styleIdPresent && !accessTokenPresent) {
      if (isReleaseBuild) {
        throw StateError(
          'Missing MAPBOX_STYLE_ID and MAPBOX_ACCESS_TOKEN for release build. '
          'Pass --dart-define=MAPBOX_STYLE_ID=<username/styleId> and '
          '--dart-define=MAPBOX_ACCESS_TOKEN=<token>. '
          'Example styleId: mapbox/outdoors-v12',
        );
      }
      return MapTileProviderConfig.devFallback;
    }

    final List<String> missingVariables = <String>[
      if (!styleIdPresent) 'MAPBOX_STYLE_ID',
      if (!accessTokenPresent) 'MAPBOX_ACCESS_TOKEN',
    ];
    throw StateError(
      'Missing ${missingVariables.join(' and ')}. '
      'Pass both Mapbox defines together, or omit both to use the dev fallback. '
      'Example: --dart-define=MAPBOX_STYLE_ID=mapbox/outdoors-v12 '
      '--dart-define=MAPBOX_ACCESS_TOKEN=<token>',
    );
  }

  static const Duration httpTimeout = Duration(seconds: 20);
  static const Duration weatherCacheTtl = Duration(minutes: 60);
  static const bool _forceDebugDiagnostics = bool.fromEnvironment(
    'DEBUG_DIAGNOSTICS',
    defaultValue: false,
  );

  static bool get isDebugDiagnostics => kDebugMode || _forceDebugDiagnostics;
}

enum MapTileProviderKind {
  mapbox,
  devFallback,
}

class MapTileProviderConfig {
  const MapTileProviderConfig({
    required this.kind,
    required this.urlTemplate,
    required this.attributionLines,
    this.subdomains = const <String>[],
    this.retinaMode = false,
  });

  factory MapTileProviderConfig.mapbox({
    required String styleId,
    required String accessToken,
  }) {
    return MapTileProviderConfig(
      kind: MapTileProviderKind.mapbox,
      urlTemplate:
          'https://api.mapbox.com/styles/v1/$styleId/tiles/256/{z}/{x}/{y}{r}?access_token=$accessToken',
      attributionLines: const <String>[
        '© Mapbox',
        '© OpenStreetMap contributors',
      ],
      retinaMode: true,
    );
  }

  final MapTileProviderKind kind;
  final String urlTemplate;
  final List<String> attributionLines;
  final List<String> subdomains;
  final bool retinaMode;

  String get attribution => attributionLines.join(' ');

  static const MapTileProviderConfig devFallback = MapTileProviderConfig(
    kind: MapTileProviderKind.devFallback,
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attributionLines: <String>['© OpenStreetMap contributors'],
  );
}
