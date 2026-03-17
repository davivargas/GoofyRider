import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/date_time_formatting.dart';
import '../domain/location_tracking_repository.dart';
import '../domain/session_models.dart';
import 'recording_controller.dart';
import 'session_providers.dart';

class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({
    super.key,
    this.preselectedResortId,
  });

  final String? preselectedResortId;

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      ref
          .read(recordingControllerProvider.notifier)
          .bootstrap(preselectedResortId: widget.preselectedResortId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final RecordingViewState state = ref.watch(recordingControllerProvider);
    final ThemeData theme = Theme.of(context);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleRecoveryPrompt(state);
    });

    final List<LatLng> route = state.route;
    final LatLng center =
        route.isNotEmpty ? route.last : const LatLng(50.1, -119.4);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Record'),
        actions: <Widget>[
          if (state.lastSyncMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  state.lastSyncMessage!,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                FlutterMap(
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 12,
                  ),
                  children: <Widget>[
                    TileLayer(
                      urlTemplate:
                          MapTileProviderConfig.openStreetMap.urlTemplate,
                      subdomains:
                          MapTileProviderConfig.openStreetMap.subdomains,
                      userAgentPackageName: 'com.goofyrider.mobile',
                    ),
                    if (route.isNotEmpty)
                      PolylineLayer(
                        polylines: <Polyline>[
                          Polyline(
                            points: route,
                            strokeWidth: 5,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    if (route.isNotEmpty)
                      MarkerLayer(
                        markers: <Marker>[
                          Marker(
                            point: route.last,
                            width: 32,
                            height: 32,
                            child: const Icon(Icons.snowboarding, size: 28),
                          ),
                        ],
                      ),
                  ],
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: _statusBanner(state, theme),
                ),
              ],
            ),
          ),
          _statsPanel(state, theme),
          _controlBar(state),
        ],
      ),
    );
  }

  Widget _statusBanner(RecordingViewState state, ThemeData theme) {
    final List<String> labels = <String>[
      'Phase: ${state.phase.name}',
      'Elapsed: ${state.elapsed.inMinutes.toString().padLeft(2, '0')}:${(state.elapsed.inSeconds % 60).toString().padLeft(2, '0')}',
      if (state.lowAccuracy) 'Low GPS accuracy',
      if (state.permissionState != LocationPermissionState.granted)
        'Location permission required',
      if (state.preselectedResortId != null) 'Resort selected',
    ];

    return Card(
      color: Colors.black54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: labels
              .map(
                (String text) => Chip(
                  label: Text(text),
                  visualDensity: VisualDensity.compact,
                ),
              )
              .toList(growable: false),
        ),
      ),
    );
  }

  Widget _statsPanel(RecordingViewState state, ThemeData theme) {
    final SessionStats stats = state.liveStats;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: <Widget>[
          _statCard(
              'Current', '${state.currentSpeedMps.toStringAsFixed(1)} m/s'),
          _statCard('Max', '${stats.maxSpeedMps.toStringAsFixed(1)} m/s'),
          _statCard('Distance', '${stats.distanceM.toStringAsFixed(0)} m'),
          _statCard('Avg', '${stats.avgSpeedMps.toStringAsFixed(1)} m/s'),
          _statCard('Points', '${state.route.length}'),
          _statCard('Updated', DateTime.now().toTimeLabel()),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Container(
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF11273A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _controlBar(RecordingViewState state) {
    final RecordingController controller =
        ref.read(recordingControllerProvider.notifier);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton(
                onPressed: state.phase == RecordScreenPhase.recording
                    ? controller.pause
                    : state.phase == RecordScreenPhase.paused
                        ? controller.resume
                        : null,
                child: Text(
                  state.phase == RecordScreenPhase.paused ? 'Resume' : 'Pause',
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: state.canStart
                    ? controller.startRecording
                    : state.phase == RecordScreenPhase.recording ||
                            state.phase == RecordScreenPhase.paused
                        ? controller.finish
                        : null,
                child: Text(
                  state.phase == RecordScreenPhase.recording ||
                          state.phase == RecordScreenPhase.paused
                      ? 'Finish'
                      : 'Start Recording',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleRecoveryPrompt(RecordingViewState state) async {
    if (!state.hasRecovery || !mounted) {
      return;
    }

    final RecordingController controller =
        ref.read(recordingControllerProvider.notifier);

    final String? selected = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('Recover unfinished session?'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop('resume'),
                  child: const Text('Resume session'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop('discard'),
                  child: const Text('Discard recovery prompt'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (selected == 'resume') {
      await controller.resumeRecoveredSession();
    } else {
      await controller.discardRecovery();
    }
  }
}
