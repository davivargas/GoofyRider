import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/widgets/app_empty_view.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../domain/session_models.dart';
import 'session_providers.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<LocalRideSession>> history =
        ref.watch(historyProvider);
    final SpeedUnit speedUnit = ref.watch(speedUnitPreferenceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
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
              await ref
                  .read(recordingControllerProvider.notifier)
                  .retryPendingSyncs();
              ref.invalidate(historyProvider);
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
                    title: Text(
                      session.resortId ?? 'Unknown resort',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      'Duration ${session.activeDurationS}s | Distance ${session.distanceM.toStringAsFixed(0)}m\n'
                      'Max ${speedUnit.formatFromMetersPerSecond(session.maxSpeedMps)}',
                    ),
                    trailing: _SyncBadge(state: session.state),
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
