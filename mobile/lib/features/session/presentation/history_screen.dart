import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/providers/vertical_unit_preference_provider.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/utils/vertical_unit.dart';
import '../../../core/widgets/app_empty_view.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../../../core/widgets/design_widgets.dart';
import '../domain/session_models.dart';
import 'history_view_models.dart';
import 'season_summary.dart';
import 'session_providers.dart';
import '../../../app/shell/app_tab_bar.dart';

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
    final verticalUnit = ref.watch(verticalUnitPreferenceProvider);
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
                  Text('SEASONS',
                      style: Theme.of(context).textTheme.headlineSmall),
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
                loading: () =>
                    const AppLoadingView(label: 'Loading sessions...'),
                error: (Object error, StackTrace _) => AppErrorView(
                  message: error.toString(),
                  onRetry: () {
                    ref.invalidate(historyProvider);
                    ref.invalidate(historySectionsProvider);
                  },
                ),
                data: (List<SessionHistorySeasonSection> sections) {
                  final totalSessions = sections.fold<int>(
                      0,
                      (int c, SessionHistorySeasonSection s) =>
                          c + s.items.length);
                  if (totalSessions == 0) {
                    return const AppEmptyView(
                        title: 'No sessions yet',
                        subtitle:
                            'Record your first run to start your logbook.');
                  }
                  return RefreshIndicator(
                    onRefresh: () async => _runSyncPass(ref),
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                          24, 8, 24, AppTabBar.bottomClearance(context) + 24),
                      children: <Widget>[
                        for (final SessionHistorySeasonSection section
                            in sections) ...<Widget>[
                          _SeasonHeader(
                              section: section,
                              verticalUnit: verticalUnit,
                              speedUnit: speedUnit),
                          for (final SessionHistoryEntryViewModel item
                              in section.items)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: _HistorySessionCard(
                                  item: item, speedUnit: speedUnit),
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
  const _SeasonHeader(
      {required this.section,
      required this.verticalUnit,
      required this.speedUnit});

  final SessionHistorySeasonSection section;
  final VerticalUnit verticalUnit;
  final SpeedUnit speedUnit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final sessions = section.items
        .map((SessionHistoryEntryViewModel i) => i.session)
        .toList(growable: false);
    final days = sessions
        .map((LocalRideSession s) {
          final d = s.startedAt.toLocal();
          return '${d.year}-${d.month}-${d.day}';
        })
        .toSet()
        .length;
    final vert = sessions.fold<int>(
        0, (int a, LocalRideSession s) => a + (s.elevationLossM ?? 0));
    final top = sessions.fold<double>(
        0,
        (double a, LocalRideSession s) =>
            s.maxSpeedMps > a ? s.maxSpeedMps : a);
    final vertLabel = NumberFormat('#,###')
        .format(verticalUnit.convertFromMeters(vert.toDouble()).round());
    final topLabel =
        speedUnit.convertFromMetersPerSecond(top).toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(
            shortSeasonLabel(section.label),
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontSize: 26,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 1.2
                    ..color = t.voltText,
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: MonoLabel(
              '$days ${days == 1 ? 'day' : 'days'} · $vertLabel ${verticalUnit.shortLabel} · MAX $topLabel ${speedUnit.shortLabel}',
              size: 13,
              letterSpacing: 0.78,
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistorySessionCard extends StatelessWidget {
  const _HistorySessionCard({required this.item, required this.speedUnit});

  final SessionHistoryEntryViewModel item;
  final SpeedUnit speedUnit;

  @override
  Widget build(BuildContext context) {
    final session = item.session;
    return SessionDayCard(
      date: session.startedAt,
      title: item.resortLabel,
      dataLine: sessionDataLine(session, speedUnit),
      onTap: session.localId > 0
          ? () => context.go(RoutePaths.sessionDetail
              .replaceAll(':sessionId', session.localId.toString()))
          : null,
    );
  }
}
