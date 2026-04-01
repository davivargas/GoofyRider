import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/constants/app_constants.dart';
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
import 'session_providers.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  Future<void> _runSyncPass(WidgetRef ref) async {
    await ref.read(recordingControllerProvider.notifier).retryPendingSyncs();
    ref.invalidate(historyProvider);
    ref.invalidate(unsyncedSessionCountProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<LocalRideSession>> history =
        ref.watch(historyProvider);
    final SpeedUnit speedUnit = ref.watch(speedUnitPreferenceProvider);
    final DistanceUnit distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final bool showDebugDiagnostics =
        kDebugMode && AppConstants.isDebugDiagnostics;
    final AsyncValue<int> unsyncedCount = ref.watch(unsyncedSessionCountProvider);

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
          onRetry: () => ref.invalidate(historyProvider),
        ),
        data: (List<LocalRideSession> sessions) {
          if (sessions.isEmpty) {
            return const AppEmptyView(
              title: 'No sessions yet',
              subtitle: 'Record your first run to start your logbook.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              await _runSyncPass(ref);
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(12),
              itemCount: sessions.length,
              itemBuilder: (BuildContext context, int index) {
                final LocalRideSession session = sessions[index];
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
                      session.resortId ?? 'Unknown resort',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      'Duration ${formatSecondsAsDuration(session.activeDurationS)} | Distance ${distanceUnit.formatFromMeters(session.distanceM)}\n'
                      'Max ${speedUnit.formatFromMetersPerSecond(session.maxSpeedMps)}',
                    ),
                    trailing: _HistorySyncActions(
                      session: session,
                      showDebugDiagnostics: showDebugDiagnostics,
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _HistorySyncActions extends ConsumerWidget {
  const _HistorySyncActions({
    required this.session,
    required this.showDebugDiagnostics,
  });

  final LocalRideSession session;
  final bool showDebugDiagnostics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool canSync = session.localId > 0 && session.isUnsynced && !session.isInProgress;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showDebugDiagnostics || canSync) ...<Widget>[
          _SyncBadge(state: session.state),
          const SizedBox(width: 8),
        ],
        if (canSync)
          IconButton(
            tooltip: 'Sync now',
            onPressed: () async {
              await ref.read(sessionRepositoryProvider).syncSession(session.localId);
              ref.invalidate(historyProvider);
              ref.invalidate(unsyncedSessionCountProvider);
              ref.invalidate(sessionDetailProvider(session.localId));
            },
            icon: const Icon(Icons.sync),
          ),
      ],
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

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.state});

  final LocalSessionState state;

  @override
  Widget build(BuildContext context) {
    final (Color color, String text) = switch (state) {
      LocalSessionState.synced => (Colors.green, 'Synced'),
      LocalSessionState.syncPending => (Colors.orange, 'Pending'),
      LocalSessionState.syncFailed => (Colors.redAccent, 'Failed'),
      LocalSessionState.syncing => (Colors.lightBlue, 'Syncing'),
      _ => (Colors.orange, 'Pending'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
