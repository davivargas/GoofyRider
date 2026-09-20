import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_constants.dart';
import '../../core/providers/distance_unit_preference_provider.dart';
import '../../core/providers/speed_unit_preference_provider.dart';
import '../../core/providers/vertical_unit_preference_provider.dart';
import '../../core/utils/distance_unit.dart';
import '../../core/utils/duration_formatting.dart';
import '../../core/utils/speed_unit.dart';
import '../../core/utils/vertical_unit.dart';
import '../../core/widgets/design_widgets.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/resorts/domain/resort_models.dart';
import '../../features/resorts/presentation/resort_providers.dart';
import '../../features/session/domain/session_models.dart';
import '../../features/session/presentation/history_view_models.dart';
import '../../features/session/presentation/season_summary.dart';
import '../../features/session/presentation/session_providers.dart';
import '../../features/weather/domain/weather_models.dart';
import '../../features/weather/presentation/weather_providers.dart';
import '../router/route_paths.dart';
import '../theme/app_theme.dart';
import 'app_tab_bar.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final verticalUnit = ref.watch(verticalUnitPreferenceProvider);
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final favorites = ref.watch(favoriteResortsProvider);
    final history = ref.watch(historyProvider);
    final latestSession = ref.watch(latestSessionEntryProvider);
    final unsyncedCount = ref.watch(unsyncedSessionCountProvider);
    final showDebugDiagnostics = kDebugMode && AppConstants.isDebugDiagnostics;
    final t = context.tokens;
    final displayName = authState.session?.user.displayName ?? 'Rider';

    return Scaffold(
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
          padding: EdgeInsets.fromLTRB(
              24,
              MediaQuery.paddingOf(context).top + 18,
              24,
              AppTabBar.bottomClearance(context) + 24),
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Wordmark(size: 18),
                InitialsAvatar(name: displayName),
              ],
            ),
            const SizedBox(height: 26),
            history.when(
              loading: () => const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator())),
              error: (Object error, StackTrace _) =>
                  SurfaceCard(child: Text('Unable to load history: $error')),
              data: (List<LocalRideSession> sessions) => _SeasonHero(
                sessions: sessions,
                verticalUnit: verticalUnit,
                distanceUnit: distanceUnit,
                speedUnit: speedUnit,
              ),
            ),
            if (showDebugDiagnostics)
              unsyncedCount.when(
                data: (int count) => count <= 0
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: SurfaceCard(
                          voltBorder: true,
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.sync_problem, color: t.voltText),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  '$count session(s) pending sync. Open Seasons to retry any failed uploads.',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
            const SizedBox(height: 26),
            latestSession.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
              data: (SessionHistoryEntryViewModel? latest) {
                if (latest == null) {
                  return SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const MonoLabel('No sessions yet',
                            size: 10, tone: MonoTone.muted, letterSpacing: 1.8),
                        const SizedBox(height: 10),
                        Text('Ready for your next run?',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 14),
                        VoltButton(
                            label: 'Start recording',
                            onPressed: () => context.go(RoutePaths.record)),
                      ],
                    ),
                  );
                }
                return _LastSessionCard(entry: latest, speedUnit: speedUnit);
              },
            ),
            const SizedBox(height: 26),
            const MonoLabel('Your mountains', size: 11, letterSpacing: 1.8),
            const SizedBox(height: 12),
            favorites.when(
              loading: () => const SizedBox(
                  height: 110,
                  child: Center(child: CircularProgressIndicator())),
              error: (Object error, StackTrace _) =>
                  SurfaceCard(child: Text('Unable to load favorites: $error')),
              data: (List<ResortSummary> resorts) {
                if (resorts.isEmpty) {
                  return SurfaceCard(
                    child: Text(
                      'No favorites yet. Add some from the Resorts tab.',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: t.textSecondary),
                    ),
                  );
                }
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    for (final ResortSummary resort in resorts)
                      SizedBox(
                        width: (MediaQuery.sizeOf(context).width - 48 - 12) / 2,
                        child: _FavoriteResortCard(resort: resort),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

Widget _heroStat(String value, String label) => StatBlock(
      value: value,
      label: label,
      size: StatSize.large,
      valueSize: 24,
      labelSize: 11,
      labelLetterSpacing: 1.32,
      labelGap: 4,
    );

class _SeasonHero extends StatelessWidget {
  const _SeasonHero(
      {required this.sessions,
      required this.verticalUnit,
      required this.distanceUnit,
      required this.speedUnit});

  final List<LocalRideSession> sessions;
  final VerticalUnit verticalUnit;
  final DistanceUnit distanceUnit;
  final SpeedUnit speedUnit;

  @override
  Widget build(BuildContext context) {
    final summary = buildSeasonSummary(sessions, now: DateTime.now());
    final vert = summary.totalVertM > 0
        ? verticalUnit.convertFromMeters(summary.totalVertM).round().toString()
        : '--';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MonoLabel(
            'Season ${shortSeasonLabel(summary.label)} · ${summary.daysRidden} days ridden',
            size: 11,
            letterSpacing: 1.8),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text(vert, style: Theme.of(context).textTheme.displayLarge),
            const SizedBox(width: 10),
            MonoLabel('${verticalUnit.shortLabel} vert',
                size: 12, tone: MonoTone.volt, letterSpacing: 1.6),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 22,
          runSpacing: 14,
          children: <Widget>[
            _heroStat(
                speedUnit
                    .convertFromMetersPerSecond(summary.topSpeedMps)
                    .toStringAsFixed(1),
                'Top ${speedUnit.shortLabel}'),
            _heroStat(
                distanceUnit
                    .convertFromMeters(summary.totalDistanceM)
                    .toStringAsFixed(1),
                '${distanceUnit.shortLabel.toUpperCase()} dist'),
            _heroStat('${summary.sessionCount}', 'Sessions'),
            _heroStat(formatSecondsAsDuration(summary.rideTimeS), 'Ride time'),
          ],
        ),
      ],
    );
  }
}

