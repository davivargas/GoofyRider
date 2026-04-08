import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/errors/failures.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/date_time_formatting.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/duration_formatting.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../domain/session_models.dart';
import '../domain/session_repository.dart';
import 'session_providers.dart';

class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({
    super.key,
    required this.localSessionId,
  });

  final int localSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<SessionDetail> detail =
        ref.watch(sessionDetailProvider(localSessionId));
    final SpeedUnit speedUnit = ref.watch(speedUnitPreferenceProvider);
    final DistanceUnit distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final bool showDebugDiagnostics =
        kDebugMode && AppConstants.isDebugDiagnostics;
    final String appBarTitle = detail.maybeWhen(
      data: (SessionDetail data) => data.session.startedAt.toDayLabel(),
      orElse: () => 'Session detail',
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(appBarTitle),
        actions: <Widget>[
          detail.maybeWhen(
            data: (SessionDetail data) => PopupMenuButton<_SessionDetailAction>(
              tooltip: 'Session actions',
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<_SessionDetailAction>>[
                const PopupMenuItem<_SessionDetailAction>(
                  value: _SessionDetailAction.delete,
                  child: Text(
                    'Delete session',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
              onSelected: (_SessionDetailAction action) async {
                if (action != _SessionDetailAction.delete) {
                  return;
                }

                final bool confirmed = await _confirmDelete(context);
                if (!confirmed) {
                  return;
                }

                try {
                  final DeleteSessionResult result = await ref
                      .read(sessionRepositoryProvider)
                      .deleteSession(data.session);

                  ref.invalidate(historyProvider);
                  ref.invalidate(historySectionsProvider);
                  ref.invalidate(unsyncedSessionCountProvider);
                  ref.invalidate(sessionDetailProvider(localSessionId));

                  if (context.mounted) {
                    if (result.queuedRemoteDelete) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Session removed locally. Server deletion will retry when the backend is reachable.',
                          ),
                        ),
                      );
                    }
                    final GoRouter? router = GoRouter.maybeOf(context);
                    if (router != null) {
                      router.go(RoutePaths.history);
                    } else {
                      Navigator.of(context).pop();
                    }
                  }
                } catch (error) {
                  final String message = switch (error) {
                    AppFailure failure => failure.message,
                    _ => error.toString(),
                  };

                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to delete session: $message'),
                      ),
                    );
                  }
                }
              },
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: detail.when(
        loading: () => const AppLoadingView(label: 'Loading details...'),
        error: (Object error, StackTrace _) => AppErrorView(
          message: error.toString(),
          onRetry: () => ref.invalidate(sessionDetailProvider(localSessionId)),
        ),
        data: (SessionDetail data) {
          final LocalRideSession session = data.session;

          return ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              Card(
                child: ListTile(
                  title: Text(
                    session.startedAt.toDayLabel(),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle:
                      Text('Started at ${session.startedAt.toTimeLabel()}'),
                ),
              ),
              const SizedBox(height: 12),
              _summaryCards(data, speedUnit, distanceUnit),
              const SizedBox(height: 12),
              _mapReplay(data),
              const SizedBox(height: 12),
              _timelineCard(data, distanceUnit),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  title: const Text('Route metadata'),
                  subtitle: Text(
                    'Point count: ${data.points.length}\n'
                    'Accepted for analytics: ${data.acceptedPoints.length}\n'
                    'Origin: ${session.remoteId != null ? 'Local+Server' : 'Local only'}',
                  ),
                ),
              ),
              if (data.trackingDiagnostics.isNotEmpty)
                Card(
                  child: ListTile(
                    title: const Text('Tracking diagnostics'),
                    subtitle: Text(
                      data.trackingDiagnostics
                          .take(16)
                          .map(_diagnosticLine)
                          .join('\n'),
                    ),
                  ),
                ),
              if (showDebugDiagnostics)
                Card(
                  child: ListTile(
                    title: const Text('Diagnostics'),
                    subtitle: Text(
                      'Raw points: ${data.points.length}\n'
                      'Filtered points: ${data.acceptedPoints.length}\n'
                      'Upload state: ${session.state.wireValue}\n'
                      'Last sync error: ${session.lastSyncError ?? 'None'}\n'
                      'Tracking events: ${data.trackingDiagnostics.length}',
                    ),
                  ),
                ),
              if (session.localId > 0 &&
                  session.isUnsynced &&
                  !session.isInProgress)
                FilledButton(
                  onPressed: () async {
                    await ref
                        .read(sessionRepositoryProvider)
                        .syncSession(localSessionId);
                    ref.invalidate(sessionDetailProvider(localSessionId));
                    ref.invalidate(historyProvider);
                    ref.invalidate(unsyncedSessionCountProvider);
                  },
                  child: Text(
                    session.state == LocalSessionState.syncFailed
                        ? 'Retry sync'
                        : 'Sync now',
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCards(
    SessionDetail detail,
    SpeedUnit speedUnit,
    DistanceUnit distanceUnit,
  ) {
    final SessionStats stats = detail.stats;
    final bool hasSegmentBreakdown = detail.timeline.isNotEmpty ||
        stats.descentDurationS > 0 ||
        stats.liftDurationS > 0 ||
        stats.idleDurationS > 0;
    final int rideDurationS =
        hasSegmentBreakdown ? stats.descentDurationS : stats.durationS;
    final String liftDuration = hasSegmentBreakdown
        ? formatSecondsAsDuration(stats.liftDurationS)
        : '--';
    final String idleDuration = hasSegmentBreakdown
        ? formatSecondsAsDuration(stats.idleDurationS)
        : '--';
    final double rideDistanceM =
        hasSegmentBreakdown ? stats.descentDistanceM : stats.distanceM;
    final double rideAvgSpeedMps =
        hasSegmentBreakdown ? stats.rideAvgSpeedMps : stats.avgSpeedMps;

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _summaryCard('Session', formatSecondsAsDuration(stats.durationS)),
        _summaryCard('Ride time', formatSecondsAsDuration(rideDurationS)),
        _summaryCard('Lift', liftDuration),
        _summaryCard('Idle', idleDuration),
        _summaryCard(
          'Ride distance',
          distanceUnit.formatFromMeters(rideDistanceM),
        ),
        _summaryCard(
          'Total route',
          distanceUnit.formatFromMeters(stats.distanceM),
        ),
        _summaryCard(
          'Max speed',
          speedUnit.formatFromMetersPerSecond(stats.maxSpeedMps),
        ),
        _summaryCard(
          'Ride avg',
          speedUnit.formatFromMetersPerSecond(rideAvgSpeedMps),
        ),
      ],
    );
  }

  Widget _summaryCard(String title, String value) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF123048),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _mapReplay(SessionDetail detail) {
    final List<LocalSessionPoint> routePoints = detail.acceptedPoints.isNotEmpty
        ? detail.acceptedPoints
        : detail.points;
    if (routePoints.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No route points available.'),
        ),
      );
    }

    final List<LatLng> route = routePoints
        .map(
          (LocalSessionPoint point) => LatLng(
            point.filteredLatitude ?? point.latitude,
            point.filteredLongitude ?? point.longitude,
          ),
        )
        .toList(growable: false);
    final List<Polyline> polylines = detail.timeline.isEmpty
        ? <Polyline>[
            Polyline(
              points: route,
              strokeWidth: 4,
              color: const Color(0xFF59C3FF),
            ),
          ]
        : detail.timeline
            .where(
                (SessionTimelineSegment segment) => segment.points.length >= 2)
            .map(
              (SessionTimelineSegment segment) => Polyline(
                points: segment.points
                    .map(
                      (LocalSessionPoint point) => LatLng(
                        point.filteredLatitude ?? point.latitude,
                        point.filteredLongitude ?? point.longitude,
                      ),
                    )
                    .toList(growable: false),
                strokeWidth: 5,
                color: _segmentColor(segment.type),
              ),
            )
            .toList(growable: false);

    return SizedBox(
      height: 260,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: FlutterMap(
          options: MapOptions(initialCenter: route.first, initialZoom: 12),
          children: <Widget>[
            TileLayer(
              urlTemplate: MapTileProviderConfig.openStreetMap.urlTemplate,
              subdomains: MapTileProviderConfig.openStreetMap.subdomains,
              userAgentPackageName: 'com.goofyrider.mobile',
            ),
            PolylineLayer(
              polylines: polylines,
            ),
            MarkerLayer(
              markers: <Marker>[
                Marker(
                  point: route.last,
                  width: 30,
                  height: 30,
                  child: const Icon(Icons.flag, size: 22),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _timelineCard(SessionDetail detail, DistanceUnit distanceUnit) {
    if (detail.timeline.isEmpty) {
      return const Card(
        child: ListTile(
          title: Text('Timeline'),
          subtitle: Text(
            'Motion segments are not available for this session yet.',
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Timeline',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ...detail.timeline.map(
              (SessionTimelineSegment segment) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(top: 5, right: 10),
                      decoration: BoxDecoration(
                        color: _segmentColor(segment.type),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${segment.type.label}  ${segment.startedAt.toTimeLabel()} - ${segment.endedAt.toTimeLabel()}\n'
                        '${formatSecondsAsDuration(segment.durationS)} | ${distanceUnit.formatFromMeters(segment.distanceM)}',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _segmentColor(SessionActivityType type) {
    switch (type) {
      case SessionActivityType.descent:
        return const Color(0xFF59C3FF);
      case SessionActivityType.lift:
        return const Color(0xFFFFB347);
      case SessionActivityType.idle:
        return const Color(0xFF94A3B8);
    }
  }

  String _diagnosticLine(TrackingDiagnosticEvent event) {
    final String stamp =
        event.occurredAt.toLocal().toIso8601String().substring(11, 19);
    final String details = event.details.isEmpty ? '' : ' ${event.details}';
    final String message = event.message == null ? '' : ' (${event.message})';
    return '[$stamp] ${event.eventType}$message$details';
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
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
              child: const Text(
                'Delete',
                style: TextStyle(color: Colors.red),
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
