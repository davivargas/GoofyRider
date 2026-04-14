import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/providers.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/date_time_formatting.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/duration_formatting.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/widgets/map_attribution.dart';
import '../domain/location_tracking_repository.dart';
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

class _RecordScreenState extends ConsumerState<RecordScreen>
    with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  bool _isMapFollowing = true;
  bool _recoveryPromptVisible = false;
  bool _mapTileError = false;
  double _mapZoom = 12;
  int _lastRoutePointCount = 0;
  String? _lastShownErrorMessage;
  Timer? _gpsSignalRefreshTicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future<void>.microtask(() {
      ref
          .read(recordingControllerProvider.notifier)
          .bootstrap(preselectedResortId: widget.preselectedResortId);
    });
    _startGpsSignalRefreshLoop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(recordingControllerProvider.notifier).onAppResumed();
    }
  }

  @override
  void dispose() {
    _gpsSignalRefreshTicker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final activeMapTileProviderConfig =
        ref.watch(activeMapTileProviderConfigProvider);
    final theme = Theme.of(context);
    final showDebugDiagnostics =
        kDebugMode && AppConstants.isDebugDiagnostics;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleRecoveryPrompt(state);
      _handleErrorAlert(state);
    });

    final route = state.tracking.route;
    _maybeFollowRider(state, route);

    final center =
        route.isNotEmpty ? route.last : const LatLng(50.1, -119.4);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Record'),
        actions: <Widget>[
          if (showDebugDiagnostics && state.sync.lastSyncMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  state.sync.lastSyncMessage!,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final mapHeight = _mapSectionHeight(constraints.maxHeight);
          return Column(
            children: <Widget>[
              SizedBox(
                height: mapHeight,
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
                          urlTemplate: activeMapTileProviderConfig.urlTemplate,
                          subdomains: activeMapTileProviderConfig.subdomains,
                          retinaMode: activeMapTileProviderConfig.retinaMode,
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
                                child: const Icon(
                                  Icons.snowboarding,
                                  size: 28,
                                  color: Colors.black,
                                ),
                              ),
                            ],
                          ),
                        MapAttribution(config: activeMapTileProviderConfig),
                      ],
                    ),
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 88,
                      child: _statusBanner(state),
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: _gpsSignalBadge(state),
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
              Expanded(
                child: _statsPanel(state, speedUnit, distanceUnit),
              ),
              _controlBar(state),
            ],
          );
        },
      ),
    );
  }

  Widget _statusBanner(RecordingViewState state) {
    final controller =
        ref.read(recordingControllerProvider.notifier);
    final nowUtc = DateTime.now().toUtc();
    final labels = <String>[
      'Phase: ${state.phase.name}',
      'Elapsed: ${state.tracking.elapsed.toHoursMinutesSeconds()}',
      if (state.tracking.lowAccuracy) 'Low GPS accuracy',
      if (!state.permission.hasLocationPermission) 'Location permission required',
      if (state.phase == RecordScreenPhase.recording &&
          state.permission.hasConfirmedBackgroundTracking)
        'Background tracking active',
      if (state.phase == RecordScreenPhase.recording &&
          !state.permission.hasConfirmedBackgroundTracking)
        'Background tracking limited: allow "All the time".',
      if (state.phase == RecordScreenPhase.recording &&
          state.tracking.lastSampleAtUtc != null)
        'Last sample ${nowUtc.difference(state.tracking.lastSampleAtUtc!).toHoursMinutesSeconds()} ago',
      if (state.phase == RecordScreenPhase.recording &&
          state.tracking.lastPersistedPointAtUtc != null)
        'Last DB write ${nowUtc.difference(state.tracking.lastPersistedPointAtUtc!).toHoursMinutesSeconds()} ago',
      if (state.streamRestartCount > 0)
        'Stream restarts: ${state.streamRestartCount}',
      if (state.preselectedResortId != null) 'Resort selected',
      if (_mapTileError) 'Map tiles failing, check network signal.',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Card(
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
        ),
        if (state.permission.needsAlwaysOnPermission)
          Card(
            color: Colors.black54,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  const Text(
                    'Enable "Allow all the time" to keep tracking when your phone is locked.',
                  ),
                  FilledButton.tonal(
                    onPressed: controller.requestRequiredLocationPermissions,
                    child: const Text('Retry permission'),
                  ),
                  OutlinedButton(
                    onPressed: controller.openLocationPermissionSettings,
                    child: const Text('Open location settings'),
                  ),
                ],
              ),
            ),
          ),
        if (state.permission.permissionState == LocationPermissionState.serviceDisabled)
          Card(
            color: Colors.black54,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  const Text('Turn GPS on to keep recording accurately.'),
                  OutlinedButton(
                    onPressed: controller.openLocationServiceSettings,
                    child: const Text('Open GPS settings'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _statsPanel(
    RecordingViewState state,
    SpeedUnit speedUnit,
    DistanceUnit distanceUnit,
  ) {
    final stats = state.tracking.liveStats;
    final verticalLabel = stats.elevationLossM == null
        ? '--'
        : distanceUnit.formatFromMeters(stats.elevationLossM!.toDouble());
    final altitudeLabel = state.tracking.currentAltitudeM == null
        ? '--'
        : distanceUnit.formatFromMeters(state.tracking.currentAltitudeM!);

    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            const spacing = 8.0;
            final columns = constraints.maxWidth >= 320 ? 3 : 2;
            final cardWidth =
                (constraints.maxWidth - (spacing * (columns - 1))) / columns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: <Widget>[
                _statCard(
                  'Current',
                  speedUnit
                      .formatFromMetersPerSecond(state.tracking.currentSpeedMps),
                  width: cardWidth,
                ),
                _statCard(
                  'Max',
                  speedUnit.formatFromMetersPerSecond(stats.maxSpeedMps),
                  width: cardWidth,
                ),
                _statCard(
                  'Distance',
                  distanceUnit.formatFromMeters(stats.distanceM),
                  width: cardWidth,
                ),
                _statCard('Vertical', verticalLabel, width: cardWidth),
                _statCard('Altitude', altitudeLabel, width: cardWidth),
                _statCard(
                  'Ride avg',
                  speedUnit.formatFromMetersPerSecond(stats.rideAvgSpeedMps),
                  width: cardWidth,
                ),
                _statCard(
                  'Duration',
                  state.tracking.elapsed.toHoursMinutesSeconds(),
                  width: cardWidth,
                ),
                _statCard('Points', '${state.tracking.route.length}',
                    width: cardWidth),
                _statCard('Updated', DateTime.now().toTimeLabel(),
                    width: cardWidth),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _gpsSignalBadge(RecordingViewState state) {
    final signalColor = switch (state.tracking.gpsSignal.bars) {
      4 => const Color(0xFF6EDB8F),
      3 => const Color(0xFF9BE070),
      2 => const Color(0xFFF6C667),
      1 => const Color(0xFFE28E5B),
      _ => const Color(0xFF9BA4AF),
    };

    return Semantics(
      label: 'GPS signal ${state.tracking.gpsSignal.description}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _GpsSignalBars(
              bars: state.tracking.gpsSignal.bars,
              color: signalColor,
            ),
            const SizedBox(height: 2),
            const Text(
              'GPS',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(
    String label,
    String value, {
    required double width,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF11273A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 2),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _mapSectionHeight(double availableHeight) {
    const minimumStatsAndControlsHeight = 190.0;
    const minimumMapHeight = 180.0;
    final targetMapHeight = availableHeight * 0.65;
    final maxMapHeight = availableHeight - minimumStatsAndControlsHeight;
    if (maxMapHeight <= minimumMapHeight) {
      return (availableHeight * 0.50).clamp(150.0, minimumMapHeight).toDouble();
    }
    return targetMapHeight.clamp(minimumMapHeight, maxMapHeight).toDouble();
  }

  Widget _controlBar(RecordingViewState state) {
    final controller =
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
      if (_lastRoutePointCount > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          try {
            _mapController.move(const LatLng(50.1, -119.4), _mapZoom);
          } catch (_) {}
          if (!_isMapFollowing) {
            setState(() {
              _isMapFollowing = true;
            });
          }
        });
      }
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

  void _handleErrorAlert(RecordingViewState state) {
    final error = state.permission.errorMessage;
    if (!mounted) {
      return;
    }

    if (error == null) {
      _lastShownErrorMessage = null;
      return;
    }

    if (_lastShownErrorMessage == error) {
      return;
    }
    _lastShownErrorMessage = error;

    final controller =
        ref.read(recordingControllerProvider.notifier);
    final canOpenPermissionSettings = state.permission.permissionState ==
            LocationPermissionState.grantedForegroundOnly ||
        state.permission.permissionState == LocationPermissionState.deniedForever;
    final canOpenLocationSettings =
        state.permission.permissionState == LocationPermissionState.serviceDisabled;

    final SnackBarAction? action;
    if (canOpenPermissionSettings) {
      action = SnackBarAction(
        label: 'Open settings',
        onPressed: () {
          controller.openLocationPermissionSettings();
        },
      );
    } else if (canOpenLocationSettings) {
      action = SnackBarAction(
        label: 'Open GPS settings',
        onPressed: () {
          controller.openLocationServiceSettings();
        },
      );
    } else {
      action = null;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(error),
          action: action,
        ),
      );
  }

  Future<void> _handleRecoveryPrompt(RecordingViewState state) async {
    if (!state.hasRecovery || !mounted || _recoveryPromptVisible) {
      return;
    }

    _recoveryPromptVisible = true;
    final controller =
        ref.read(recordingControllerProvider.notifier);

    final selected = await showModalBottomSheet<String>(
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

  void _startGpsSignalRefreshLoop() {
    _gpsSignalRefreshTicker?.cancel();
    final controller =
        ref.read(recordingControllerProvider.notifier);
    controller.refreshGpsSignal();
    _gpsSignalRefreshTicker = Timer.periodic(const Duration(seconds: 15), (_) {
      final state = ref.read(recordingControllerProvider);
      if (state.phase != RecordScreenPhase.recording) {
        controller.refreshGpsSignal();
      }
    });
  }
}

class _GpsSignalBars extends StatelessWidget {
  const _GpsSignalBars({
    required this.bars,
    required this.color,
  });

  final int bars;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const heights = <double>[6, 10, 14, 18];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List<Widget>.generate(heights.length, (int index) {
        final active = index < bars;
        return Padding(
          padding: EdgeInsets.only(right: index == heights.length - 1 ? 0 : 2),
          child: Container(
            width: 4,
            height: heights[index],
            decoration: BoxDecoration(
              color: active ? color : Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}
