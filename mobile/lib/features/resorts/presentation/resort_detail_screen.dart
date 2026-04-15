import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/providers.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../../../core/widgets/map_attribution.dart';
import '../../weather/domain/weather_models.dart';
import '../../weather/presentation/weather_providers.dart';
import '../domain/resort_models.dart';
import 'resort_providers.dart';

class ResortDetailScreen extends ConsumerWidget {
  const ResortDetailScreen({
    super.key,
    required this.resortId,
  });

  final String resortId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resortValue =
        ref.watch(resortDetailControllerProvider(resortId));
    final isFavoriteToggleInFlight =
        ref.watch(resortDetailToggleInFlightProvider(resortId));
    final activeMapTileProviderConfig =
        ref.watch(activeMapTileProviderConfigProvider);

    return resortValue.when(
      loading: () =>
          const Scaffold(body: AppLoadingView(label: 'Loading resort...')),
      error: (Object error, StackTrace _) => Scaffold(
        appBar: AppBar(),
        body: AppErrorView(message: error.toString()),
      ),
      data: (ResortSummary resort) {
        final weather =
            ref.watch(resortWeatherProvider(resort.id));

        final center = LatLng(
          resort.latitude ?? 50,
          resort.longitude ?? -120,
        );

        return Scaffold(
          appBar: AppBar(
            title: Text(resort.name),
            actions: <Widget>[
              IconButton(
                tooltip: resort.isFavorite ? 'Remove favorite' : 'Add favorite',
                onPressed: isFavoriteToggleInFlight
                    ? null
                    : () => ref
                        .read(resortDetailControllerProvider(resortId).notifier)
                        .toggleFavorite(),
                icon: Icon(
                  resort.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: resort.isFavorite ? Colors.amber : null,
                ),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final mapHeight = (constraints.maxHeight * 0.70)
                  .clamp(260.0, constraints.maxHeight - 220)
                  .toDouble();
              return Column(
                children: <Widget>[
                  SizedBox(
                    height: mapHeight,
                    width: double.infinity,
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: center,
                        initialZoom: 13,
                      ),
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
                              width: 40,
                              height: 40,
                              child: const Icon(
                                Icons.place,
                                color: Colors.redAccent,
                              ),
                            ),
                          ],
                        ),
                        MapAttribution(config: activeMapTileProviderConfig),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Card(
                            margin: EdgeInsets.zero,
                            color: Colors.transparent,
                            elevation: 0,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: <Widget>[
                                  const SizedBox(height: 3),
                                  Text(
                                    '${resort.region}, ${resort.country}',
                                    style: Theme.of(context).textTheme.bodyLarge,
                                  ),
                                  if (resort.city != null)
                                    Text(
                                      resort.city!,
                                      style: Theme.of(context).textTheme.bodyLarge,
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: Card(
                                  margin: EdgeInsets.zero,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    child: weather.when(
                                      loading: () =>
                                          const Text('Loading conditions...'),
                                      error: (_, __) => const Text(
                                          'Conditions unavailable right now.'),
                                      data: (ResortWeather? value) {
                                        if (value == null) {
                                          return const Text(
                                              'Conditions unavailable right now.');
                                        }

                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              value.conditionsText ??
                                                  'Conditions unavailable',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleSmall,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Temp: ${value.tempC?.toStringAsFixed(1) ?? '--'} C',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                            Text(
                                              'Wind: ${value.windKph?.toStringAsFixed(1) ?? '--'} kph',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                            Text(
                                              'Snow 24h: ${value.snowfallCm24h?.toStringAsFixed(1) ?? '--'} cm',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                            if (value.stale)
                                              const Padding(
                                                padding: EdgeInsets.only(top: 4),
                                                child: Text(
                                                  'Showing stale cached data.',
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Card(
                                  margin: EdgeInsets.zero,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          'Elevation',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Base: ${resort.elevationBaseM ?? '--'} m',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                        Text(
                                          'Top: ${resort.elevationTopM ?? '--'} m',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: () => context.go(
                              '${RoutePaths.record}?resortId=${Uri.encodeComponent(resort.id)}',
                            ),
                            child: const Text('Start recording here'),
                          ),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
