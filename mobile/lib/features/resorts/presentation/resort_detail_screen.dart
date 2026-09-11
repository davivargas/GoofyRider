import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/shell/app_tab_bar.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/providers.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../../../core/widgets/design_widgets.dart';
import '../../../core/widgets/map_attribution.dart';
import '../../weather/domain/weather_models.dart';
import '../../weather/presentation/weather_providers.dart';
import '../domain/resort_models.dart';
import 'resort_providers.dart';

class ResortDetailScreen extends ConsumerWidget {
  const ResortDetailScreen({super.key, required this.resortId});

  final String resortId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resortValue = ref.watch(resortDetailControllerProvider(resortId));
    final isFavoriteToggleInFlight = ref.watch(resortDetailToggleInFlightProvider(resortId));
    final activeMapTileProviderConfig = ref.watch(activeMapTileProviderConfigProvider);
    final t = context.tokens;

    return resortValue.when(
      loading: () => const Scaffold(body: AppLoadingView(label: 'Loading resort...')),
      error: (Object error, StackTrace _) => Scaffold(appBar: AppBar(), body: AppErrorView(message: error.toString())),
      data: (ResortSummary resort) {
        final weather = ref.watch(resortWeatherProvider(resort.id));
        final center = LatLng(resort.latitude ?? 50, resort.longitude ?? -120);
        final height = MediaQuery.sizeOf(context).height;
        final mapHeight = (height * 0.45).clamp(260.0, 400.0).toDouble();
        final base = resort.elevationBaseM;
        final top = resort.elevationTopM;
        final skiable = (base != null && top != null && top > base) ? top - base : null;
        final location = <String>[
          '${resort.region}, ${resort.country}',
          if (resort.city != null && resort.city!.trim().isNotEmpty) resort.city!,
        ].join(' · ');

        return Scaffold(
          body: ListView(
            padding: EdgeInsets.only(bottom: AppTabBar.height + 24),
            children: <Widget>[
              SizedBox(
                height: mapHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    FlutterMap(
                      options: MapOptions(initialCenter: center, initialZoom: 13),
                      children: <Widget>[
                        TileLayer(
                          urlTemplate: activeMapTileProviderConfig.urlTemplate,
                          subdomains: activeMapTileProviderConfig.subdomains,
                          retinaMode: activeMapTileProviderConfig.retinaMode,
                          userAgentPackageName: 'com.goofyrider.mobile',
                        ),
                        MarkerLayer(
                          markers: <Marker>[
                            Marker(
                              point: center,
                              width: 16,
                              height: 16,
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: t.volt, shape: BoxShape.circle, border: Border.all(color: t.bg, width: 2)),
                              ),
                            ),
                          ],
                        ),
                        MapAttribution(config: activeMapTileProviderConfig),
                      ],
                    ),
                    IgnorePointer(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          height: 120,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[t.bg.withValues(alpha: 0), t.bg],
                            ),
                          ),
                        ),
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            _RoundButton(
                              tooltip: 'Back',
                              icon: Icons.arrow_back,
                              onPressed: () {
                                if (context.canPop()) {
                                  context.pop();
                                } else {
                                  context.go(RoutePaths.resorts);
                                }
                              },
                            ),
                            _RoundButton(
                              tooltip: resort.isFavorite ? 'Remove favorite' : 'Add favorite',
                              icon: resort.isFavorite ? Icons.favorite : Icons.favorite_border,
                              iconColor: resort.isFavorite ? t.voltText : t.text,
                              volt: resort.isFavorite,
                              onPressed: isFavoriteToggleInFlight
                                  ? null
                                  : () => ref.read(resortDetailControllerProvider(resortId).notifier).toggleFavorite(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Transform.translate(
                offset: const Offset(0, -46),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(resort.name.toUpperCase(), style: Theme.of(context).textTheme.displaySmall),
                      const SizedBox(height: 4),
                      MonoLabel(location, size: 9, letterSpacing: 1.6),
                      const SizedBox(height: 16),
                      weather.when(
                        loading: () => const _WeatherTiles(temp: '--', conditions: 'Loading', snow: null, wind: null),
                        error: (_, __) => const _WeatherTiles(temp: '--', conditions: 'Unavailable', snow: null, wind: null),
                        data: (ResortWeather? value) => _WeatherTiles(
                          temp: value?.tempC == null ? '--' : '${value!.tempC!.toStringAsFixed(0)}°',
                          conditions: value?.conditionsText ?? 'Unavailable',
                          snow: value?.snowfallCm24h,
                          wind: value?.windKph,
                          stale: value?.stale ?? false,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SurfaceCard(
                        radius: 14,
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                        child: Column(
                          children: <Widget>[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: <Widget>[
                                MonoLabel('Base ${base ?? '--'} m', size: 8, tone: MonoTone.muted),
                                MonoLabel('Top ${top ?? '--'} m', size: 8, tone: MonoTone.muted),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Container(
                              height: 6,
                              decoration: BoxDecoration(color: t.raised, borderRadius: BorderRadius.circular(3)),
                              child: FractionallySizedBox(
                                alignment: Alignment.center,
                                widthFactor: 0.7,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(3),
                                    gradient: LinearGradient(colors: <Color>[t.iceBar, t.volt]),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: MonoLabel('${skiable ?? '--'} m skiable vert', size: 8),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      VoltButton(
                        label: 'Start recording here',
                        onPressed: () => context.go('${RoutePaths.record}?resortId=${Uri.encodeComponent(resort.id)}'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.tooltip, required this.icon, required this.onPressed, this.iconColor, this.volt = false});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? iconColor;
  final bool volt;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: t.bg.withValues(alpha: 0.8),
        shape: BoxShape.circle,
        border: Border.all(color: volt ? t.voltText.withValues(alpha: 0.5) : t.text.withValues(alpha: 0.1)),
      ),
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        iconSize: 16,
        onPressed: onPressed,
        icon: Icon(icon, color: iconColor ?? t.text),
      ),
    );
  }
}

class _WeatherTiles extends StatelessWidget {
  const _WeatherTiles({required this.temp, required this.conditions, required this.snow, required this.wind, this.stale = false});

  final String temp;
  final String conditions;
  final double? snow;
  final double? wind;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget tile(String value, String label, {bool volt = false}) => Expanded(
          child: SurfaceCard(
            radius: 14,
            voltBorder: volt,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: StatBlock(value: value, label: label, valueColor: volt ? t.voltText : null),
          ),
        );
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            tile(temp, conditions),
            const SizedBox(width: 10),
            tile(snow == null ? '--' : '${snow!.toStringAsFixed(0)} cm', 'Snow 24h', volt: (snow ?? 0) > 0),
            const SizedBox(width: 10),
            tile(wind == null ? '--' : wind!.toStringAsFixed(0), 'Wind kph'),
          ],
        ),
        if (stale)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: MonoLabel('Showing stale cached data.', size: 8, tone: MonoTone.muted, uppercase: false),
            ),
          ),
      ],
    );
  }
}
