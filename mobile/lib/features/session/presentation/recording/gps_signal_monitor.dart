import '../../domain/location_tracking_repository.dart';
import '../recording_view_state.dart';

const Duration _gpsSignalStaleThreshold = Duration(seconds: 15);

/// Monitors GPS signal quality and translates raw [LocationSample] data into
/// a user-facing [GpsSignalState].
///
/// Does **not** extend `StateNotifier` — the coordinator owns the state.
class GpsSignalMonitor {
  GpsSignalMonitor({
    required LocationTrackingRepository locationTrackingRepository,
    required RecordingViewState Function() readState,
    required void Function(RecordingViewState) writeState,
  })  : _locationTrackingRepository = locationTrackingRepository,
        _readState = readState,
        _writeState = writeState;

  final LocationTrackingRepository _locationTrackingRepository;
  final RecordingViewState Function() _readState;
  final void Function(RecordingViewState) _writeState;

  bool _gpsSignalRefreshInFlight = false;

  /// Queries the current location fix and updates the GPS signal indicator in
  /// the view state.
  ///
  /// The [isMounted] callback lets the caller gate writes on whether the
  /// owning `StateNotifier` is still alive.
  Future<void> refreshGpsSignal({required bool Function() isMounted}) async {
    if (_gpsSignalRefreshInFlight) {
      return;
    }

    _gpsSignalRefreshInFlight = true;
    try {
      final LocationPermissionState permission =
          await _locationTrackingRepository.checkPermissions();
      final GpsSignalState signal;
      if (permission == LocationPermissionState.serviceDisabled) {
        signal = const GpsSignalState(
          bars: 0,
          description: 'GPS off',
        );
      } else if (permission == LocationPermissionState.denied ||
          permission == LocationPermissionState.deniedForever) {
        signal = const GpsSignalState(
          bars: 0,
          description: 'No permission',
        );
      } else {
        final LocationSample? sample =
            await _locationTrackingRepository.getCurrentLocationSample();
        signal = gpsSignalFromSample(
          sample,
          permissionState: permission,
        );
      }

      if (!isMounted()) {
        return;
      }
      _writeState(
        _readState().copyWith(
          permission: _readState().permission.copyWith(
            permissionState: permission,
          ),
          tracking: _readState().tracking.copyWith(gpsSignal: signal),
        ),
      );
    } finally {
      _gpsSignalRefreshInFlight = false;
    }
  }

  /// Converts a raw [LocationSample] into a [GpsSignalState] suitable for
  /// display.  This is also used by the coordinator's `_onLocation` callback
  /// to update the signal indicator inline.
  GpsSignalState gpsSignalFromSample(
    LocationSample? sample, {
    required LocationPermissionState permissionState,
  }) {
    if (permissionState == LocationPermissionState.serviceDisabled) {
      return const GpsSignalState(
        bars: 0,
        description: 'GPS off',
      );
    }
    if (permissionState == LocationPermissionState.denied ||
        permissionState == LocationPermissionState.deniedForever) {
      return const GpsSignalState(
        bars: 0,
        description: 'No permission',
      );
    }
    if (sample == null) {
      return const GpsSignalState(
        bars: 0,
        description: 'Searching',
      );
    }

    final Duration age =
        DateTime.now().toUtc().difference(sample.timestamp.toUtc());
    if (age > _gpsSignalStaleThreshold) {
      return const GpsSignalState(
        bars: 1,
        description: 'Stale fix',
      );
    }

    final double? accuracyM = sample.accuracyM;
    if (accuracyM == null) {
      return const GpsSignalState(
        bars: 1,
        description: 'Weak fix',
      );
    }
    if (accuracyM <= 8) {
      return const GpsSignalState(
        bars: 4,
        description: 'Excellent',
      );
    }
    if (accuracyM <= 15) {
      return const GpsSignalState(
        bars: 3,
        description: 'Good',
      );
    }
    if (accuracyM <= 25) {
      return const GpsSignalState(
        bars: 2,
        description: 'Fair',
      );
    }
    return const GpsSignalState(
      bars: 1,
      description: 'Weak fix',
    );
  }

  void dispose() {
    // No timers or subscriptions to clean up.
  }
}
