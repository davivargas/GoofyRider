import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/providers.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/providers/vertical_unit_preference_provider.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/duration_formatting.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/utils/vertical_unit.dart';
import '../../../core/widgets/design_widgets.dart';
import '../../../core/widgets/map_attribution.dart';
import '../domain/location_tracking_repository.dart';
import 'recording_controller.dart';
import 'recording_view_state.dart';
import 'session_providers.dart';
import '../../../app/shell/app_tab_bar.dart';

/// Which record presentation is on screen: the map-first canvas (1b) or the
/// HUD-first canvas (1c).
enum RecordLayout { map, hud }

/// Height available to the HUD below which its fixed rows no longer fit on
/// one screen, so it falls back to scrolling instead of overflowing.
const double _hudMinFitHeight = 560;

/// Height available to the HUD at or above which the speed readout is shown
/// at full size.
const double _hudFullHeroHeight = 640;

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
  LatLng? _lastWarmupCenter;
  RecordLayout _layout = RecordLayout.map;

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
    final verticalUnit = ref.watch(verticalUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final activeMapTileProviderConfig =
        ref.watch(activeMapTileProviderConfigProvider);
    final tileProvider = ref.watch(mapTileProviderProvider);
    final t = context.tokens;
    // Distance to the visible tab bar's top edge (0 outside the shell).
    final barClearance = AppTabBar.bottomClearance(context);
    final sheetAnchor = barClearance + 8;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleRecoveryPrompt(state);
      _handleErrorAlert(state);
    });

    final route = state.tracking.route;
    _maybeFollowRider(state, route);

    final warmupSample = ref.watch(gpsWarmupSampleStreamProvider).maybeWhen(
          data: (LocationSample sample) => sample,
          orElse: () => null,
        );
    final warmupLatLng = (route.isEmpty && warmupSample != null)
        ? LatLng(warmupSample.latitude, warmupSample.longitude)
        : null;
    _maybeFollowWarmup(warmupLatLng);
    final center = route.isNotEmpty
        ? route.last
        : (warmupLatLng ?? const LatLng(50.1, -119.4));

    final topRow = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                // The REC timer and phase labels vary in width; scale the pair
                // down rather than overflowing the row on narrow phones.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _recPill(state),
                        const SizedBox(width: 8),
                        _phasePill(state),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _gpsSignalBadge(state),
                const SizedBox(width: 8),
                PillToggle<RecordLayout>(
                  key: const ValueKey<String>('record-layout-toggle'),
                  options: const <(RecordLayout, String)>[
                    (RecordLayout.map, 'MAP'),
                    (RecordLayout.hud, 'HUD'),
                  ],
                  selected: _layout,
                  onChanged: (RecordLayout v) => setState(() => _layout = v),
                ),
              ],
            ),
            _permissionBanners(state),
          ],
        ),
      ),
    );

    final mapLayers = <Widget>[
      TileLayer(
        urlTemplate: activeMapTileProviderConfig.urlTemplate,
        subdomains: activeMapTileProviderConfig.subdomains,
        retinaMode: activeMapTileProviderConfig.retinaMode,
        userAgentPackageName: 'com.fallline.mobile',
        tileProvider: tileProvider,
        errorTileCallback: (_, __, ___) {
          if (mounted && !_mapTileError) {
            setState(() => _mapTileError = true);
          }
        },
      ),
      if (route.isNotEmpty)
        PolylineLayer(
          polylines: <Polyline>[
            Polyline(
              points: route,
              strokeWidth: 3.5,
              color: t.volt,
              strokeJoin: StrokeJoin.round,
            ),
          ],
        ),
      if (route.isNotEmpty)
        MarkerLayer(
          markers: <Marker>[
            Marker(
              point: route.last,
              width: 28,
              height: 28,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: t.volt.withValues(alpha: 0.4)),
                ),
                child: Center(
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: t.volt,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      if (warmupLatLng != null)
        MarkerLayer(
          markers: <Marker>[
            Marker(
              point: warmupLatLng,
              width: 24,
              height: 24,
              child: Icon(Icons.my_location, size: 22, color: t.ice),
            ),
          ],
        ),
      MapAttribution(config: activeMapTileProviderConfig),
    ];

    // The HUD thumbnail deliberately omits `mapController`: a single
    // `MapController` cannot be handed to a second `FlutterMap` while the
    // previous one is still being deactivated, and the thumbnail is static
    // anyway.
    FlutterMap buildMap({required bool interactive}) => FlutterMap(
          mapController: interactive ? _mapController : null,
          options: MapOptions(
            initialCenter: center,
            initialZoom: _mapZoom,
            backgroundColor: t.mapBg,
            interactionOptions: interactive
                ? const InteractionOptions()
                : const InteractionOptions(flags: InteractiveFlag.none),
            onPositionChanged: interactive
                ? (MapCamera camera, bool hasGesture) {
                    _mapZoom = camera.zoom;
                    if (hasGesture && _isMapFollowing) {
                      setState(() => _isMapFollowing = false);
                    }
                  }
                : null,
          ),
          children: mapLayers,
        );

    final Widget body;
    if (_layout == RecordLayout.map) {
      body = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          buildMap(interactive: true),
          Positioned(top: 0, left: 0, right: 0, child: topRow),
          Positioned(
            left: 12,
            right: 12,
            bottom: sheetAnchor,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 0, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      _speedHero(state, speedUnit, size: 84, shadow: true),
                      const Spacer(),
                      FloatingActionButton.small(
                        heroTag: 'recenter-record-map',
                        onPressed: () =>
                            _recenterOnRider(route, warmupLatLng: warmupLatLng),
                        child: const Icon(Icons.my_location),
                      ),
                    ],
                  ),
                ),
                if (state.autoPaused) _autoPauseBanner(),
                _statsSheet(state, speedUnit, verticalUnit, distanceUnit),
              ],
            ),
          ),
        ],
      );
    } else {
      final hudMapThumbnail = GestureDetector(
        onTap: () => setState(() => _layout = RecordLayout.map),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: t.line),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                IgnorePointer(child: buildMap(interactive: false)),
                const Positioned(
                  right: 10,
                  bottom: 8,
                  child: MonoLabel('Tap for map ↗', size: 10),
                ),
              ],
            ),
          ),
        ),
      );

      body = Column(
        children: <Widget>[
          topRow,
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // The HUD is meant to fill exactly one screen. Everything but
                // the map thumbnail has a fixed height, so the thumbnail takes
                // whatever is left over. Under `_hudMinFitHeight` the fixed
                // rows alone no longer fit, and it scrolls rather than
                // overflowing.
                final fits = constraints.maxHeight >= _hudMinFitHeight;
                final heroSize =
                    constraints.maxHeight >= _hudFullHeroHeight ? 148.0 : 112.0;
                final column = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
                  children: <Widget>[
                    Center(
                      child: MonoLabel(
                        '${_phaseLabel(state)} · Session',
                        size: 12,
                        tone: MonoTone.muted,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: _speedHero(
                        state,
                        speedUnit,
                        size: heroSize,
                        shadow: false,
                        centered: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(child: _sessionMax(state, speedUnit)),
                    const SizedBox(height: 18),
                    _hudTiles(state, verticalUnit, distanceUnit),
                    const SizedBox(height: 12),
                    if (fits)
                      Expanded(child: hudMapThumbnail)
                    else
                      SizedBox(height: 96, child: hudMapThumbnail),
                    if (state.autoPaused) ...<Widget>[
                      const SizedBox(height: 10),
                      _autoPauseBanner(),
                    ],
                    const SizedBox(height: 14),
                    _controlRow(state),
                  ],
                );
                final padding =
                    EdgeInsets.fromLTRB(24, 16, 24, barClearance + 12);
                return fits
                    ? Padding(padding: padding, child: column)
                    : SingleChildScrollView(padding: padding, child: column);
              },
            ),
          ),
        ],
      );
    }

    return Scaffold(body: body);
  }

  String _phaseLabel(RecordingViewState state) {
    if (state.autoPaused) {
      return 'Auto-paused';
    }
    return switch (state.phase) {
      RecordScreenPhase.recording => 'Recording',
      RecordScreenPhase.paused => 'Paused',
      RecordScreenPhase.finishing => 'Finishing',
      RecordScreenPhase.syncPending => 'Sync pending',
      RecordScreenPhase.requestingPermissions => 'Permissions',
      _ => 'Ready',
    };
  }

  Widget _recPill(RecordingViewState state) {
    final active = state.phase == RecordScreenPhase.recording ||
        state.phase == RecordScreenPhase.paused;
    if (!active) {
      return const StatusPill('Ready', variant: PillVariant.ghost);
    }
    return StatusPill(
      '● Rec ${state.tracking.elapsed.toHoursMinutesSeconds()}',
      variant: PillVariant.rec,
    );
  }

  Widget _phasePill(RecordingViewState state) {
    final recording =
        state.phase == RecordScreenPhase.recording && !state.autoPaused;
    return StatusPill(
      _phaseLabel(state),
      variant: recording ? PillVariant.volt : PillVariant.muted,
    );
  }

  Widget _speedHero(
    RecordingViewState state,
    SpeedUnit speedUnit, {
    required double size,
    required bool shadow,
    bool centered = false,
  }) {
    final t = context.tokens;
    final value =
        speedUnit.convertFromMetersPerSecond(state.tracking.currentSpeedMps);
    final whole = value.floor().toString();
    final frac = '.${((value - value.floor()) * 10).floor()}';
    final style = TextStyle(
      fontFamily: AppFonts.archivo,
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: -size * 0.04,
      height: 0.9,
      color: t.text,
      shadows: shadow
          ? <Shadow>[
              Shadow(
                color: t.bg.withValues(alpha: 0.9),
                blurRadius: 18,
                offset: const Offset(0, 2),
              ),
            ]
          : null,
    );
    final number = Text.rich(
      TextSpan(
        text: whole,
        style: style,
        children: <InlineSpan>[
          TextSpan(
            text: frac,
            style: style.copyWith(
              fontSize: size * 0.5,
              color: t.textSecondary,
            ),
          ),
        ],
      ),
    );
    if (centered) {
      return Column(
        children: <Widget>[
          number,
          const SizedBox(height: 8),
          MonoLabel(
            speedUnit.shortLabel,
            size: 13,
            tone: MonoTone.volt,
            letterSpacing: 2.6,
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        number,
        const SizedBox(width: 8),
        MonoLabel(
          speedUnit.shortLabel,
          size: 13,
          tone: MonoTone.volt,
          letterSpacing: 1.6,
        ),
      ],
    );
  }

  Widget _sessionMax(RecordingViewState state, SpeedUnit speedUnit) {
    final t = context.tokens;
    final max = state.tracking.liveStats.maxSpeedMps;
    final current = state.tracking.currentSpeedMps;
    final ratio = max <= 0 ? 0.0 : (current / max).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const MonoLabel('Session max', size: 11),
        const SizedBox(width: 8),
        Text(
          speedUnit.convertFromMetersPerSecond(max).toStringAsFixed(1),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 16),
        ),
        const SizedBox(width: 8),
        Container(
          width: 44,
          height: 4,
          decoration: BoxDecoration(
            color: t.raised,
            borderRadius: BorderRadius.circular(2),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: ratio,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.volt,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _verticalLabel(RecordingViewState state, VerticalUnit verticalUnit) {
    final loss = state.tracking.liveStats.elevationLossM;
    return loss == null ? '--' : verticalUnit.formatFromMeters(loss.toDouble());
  }

  String _altitudeLabel(RecordingViewState state, VerticalUnit verticalUnit) {
    final alt = state.tracking.currentAltitudeM;
    return alt == null ? '--' : verticalUnit.formatFromMeters(alt);
  }

  Widget _hudTiles(
    RecordingViewState state,
    VerticalUnit verticalUnit,
    DistanceUnit distanceUnit,
  ) {
    final stats = state.tracking.liveStats;
    Widget tile(String value, String label) => SurfaceCard(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: StatBlock(value: value, label: label, size: StatSize.large),
        );
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 2.2,
      children: <Widget>[
        tile(_verticalLabel(state, verticalUnit), 'Vert'),
        tile(distanceUnit.formatFromMeters(stats.distanceM), 'Dist'),
        tile(state.tracking.elapsed.toHoursMinutesSeconds(), 'Ride time'),
        tile(_altitudeLabel(state, verticalUnit), 'Alt'),
      ],
    );
  }

  Widget _statsSheet(
    RecordingViewState state,
    SpeedUnit speedUnit,
    VerticalUnit verticalUnit,
    DistanceUnit distanceUnit,
  ) {
    final t = context.tokens;
    final stats = state.tracking.liveStats;
    // Rows rather than a GridView: a fixed childAspectRatio left slack under
    // every cell, and the bottom row's slack read as dead space above the
    // controls. Rows size to their content at any width.
    Widget statRow(List<Widget> blocks) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final Widget block in blocks) Expanded(child: block),
          ],
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: t.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          statRow(<Widget>[
            StatBlock(
              value: speedUnit
                  .convertFromMetersPerSecond(stats.maxSpeedMps)
                  .toStringAsFixed(1),
              label: 'Max ${speedUnit.shortLabel}',
            ),
            StatBlock(
              value: _verticalLabel(state, verticalUnit),
              label: 'Vert',
            ),
            StatBlock(
              value: distanceUnit.formatFromMeters(stats.distanceM),
              label: 'Dist',
            ),
          ]),
          const SizedBox(height: 12),
          statRow(<Widget>[
            StatBlock(
              value: _altitudeLabel(state, verticalUnit),
              label: 'Alt',
            ),
            StatBlock(
              value: speedUnit
                  .convertFromMetersPerSecond(stats.rideAvgSpeedMps)
                  .toStringAsFixed(1),
              label: 'Ride avg',
            ),
            StatBlock(
              value: state.tracking.elapsed.toHoursMinutesSeconds(),
              label: 'Ride time',
            ),
          ]),
          const SizedBox(height: 14),
          _controlRow(state),
        ],
      ),
    );
  }

  Widget _gpsSignalBadge(RecordingViewState state) {
    final t = context.tokens;
    final signalColor = switch (state.tracking.gpsSignal.bars) {
      4 || 3 => t.ice,
      2 || 1 => t.volt,
      _ => t.textMuted,
    };
    return Semantics(
      label: 'GPS signal ${state.tracking.gpsSignal.description}',
      child: StatusPill(
        'GPS',
        variant: PillVariant.ghost,
        leading: _GpsSignalBars(
          bars: state.tracking.gpsSignal.bars,
          color: signalColor,
        ),
      ),
    );
  }

  Widget _permissionBanners(RecordingViewState state) {
    final controller = ref.read(recordingControllerProvider.notifier);
    final children = <Widget>[
      if (state.permission.needsAlwaysOnPermission)
        SurfaceCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Enable "Allow all the time" to keep tracking when your phone is locked.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextButton(
                      onPressed: controller.requestRequiredLocationPermissions,
                      child: const Text('RETRY PERMISSION'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: controller.openLocationPermissionSettings,
                      child: const Text('OPEN SETTINGS'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (state.permission.permissionState ==
          LocationPermissionState.serviceDisabled)
        SurfaceCard(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Turn GPS on to keep recording accurately.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: controller.openLocationServiceSettings,
                child: const Text('GPS SETTINGS'),
              ),
            ],
          ),
        ),
      if (_mapTileError)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: MonoLabel(
            'Map tiles failing, check network signal.',
            size: 10,
            tone: MonoTone.muted,
            uppercase: false,
          ),
        ),
    ];
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _autoPauseBanner() {
    final t = context.tokens;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.line),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.pause_circle_outline, color: t.textSecondary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Paused while stopped. Tap resume when you start moving again.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: t.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlRow(RecordingViewState state) {
    final controller = ref.read(recordingControllerProvider.notifier);
    final inSession = state.phase == RecordScreenPhase.recording ||
        state.phase == RecordScreenPhase.paused;
    return Row(
      children: <Widget>[
        Expanded(
          flex: 10,
          child: GhostButton(
            label: state.phase == RecordScreenPhase.paused ? 'Resume' : 'Pause',
            onPressed: state.phase == RecordScreenPhase.recording
                ? controller.pause
                : state.phase == RecordScreenPhase.paused
                    ? controller.resume
                    : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 14,
          child: VoltButton(
            label: inSession ? 'Finish' : 'Start recording',
            onPressed: state.canStart
                ? controller.startRecording
                : (inSession ? controller.finish : null),
          ),
        ),
      ],
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

  void _maybeFollowWarmup(LatLng? warmupLatLng) {
    if (warmupLatLng == null) {
      _lastWarmupCenter = null;
      return;
    }
    if (!_isMapFollowing) {
      return;
    }
    if (_lastWarmupCenter == warmupLatLng) {
      return;
    }
    _lastWarmupCenter = warmupLatLng;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isMapFollowing) {
        return;
      }
      try {
        _mapController.move(warmupLatLng, _mapZoom);
      } catch (_) {}
    });
  }

  void _recenterOnRider(List<LatLng> route, {LatLng? warmupLatLng}) {
    final target = route.isNotEmpty ? route.last : warmupLatLng;
    if (target == null) {
      return;
    }
    try {
      _mapController.move(target, _mapZoom);
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

    final controller = ref.read(recordingControllerProvider.notifier);
    final canOpenPermissionSettings = state.permission.permissionState ==
            LocationPermissionState.grantedForegroundOnly ||
        state.permission.permissionState ==
            LocationPermissionState.deniedForever;
    final canOpenLocationSettings = state.permission.permissionState ==
        LocationPermissionState.serviceDisabled;

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
    final controller = ref.read(recordingControllerProvider.notifier);

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
    final controller = ref.read(recordingControllerProvider.notifier);
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
    const heights = <double>[5, 8, 11, 14];
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
              color: active ? color : context.tokens.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}
