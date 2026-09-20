import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/errors/failures.dart';
import '../../../core/providers.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/date_time_formatting.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/duration_formatting.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../../../core/widgets/design_widgets.dart';
import '../../../core/widgets/map_attribution.dart';
import '../domain/session_models.dart';
import '../domain/session_repository.dart';
import 'session_providers.dart';
import '../../../app/shell/app_tab_bar.dart';

class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({
    super.key,
    required this.localSessionId,
  });

  final int localSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sessionDetailProvider(localSessionId));
    final resortLabel =
        ref.watch(sessionResortLabelProvider(localSessionId)).valueOrNull;
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final activeMapTileProviderConfig =
        ref.watch(activeMapTileProviderConfigProvider);
    final tileProvider = ref.watch(mapTileProviderProvider);
    final showDebugDiagnostics = kDebugMode && AppConstants.isDebugDiagnostics;
    final t = context.tokens;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: detail.when(
          loading: () => const AppLoadingView(label: 'Loading details...'),
          error: (Object error, StackTrace _) => AppErrorView(
            message: error.toString(),
            onRetry: () {
              ref.invalidate(sessionDetailProvider(localSessionId));
              ref.invalidate(sessionResortLabelProvider(localSessionId));
            },
          ),
          data: (SessionDetail data) {
            final session = data.session;
            final runs = data.timeline
                .where((SessionTimelineSegment s) =>
                    s.type == SessionActivityType.descent)
                .length;
            final vert = session.elevationLossM;
            return ListView(
              padding: EdgeInsets.fromLTRB(
                  24, 16, 24, AppTabBar.bottomClearance(context) + 24),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: 'Back',
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        final router = GoRouter.maybeOf(context);
                        if (router != null) {
                          router.go(RoutePaths.history);
                        } else {
                          Navigator.of(context).maybePop();
                        }
                      },
                      icon: Icon(Icons.arrow_back, color: t.textSecondary),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(resortLabel ?? 'Session',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 2),
                          MonoLabel(
                              '${session.startedAt.toDayLabel()} · ${session.startedAt.toTimeLabel()}',
                              size: 10,
                              tone: MonoTone.muted,
                              letterSpacing: 1.6),
                        ],
                      ),
                    ),
                    PopupMenuButton<_SessionDetailAction>(
                      tooltip: 'Session actions',
                      icon: Icon(Icons.more_vert, color: t.textSecondary),
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<_SessionDetailAction>>[
                        PopupMenuItem<_SessionDetailAction>(
                          value: _SessionDetailAction.delete,
                          child: Text('Delete session',
                              style: TextStyle(color: t.rec)),
                        ),
                      ],
                      onSelected: (_SessionDetailAction action) =>
                          _onAction(context, ref, action, data),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Text(
                            vert == null
                                ? '--'
                                : distanceUnit
                                    .convertFromMeters(vert.toDouble())
                                    .round()
                                    .toString(),
                            style: Theme.of(context).textTheme.displayMedium),
                        const SizedBox(width: 8),
                        MonoLabel('${distanceUnit.shortLabel} vert',
                            size: 10, tone: MonoTone.volt, letterSpacing: 1.6),
                      ],
                    ),
                    const SizedBox(width: 22),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 18,
                          children: <Widget>[
                            _detailStat(
                                speedUnit
                                    .convertFromMetersPerSecond(
                                        data.stats.maxSpeedMps)
                                    .toStringAsFixed(1),
                                'Max'),
                            _detailStat(
                                distanceUnit
                                    .formatFromMeters(data.stats.distanceM),
                                'Dist'),
                            _detailStat('$runs', 'Runs'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _timeSplit(context, data),
                const SizedBox(height: 18),
                _mapReplay(
                    context, data, activeMapTileProviderConfig, tileProvider),
                const SizedBox(height: 20),
                _timeline(context, data, distanceUnit, speedUnit),
                if (session.localId > 0 &&
                    session.isUnsynced &&
                    !session.isInProgress) ...<Widget>[
                  const SizedBox(height: 18),
                  VoltButton(
                    label: session.state == LocalSessionState.syncFailed
                        ? 'Retry sync'
                        : 'Sync now',
                    onPressed: () async {
                      await ref
                          .read(sessionRepositoryProvider)
                          .syncSession(localSessionId);
                      ref.invalidate(sessionDetailProvider(localSessionId));
                      ref.invalidate(
                          sessionResortLabelProvider(localSessionId));
                      ref.invalidate(historyProvider);
                      ref.invalidate(unsyncedSessionCountProvider);
                    },
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _onAction(BuildContext context, WidgetRef ref,
      _SessionDetailAction action, SessionDetail data) async {
    if (action != _SessionDetailAction.delete) {
      return;
    }
    final confirmed = await _confirmDelete(context);
    if (!confirmed) {
      return;
    }
    try {
      final result =
          await ref.read(sessionRepositoryProvider).deleteSession(data.session);
      ref.invalidate(historyProvider);
      ref.invalidate(historySectionsProvider);
      ref.invalidate(unsyncedSessionCountProvider);
      ref.invalidate(sessionDetailProvider(localSessionId));
      ref.invalidate(sessionResortLabelProvider(localSessionId));
      if (context.mounted) {
        if (result.queuedRemoteDelete) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Session removed locally. Server deletion will retry when the backend is reachable.'),
            ),
          );
        }
        final router = GoRouter.maybeOf(context);
        if (router != null) {
          router.go(RoutePaths.history);
        } else {
          Navigator.of(context).pop();
        }
      }
    } catch (error) {
      final message = switch (error) {
        final AppFailure failure => failure.message,
        _ => error.toString(),
      };
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete session: $message')));
      }
    }
  }

  Widget _detailStat(String value, String label) => StatBlock(
        value: value,
        label: label,
        size: StatSize.large,
        valueSize: 24,
        labelSize: 11,
        labelGap: 3,
      );

  Widget _timeSplit(BuildContext context, SessionDetail data) {
    final t = context.tokens;
    final stats = data.stats;
    final hasSplit = data.timeline.isNotEmpty ||
        stats.descentDurationS > 0 ||
        stats.liftDurationS > 0 ||
        stats.idleDurationS > 0;
    final total = hasSplit
        ? (stats.descentDurationS + stats.liftDurationS + stats.idleDurationS)
        : stats.durationS;
    int flex(int s) => total == 0 ? 1 : (s * 1000 ~/ total).clamp(1, 1000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            MonoLabel(
                'Time split · ${formatSecondsAsDuration(stats.durationS)}',
                size: 10,
                tone: MonoTone.muted),
            Row(
              children: <Widget>[
                MonoLabel('■ Ride', size: 10, color: t.voltText),
                const SizedBox(width: 8),
                MonoLabel('■ Lift', size: 10, color: t.ice),
                const SizedBox(width: 8),
                const MonoLabel('■ Idle', size: 10, tone: MonoTone.muted),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: SizedBox(
            height: 10,
            child: hasSplit
                ? Row(
                    children: <Widget>[
                      Expanded(
                          flex: flex(stats.descentDurationS),
                          child: ColoredBox(color: t.descent)),
                      const SizedBox(width: 2),
                      Expanded(
                          flex: flex(stats.liftDurationS),
                          child: ColoredBox(color: t.lift)),
                      const SizedBox(width: 2),
                      Expanded(
                          flex: flex(stats.idleDurationS),
                          child: ColoredBox(color: t.idle)),
                    ],
                  )
                : ColoredBox(color: t.descent),
          ),
        ),
        if (!hasSplit) ...<Widget>[
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            children: <Widget>[
              StatBlock(
                  value: formatSecondsAsDuration(stats.durationS),
                  label: 'Ride time',
                  size: StatSize.small),
            ],
          ),
        ],
      ],
    );
  }

  Widget _mapReplay(
      BuildContext context,
      SessionDetail detail,
      MapTileProviderConfig activeMapTileProviderConfig,
      TileProvider? tileProvider) {
    final t = context.tokens;
    final routePoints = detail.acceptedPoints.isNotEmpty
        ? detail.acceptedPoints
        : detail.points;
    if (routePoints.isEmpty) {
      return const SurfaceCard(
          child: MonoLabel('No route points available.',
              size: 11, uppercase: false, tone: MonoTone.muted));
    }
    LatLng toLatLng(LocalSessionPoint p) => LatLng(
        p.filteredLatitude ?? p.latitude, p.filteredLongitude ?? p.longitude);
    final route = routePoints.map(toLatLng).toList(growable: false);
    final polylines = detail.timeline.isEmpty
        ? <Polyline>[Polyline(points: route, strokeWidth: 3, color: t.descent)]
        : detail.timeline
            .where((SessionTimelineSegment s) => s.points.length >= 2)
            .map(
              (SessionTimelineSegment s) => Polyline(
                points: s.points.map(toLatLng).toList(growable: false),
                strokeWidth: s.type == SessionActivityType.descent ? 3 : 2,
                color: segmentColor(t, s.type),
                pattern: s.type == SessionActivityType.lift
                    ? const StrokePattern.dotted(spacingFactor: 3)
                    : const StrokePattern.solid(),
              ),
            )
            .toList(growable: false);

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 210,
        decoration: BoxDecoration(
            border: Border.all(color: t.line),
            borderRadius: BorderRadius.circular(18)),
        child: Stack(
          children: <Widget>[
            FlutterMap(
              options: MapOptions(initialCenter: route.first, initialZoom: 14),
              children: <Widget>[
                TileLayer(
                  urlTemplate: activeMapTileProviderConfig.urlTemplate,
                  subdomains: activeMapTileProviderConfig.subdomains,
                  retinaMode: activeMapTileProviderConfig.retinaMode,
                  userAgentPackageName: 'com.fallline.mobile',
                  tileProvider: tileProvider,
                ),
                PolylineLayer(polylines: polylines),
                MarkerLayer(
                  markers: <Marker>[
                    Marker(
                        point: route.first,
                        width: 8,
                        height: 8,
                        child: DecoratedBox(
                            decoration: BoxDecoration(
                                color: t.text, shape: BoxShape.circle))),
                    Marker(
                        point: route.last,
                        width: 10,
                        height: 10,
                        child: DecoratedBox(
                            decoration: BoxDecoration(
                                color: t.volt, shape: BoxShape.circle))),
                  ],
                ),
                MapAttribution(config: activeMapTileProviderConfig),
              ],
            ),
            const Positioned(
                left: 12, bottom: 10, child: MonoLabel('Full route', size: 10)),
          ],
        ),
      ),
    );
  }

  Widget _timeline(BuildContext context, SessionDetail detail,
      DistanceUnit distanceUnit, SpeedUnit speedUnit) {
    final t = context.tokens;
    if (detail.timeline.isEmpty) {
      return SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const MonoLabel('Timeline', size: 11, letterSpacing: 1.8),
            const SizedBox(height: 8),
            Text('Motion segments are not available for this session yet.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: t.textSecondary)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const MonoLabel('Timeline', size: 11, letterSpacing: 1.8),
        const SizedBox(height: 6),
        for (final SessionTimelineSegment segment in detail.timeline)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.line))),
            child: Row(
              children: <Widget>[
                SegmentSwatch(type: segment.type),
                const SizedBox(width: 12),
                SizedBox(
                    width: 64,
                    child: MonoLabel(
                        segment.type == SessionActivityType.descent
                            ? 'Ride'
                            : segment.type.label,
                        size: 10,
                        weight: FontWeight.w700,
                        tone: MonoTone.primary)),
                MonoLabel(
                    '${segment.startedAt.toTimeLabel()}–${segment.endedAt.toTimeLabel()}',
                    size: 9,
                    tone: MonoTone.muted,
                    letterSpacing: 0.4,
                    uppercase: false),
                const Spacer(),
                MonoLabel(
                    '${formatSecondsAsDuration(segment.durationS)} · ${distanceUnit.formatFromMeters(segment.distanceM)}',
                    size: 9,
                    letterSpacing: 0.4),
              ],
            ),
          ),
      ],
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete session?'),
          content: const Text(
            'This removes the session from your history.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                'Delete',
                style: TextStyle(color: context.tokens.rec),
              ),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }
}

enum _SessionDetailAction { delete }