class _LastSessionCard extends StatelessWidget {
  const _LastSessionCard({required this.entry, required this.speedUnit});

  final SessionHistoryEntryViewModel entry;
  final SpeedUnit speedUnit;

  @override
  Widget build(BuildContext context) {
    final session = entry.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const MonoLabel('Last session', size: 11, letterSpacing: 1.76),
        const SizedBox(height: 10),
        SessionDayCard(
          date: session.startedAt,
          title: entry.resortLabel,
          dataLine: sessionDataLine(session, speedUnit),
          onTap: session.localId > 0
              ? () => context.go(RoutePaths.sessionDetail
                  .replaceAll(':sessionId', session.localId.toString()))
              : null,
        ),
      ],
    );
  }
}

class _FavoriteResortCard extends ConsumerWidget {
  const _FavoriteResortCard({required this.resort});

  final ResortSummary resort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weather = ref.watch(resortWeatherProvider(resort.id));
    final t = context.tokens;
    final conditions = _resolveConditionsText(weather, resort);
    final temp = _resolveTemperatureText(weather, resort);
    final snow = weather.valueOrNull?.snowfallCm24h;
    final powDay = snow != null && snow >= 10;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      onTap: () => context
          .go(RoutePaths.resortDetail.replaceAll(':resortId', resort.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(resort.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          MonoLabel('$temp · $conditions',
              size: 11, letterSpacing: 0.6, maxLines: 1),
          if (snow != null) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: powDay ? t.volt : t.raised,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: powDay ? t.volt : t.line),
              ),
              child: MonoLabel(
                '${snow.round()} cm · ${powDay ? 'Pow' : '24h'}',
                size: 11,
                weight: FontWeight.w700,
                letterSpacing: 1,
                softWrap: false,
                color: powDay ? t.voltInk : t.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _resolveConditionsText(
    AsyncValue<ResortWeather?> weather, ResortSummary resort) {
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
    AsyncValue<ResortWeather?> weather, ResortSummary resort) {
  final liveTemp = weather.valueOrNull?.tempC;
  if (liveTemp != null) {
    return '${liveTemp.toStringAsFixed(1)}°C';
  }
  final cachedTemp = resort.cachedWeatherTempC;
  if (cachedTemp != null) {
    return '${cachedTemp.toStringAsFixed(1)}°C';
  }
  return '--';
}
