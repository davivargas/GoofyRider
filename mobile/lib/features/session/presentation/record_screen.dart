import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/date_time_formatting.dart';
import '../../../core/utils/speed_unit.dart';
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
  final MapController _mapController = MapController();
  bool _isMapFollowing = true;
  bool _recoveryPromptVisible = false;
  bool _mapTileError = false;
  double _mapZoom = 12;
  int _lastRoutePointCount = 0;

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
    final SpeedUnit speedUnit = ref.watch(speedUnitPreferenceProvider);
    final ThemeData theme = Theme.of(context);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleRecoveryPrompt(state);
    });

    final List<LatLng> route = state.route;
    _maybeFollowRider(state, route);

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
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: _mapZoom,
                    onPositionChanged: (MapCamera camera, bool hasGesture) {
                      _mapZoom = camera.zoom;
                      if (hasGesture && _isMapFollowing) {
                        setState(() {
                          _isMapFollowing = false;
                        });
                      }
                    },
                  ),
                  children: <Widget>[
                    TileLayer(
                      urlTemplate:
                          MapTileProviderConfig.openStreetMap.urlTemplate,
                      subdomains:
                          MapTileProviderConfig.openStreetMap.subdomains,
                      userAgentPackageName: 'com.goofyrider.mobile',
                      errorTileCallback: (_, __, ___) {
                        if (mounted && !_mapTileError) {
                          setState(() {
                            _mapTileError = true;
                          });
                        }
                      },
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
                  child: _statusBanner(state),
                ),
                if (!_isMapFollowing && route.isNotEmpty)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      heroTag: 'recenter-record-map',
                      onPressed: () => _recenterOnRider(route),
                      child: const Icon(Icons.my_location),
                    ),
                  ),
              ],
            ),
          ),
          _statsPanel(state, speedUnit),
          _controlBar(state),
        ],
      ),
    );
  }

  Widget _statusBanner(RecordingViewState state) {
    final List<String> labels = <String>[
      'Phase: ${state.phase.name}',
      'Elapsed: ${state.elapsed.inMinutes.toString().padLeft(2, '0')}:${(state.elapsed.inSeconds % 60).toString().padLeft(2, '0')}',
      if (state.lowAccuracy) 'Low GPS accuracy',
      if (!state.hasLocationPermission) 'Location permission required',
      if (state.phase == RecordScreenPhase.recording &&
          state.hasConfirmedBackgroundTracking)
        'Background tracking active',
      if (state.phase == RecordScreenPhase.recording &&
          !state.hasConfirmedBackgroundTracking)
        'Background tracking limited: allow "All the time".',
      if (state.preselectedResortId != null) 'Resort selected',
      if (_mapTileError) 'Map tiles failing, check network signal.',
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

  Widget _statsPanel(RecordingViewState state, SpeedUnit speedUnit) {
    final SessionStats stats = state.liveStats;

    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            _statCard('Current',
                speedUnit.formatFromMetersPerSecond(state.currentSpeedMps)),
            _statCard(
                'Max', speedUnit.formatFromMetersPerSecond(stats.maxSpeedMps)),
            _statCard('Distance', '${stats.distanceM.toStringAsFixed(0)} m'),
            _statCard(
                'Avg', speedUnit.formatFromMetersPerSecond(stats.avgSpeedMps)),
            _statCard('Points', '${state.route.length}'),
            _statCard('Updated', DateTime.now().toTimeLabel()),
          ],
        ),
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

  void _maybeFollowRider(RecordingViewState state, List<LatLng> route) {
    if (route.isEmpty) {
      _lastRoutePointCount = 0;
      return;
    }

    if (!_isMapFollowing) {
      _lastRoutePointCount = route.length;
      return;
    }

    if (route.length == _lastRoutePointCount) {
      return;
    }

    _lastRoutePointCount = route.length;

    if (state.phase != RecordScreenPhase.recording &&
        state.phase != RecordScreenPhase.paused) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isMapFollowing || route.isEmpty) {
        return;
      }
      try {
        _mapController.move(route.last, _mapZoom);
      } catch (_) {}
    });
  }

  void _recenterOnRider(List<LatLng> route) {
    if (route.isEmpty) {
      return;
    }
    try {
      _mapController.move(route.last, _mapZoom);
      setState(() {
        _isMapFollowing = true;
      });
    } catch (_) {}
  }

  Future<void> _handleRecoveryPrompt(RecordingViewState state) async {
    if (!state.hasRecovery || !mounted || _recoveryPromptVisible) {
      return;
    }

    _recoveryPromptVisible = true;
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
    _recoveryPromptVisible = false;
  }
}
