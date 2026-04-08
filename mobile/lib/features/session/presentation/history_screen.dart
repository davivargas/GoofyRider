import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/date_time_formatting.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/duration_formatting.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/widgets/app_empty_view.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../domain/session_models.dart';
import 'history_view_models.dart';
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
    final AsyncValue<List<SessionHistorySeasonSection>> history =
        ref.watch(historySectionsProvider);
    final SpeedUnit speedUnit = ref.watch(speedUnitPreferenceProvider);
    final DistanceUnit distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final AsyncValue<int> unsyncedCount =
        ref.watch(unsyncedSessionCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: <Widget>[
          unsyncedCount.maybeWhen(
            data: (int count) => count > 0
                ? IconButton(
                    tooltip: 'Sync unsynced sessions',
                    onPressed: () async {
                      await _runSyncPass(ref);
                    },
                    icon: const Icon(Icons.sync),
                  )
                : const SizedBox.shrink(),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: history.when(
        loading: () => const AppLoadingView(label: 'Loading sessions...'),
        error: (Object error, StackTrace _) => AppErrorView(
          message: error.toString(),
          onRetry: () {
            ref.invalidate(historyProvider);
            ref.invalidate(historySectionsProvider);
          },
        ),
        data: (List<SessionHistorySeasonSection> sections) {
          final int totalSessions = sections.fold<int>(
            0,
            (int count, SessionHistorySeasonSection section) =>
                count + section.items.length,
          );
          if (totalSessions == 0) {
            return const AppEmptyView(
              title: 'No sessions yet',
              subtitle: 'Record your first run to start your logbook.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              await _runSyncPass(ref);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              children: sections
                  .expand(
                    (SessionHistorySeasonSection section) => <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        child: Text(
                          section.label,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      ...section.items.map(
                        (SessionHistoryEntryViewModel item) =>
                            _HistorySessionCard(
                          item: item,
                          speedUnit: speedUnit,
                          distanceUnit: distanceUnit,
                        ),
                      ),
                    ],
                  )
                  .toList(growable: false),
            ),
          );
        },
      ),
    );
  }
}

class _HistorySessionCard extends ConsumerWidget {
  const _HistorySessionCard({
    required this.item,
    required this.speedUnit,
    required this.distanceUnit,
  });

  final SessionHistoryEntryViewModel item;
  final SpeedUnit speedUnit;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LocalRideSession session = item.session;
    final bool canSync =
        session.localId > 0 && session.isUnsynced && !session.isInProgress;
    final String syncLabel = switch (session.state) {
      LocalSessionState.synced => 'Synced',
      LocalSessionState.syncPending => 'Pending',
      LocalSessionState.syncFailed => 'Failed',
      LocalSessionState.syncing => 'Syncing',
      _ => 'Pending',
    };

    return Card(
      child: ListTile(
        onTap: session.localId > 0
            ? () => context.go(
                  RoutePaths.sessionDetail.replaceAll(
                    ':sessionId',
                    session.localId.toString(),
                  ),
                )
            : null,
        leading: _SessionDateBox(date: session.startedAt),
        title: Text(
          item.resortLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'Duration ${formatSecondsAsDuration(session.activeDurationS)} | Distance ${distanceUnit.formatFromMeters(session.distanceM)}\n'
          'Max ${speedUnit.formatFromMetersPerSecond(session.maxSpeedMps)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _SyncBadge(label: syncLabel, state: session.state),
            if (canSync) ...<Widget>[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Sync now',
                onPressed: () => _syncNow(ref, session),
                icon: const Icon(Icons.sync),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _syncNow(WidgetRef ref, LocalRideSession session) async {
    await ref.read(sessionRepositoryProvider).syncSession(session.localId);
    ref.invalidate(historyProvider);
    ref.invalidate(historySectionsProvider);
    ref.invalidate(unsyncedSessionCountProvider);
    ref.invalidate(sessionDetailProvider(session.localId));
  }
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({
    required this.label,
    required this.state,
  });

  final String label;
  final LocalSessionState state;

  @override
  Widget build(BuildContext context) {
    final Color color = switch (state) {
      LocalSessionState.synced => Colors.green,
      LocalSessionState.syncing => Colors.lightBlue,
      LocalSessionState.syncFailed => Colors.redAccent,
      _ => Colors.orange,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SessionDateBox extends StatelessWidget {
  const _SessionDateBox({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF123048),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        date.toDayLabel(),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
