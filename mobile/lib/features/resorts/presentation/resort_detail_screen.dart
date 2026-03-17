import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
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
    final AsyncValue<ResortSummary> resortValue = ref.watch(resortDetailProvider(resortId));

    return resortValue.when(
      loading: () => const Scaffold(body: AppLoadingView(label: 'Loading resort...')),
      error: (Object error, StackTrace _) => Scaffold(
        appBar: AppBar(),
        body: AppErrorView(message: error.toString()),
      ),
      data: (ResortSummary resort) {
        final AsyncValue<ResortWeather?> weather = ref.watch(resortWeatherProvider(resort.id));

        final LatLng center = LatLng(
          resort.latitude ?? 50,
          resort.longitude ?? -120,
        );

        return Scaffold(
          appBar: AppBar(title: Text(resort.name)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${resort.region}, ${resort.country}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (resort.city != null)
                        Text(
                          resort.city!,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 220,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: center,
                      initialZoom: 11,
                    ),
                    children: <Widget>[
                      TileLayer(
                        urlTemplate: MapTileProviderConfig.openStreetMap.urlTemplate,
                        subdomains: MapTileProviderConfig.openStreetMap.subdomains,
                        userAgentPackageName: 'com.goofyrider.mobile',
                      ),
                      MarkerLayer(
                        markers: <Marker>[
                          Marker(
                            point: center,
                            width: 40,
                            height: 40,
                            child: const Icon(Icons.place, color: Colors.redAccent),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: weather.when(
                    loading: () => const Text('Loading conditions...'),
                    error: (_, __) => const Text('Conditions unavailable right now.'),
                    data: (ResortWeather? value) {
                      if (value == null) {
                        return const Text('Conditions unavailable right now.');
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            value.conditionsText ?? 'Conditions unavailable',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text('Temp: ${value.tempC?.toStringAsFixed(1) ?? '--'} C'),
                          Text('Wind: ${value.windKph?.toStringAsFixed(1) ?? '--'} kph'),
                          Text(
                            'Snow 24h: ${value.snowfallCm24h?.toStringAsFixed(1) ?? '--'} cm',
                          ),
                          if (value.stale)
                            const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text('Showing stale cached data.'),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  title: const Text('Elevation'),
                  subtitle: Text(
                    'Base: ${resort.elevationBaseM ?? '--'} m • Top: ${resort.elevationTopM ?? '--'} m',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => context.go(
                  '${RoutePaths.record}?resortId=${Uri.encodeComponent(resort.id)}',
                ),
                child: const Text('Start recording here'),
              ),
              TextButton.icon(
                onPressed: () => ref.read(resortsControllerProvider.notifier).toggleFavorite(resort),
                icon: Icon(resort.isFavorite ? Icons.favorite : Icons.favorite_border),
                label: Text(resort.isFavorite ? 'Remove favorite' : 'Add favorite'),
              ),
            ],
          ),
        );
      },
    );
  }
}
