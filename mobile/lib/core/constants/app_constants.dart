class AppConstants {
  AppConstants._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000/v1',
  );

  static const Duration httpTimeout = Duration(seconds: 20);
  static const Duration weatherCacheTtl = Duration(minutes: 60);
  static const bool isDebugDiagnostics = bool.fromEnvironment(
    'DEBUG_DIAGNOSTICS',
    defaultValue: true,
  );
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
