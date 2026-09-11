import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/shell/app_tab_bar.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/duration_formatting.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/widgets/app_empty_view.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../../../core/widgets/design_widgets.dart';
import '../domain/session_models.dart';
import 'history_view_models.dart';
import 'season_summary.dart';
import 'session_providers.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  Future<void> _runSyncPass(WidgetRef ref) async {
    await ref.read(recordingControllerProvider.notifier).retryPendingSyncs();
    ref.invalidate(historyProvider);
    ref.invalidate(historySectionsProvider);
    ref.invalidate(unsyncedSessionCountProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historySectionsProvider);
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final unsyncedCount = ref.watch(unsyncedSessionCountProvider);
    final t = context.tokens;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text('SEASONS', style: Theme.of(context).textTheme.headlineSmall),
                  unsyncedCount.maybeWhen(
                    data: (int count) => count > 0
                        ? IconButton(
                            tooltip: 'Sync unsynced sessions',
                            onPressed: () async => _runSyncPass(ref),
                            icon: Icon(Icons.sync, color: t.ice),
                          )
                        : const SizedBox.shrink(),
                    orElse: () => const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: history.when(
                loading: () => const AppLoadingView(label: 'Loading sessions...'),
                error: (Object error, StackTrace _) => AppErrorView(
                  message: error.toString(),
                  onRetry: () {
                    ref.invalidate(historyProvider);
                    ref.invalidate(historySectionsProvider);
                  },
                ),
                data: (List<SessionHistorySeasonSection> sections) {
                  final totalSessions = sections.fold<int>(0, (int c, SessionHistorySeasonSection s) => c + s.items.length);
                  if (totalSessions == 0) {
                    return const AppEmptyView(title: 'No sessions yet', subtitle: 'Record your first run to start your logbook.');
                  }
                  return RefreshIndicator(
                    onRefresh: () async => _runSyncPass(ref),
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(24, 8, 24, AppTabBar.height + 24),
                      children: <Widget>[
                        for (final SessionHistorySeasonSection section in sections) ...<Widget>[
                          _SeasonHeader(section: section, distanceUnit: distanceUnit, speedUnit: speedUnit),
                          for (final SessionHistoryEntryViewModel item in section.items)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: _HistorySessionCard(item: item, speedUnit: speedUnit, distanceUnit: distanceUnit),
                            ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader({required this.section, required this.distanceUnit, required this.speedUnit});

  final SessionHistorySeasonSection section;
  final DistanceUnit distanceUnit;
  final SpeedUnit speedUnit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final sessions = section.items.map((SessionHistoryEntryViewModel i) => i.session).toList(growable: false);
    final days = sessions.map((LocalRideSession s) {
      final d = s.startedAt.toLocal();
      return '${d.year}-${d.month}-${d.day}';
    }).toSet().length;
    final vert = sessions.fold<int>(0, (int a, LocalRideSession s) => a + (s.elevationLossM ?? 0));
    final top = sessions.fold<double>(0, (double a, LocalRideSession s) => s.maxSpeedMps > a ? s.maxSpeedMps : a);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(
            shortSeasonLabel(section.label),
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 1.2
                    ..color = t.voltText,
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: MonoLabel(
              '$days days · ${distanceUnit.formatFromMeters(vert.toDouble())} vert · ${speedUnit.formatFromMetersPerSecond(top)} top',
              size: 8,
              tone: MonoTone.muted,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistorySessionCard extends StatelessWidget {
  const _HistorySessionCard({required this.item, required this.speedUnit, required this.distanceUnit});

  final SessionHistoryEntryViewModel item;
  final SpeedUnit speedUnit;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final session = item.session;
    final local = session.startedAt.toLocal();
    final (String syncLabel, Color syncColor) = switch (session.state) {
      LocalSessionState.synced => ('● Synced', t.ice),
      LocalSessionState.syncing => ('◌ Syncing', t.textSecondary),
      LocalSessionState.syncFailed => ('! Failed', t.rec),
      _ => ('○ Local only', t.textSecondary),
    };

    return SurfaceCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      onTap: session.localId > 0
          ? () => context.go(RoutePaths.sessionDetail.replaceAll(':sessionId', session.localId.toString()))
          : null,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Column(
              children: <Widget>[
                Text('${local.day}', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 14)),
                MonoLabel(DateFormat('MMM').format(local), size: 8, tone: MonoTone.muted, letterSpacing: 1),
              ],
            ),
          ),
          Container(width: 1, height: 36, color: t.line),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.resortLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                MonoLabel(
                  '${formatSecondsAsDuration(session.activeDurationS)} · ${distanceUnit.formatFromMeters(session.distanceM)} · ${speedUnit.formatFromMetersPerSecond(session.maxSpeedMps)} max',
                  size: 8,
                  letterSpacing: 0.8,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          MonoLabel(syncLabel, size: 7, weight: FontWeight.w700, letterSpacing: 1.1, color: syncColor),
        ],
      ),
    );
  }
}
