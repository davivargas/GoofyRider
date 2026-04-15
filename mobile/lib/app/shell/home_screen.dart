import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../router/route_paths.dart';
import '../../core/constants/app_constants.dart';
import '../../core/providers/distance_unit_preference_provider.dart';
import '../../core/utils/date_time_formatting.dart';
import '../../core/utils/distance_unit.dart';
import '../../core/utils/duration_formatting.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/resorts/domain/resort_models.dart';
import '../../features/resorts/presentation/resort_providers.dart';
import '../../features/session/domain/session_models.dart';
import '../../features/session/presentation/session_providers.dart';
import '../../features/weather/domain/weather_models.dart';
import '../../features/weather/presentation/weather_providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final favorites =
        ref.watch(favoriteResortsProvider);
    final history =
        ref.watch(historyProvider);
    final unsyncedCount =
        ref.watch(unsyncedSessionCountProvider);
    final showDebugDiagnostics =
        kDebugMode && AppConstants.isDebugDiagnostics;

    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref
              .read(recordingControllerProvider.notifier)
              .retryPendingSyncs();
          ref.invalidate(favoriteResortsProvider);
          ref.invalidate(historyProvider);
          ref.invalidate(unsyncedSessionCountProvider);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            Card(
              child: ListTile(
                title: Text(
                  'Welcome back, ${authState.session?.user.displayName ?? 'Rider'}',
                ),
                subtitle: const Text('Ready for your next run?'),
              ),
            ),
            const SizedBox(height: 12),
            if (showDebugDiagnostics)
              unsyncedCount.when(
                data: (int count) {
                  if (count <= 0) {
                    return const SizedBox.shrink();
                  }
                  return Card(
                    color: Colors.orange.withValues(alpha: 0.16),
                    child: ListTile(
                      leading: const Icon(Icons.sync_problem),
                      title: Text('$count session(s) pending sync'),
                      subtitle: const Text(
                        'Open History to retry any failed uploads.',
                      ),
                    ),
                  );
                },
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Text('Quick action'),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: () => context.go(RoutePaths.record),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start recording'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Recent sessions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            history.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace _) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Unable to load history: $error'),
                ),
              ),
              data: (List<LocalRideSession> sessions) {
                if (sessions.isEmpty) {
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No sessions yet.'),
                    ),
                  );
                }

                final latest = sessions.take(3).toList();
                return Column(
                  children: latest.map((LocalRideSession session) {
                    return Card(
                      child: ListTile(
                        title: Text(session.resortId ?? 'Unknown resort'),
                        subtitle: Text(
                          '${session.startedAt.toDayLabel()} at ${session.startedAt.toTimeLabel()} • ${distanceUnit.formatFromMeters(session.distanceM)} • ${formatSecondsAsDuration(session.activeDurationS)}',
                        ),
                        // trailing: showDebugDiagnostics
                        //     ? Text(session.state.wireValue)
                        //     : null,
                        onTap: session.localId > 0
                            ? () => context.go(
                                  RoutePaths.sessionDetail.replaceAll(
                                    ':sessionId',
                                    session.localId.toString(),
                                  ),
                                )
                            : null,
                      ),
                    );
                  }).toList(growable: false),
                );
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'Favorite resorts',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            favorites.when(
              loading: () => const SizedBox(
                height: 110,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (Object error, StackTrace _) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Unable to load favorites: $error'),
                ),
              ),
              data: (List<ResortSummary> resorts) {
                if (resorts.isEmpty) {
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'No favorites yet. Add some from the Resorts tab.',
                      ),
                    ),
                  );
                }

                return SizedBox(
                  height: 126,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: resorts.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (BuildContext context, int index) {
                      final resort = resorts[index];
                      return _FavoriteResortCard(resort: resort);
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FavoriteResortCard extends ConsumerWidget {
  const _FavoriteResortCard({required this.resort});

  final ResortSummary resort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weather =
        ref.watch(resortWeatherProvider(resort.id));

    final conditions = _resolveConditionsText(weather, resort);
    final temp = _resolveTemperatureText(weather, resort);

    return GestureDetector(
      onTap: () => context.go(
        RoutePaths.resortDetail.replaceAll(':resortId', resort.id),
      ),
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF123048),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              resort.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '${resort.region}, ${resort.country}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '$conditions • $temp C',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

String _resolveConditionsText(
  AsyncValue<ResortWeather?> weather,
  ResortSummary resort,
) {
  final liveText = weather.valueOrNull?.conditionsText;
  if (liveText != null && liveText.trim().isNotEmpty) {
    return liveText;
  }

  final cachedText = resort.cachedWeatherText;
  if (cachedText != null && cachedText.trim().isNotEmpty) {
    return cachedText;
  }

  return 'Conditions unavailable';
}

String _resolveTemperatureText(
  AsyncValue<ResortWeather?> weather,
  ResortSummary resort,
) {
  final liveTemp = weather.valueOrNull?.tempC;
  if (liveTemp != null) {
    return liveTemp.toStringAsFixed(1);
  }

  final cachedTemp = resort.cachedWeatherTempC;
  if (cachedTemp != null) {
    return cachedTemp.toStringAsFixed(1);
  }

  return '--';
}
