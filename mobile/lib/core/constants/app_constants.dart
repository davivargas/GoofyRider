import 'package:flutter/foundation.dart';

class AppConstants {
  AppConstants._();

  static const String androidEmulatorApiBaseUrl = 'http://10.0.2.2:8000/v1';

  static const String _configuredApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
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

  static bool get isUsingImplicitEmulatorApiBaseUrl => false;

  static const Duration httpTimeout = Duration(seconds: 20);
  static const Duration weatherCacheTtl = Duration(minutes: 60);
  static const bool _forceDebugDiagnostics = bool.fromEnvironment(
    'DEBUG_DIAGNOSTICS',
    defaultValue: false,
  );

  static bool get isDebugDiagnostics => kDebugMode || _forceDebugDiagnostics;
}

class MapTileProviderConfig {
  const MapTileProviderConfig({
    required this.urlTemplate,
    required this.attribution,
    this.subdomains = const <String>['a', 'b', 'c'],
  });

  final String urlTemplate;
  final String attribution;
  final List<String> subdomains;

  static const MapTileProviderConfig openStreetMap = MapTileProviderConfig(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attribution: '© OpenStreetMap contributors',
    subdomains: <String>[],
  );
}
