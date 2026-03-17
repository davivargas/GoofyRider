import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('Session detail')),
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
              _summaryCards(session),
              const SizedBox(height: 12),
              _mapReplay(data.acceptedPoints),
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
              if (kDebugMode && AppConstants.isDebugDiagnostics)
                Card(
                  child: ListTile(
                    title: const Text('Diagnostics'),
                    subtitle: Text(
                      'Raw points: ${data.points.length}\n'
                      'Filtered points: ${data.acceptedPoints.length}\n'
                      'Upload state: ${session.state.wireValue}\n'
                      'Last sync error: ${session.lastSyncError ?? 'None'}',
                    ),
                  ),
                ),
              if (session.state == LocalSessionState.syncFailed)
                FilledButton(
                  onPressed: () async {
                    await ref
                        .read(sessionRepositoryProvider)
                        .retryFailedSync(localSessionId);
                    ref.invalidate(sessionDetailProvider(localSessionId));
                  },
                  child: const Text('Retry sync'),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCards(LocalRideSession session) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _summaryCard('Duration', '${session.activeDurationS}s'),
        _summaryCard('Distance', '${session.distanceM.toStringAsFixed(0)}m'),
        _summaryCard(
            'Max speed', '${session.maxSpeedMps.toStringAsFixed(1)} m/s'),
        _summaryCard(
            'Avg speed', '${session.avgSpeedMps.toStringAsFixed(1)} m/s'),
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
          Text(value,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _mapReplay(List<LocalSessionPoint> points) {
    if (points.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No route points available.'),
        ),
      );
    }

    final List<LatLng> route = points
        .map((LocalSessionPoint point) =>
            LatLng(point.latitude, point.longitude))
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
            ),
            PolylineLayer(
              polylines: <Polyline>[
                Polyline(
                  points: route,
                  strokeWidth: 4,
                  color: const Color(0xFF59C3FF),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
