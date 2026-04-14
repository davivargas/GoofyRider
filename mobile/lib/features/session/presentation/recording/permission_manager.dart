import '../../domain/location_tracking_repository.dart';
import '../recording_view_state.dart';

const String _allTimePermissionMessage =
    'Location is set to "Allow only while using the app". '
    'Choose "Allow all the time" so tracking keeps working when the phone is locked.';
const String _locationPermissionMessage =
    'Location permission is required before recording.';
const String _locationDeniedForeverMessage =
    'Location permission is permanently denied. Open app settings to enable it.';
const String _locationServiceDisabledMessage =
    'Location services are turned off. Turn on GPS to record your session.';
const String _openSettingsFailedMessage =
    'Could not open app settings. Please open settings manually: Settings > Apps > GoofyRider > Permissions.';
const String _openLocationSettingsFailedMessage =
    'Could not open location settings. Please open settings manually: Settings > Apps > GoofyRider > Permissions.';

/// Manages location-permission checks, requests, and settings navigation.
///
/// Does **not** extend `StateNotifier` — the coordinator owns the state.
/// This manager reads/writes state through the callbacks supplied at
/// construction time.
class PermissionManager {
  PermissionManager({
    required LocationTrackingRepository locationTrackingRepository,
    required RecordingViewState Function() readState,
    required void Function(RecordingViewState) writeState,
  })  : _locationTrackingRepository = locationTrackingRepository,
        _readState = readState,
        _writeState = writeState;

  final LocationTrackingRepository _locationTrackingRepository;
  final RecordingViewState Function() _readState;
  final void Function(RecordingViewState) _writeState;

  Future<void> refreshPermissionState({
    required Future<void> Function(LocationPermissionState) onPermissionLoss,
    required Future<void> Function() refreshGpsSignal,
  }) async {
    final permission =
        await _locationTrackingRepository.checkPermissions();
    if (_readState().phase == RecordScreenPhase.recording &&
        permission != LocationPermissionState.granted) {
      await onPermissionLoss(permission);
      await refreshGpsSignal();
      return;
    }
    _writeState(
      _readState().copyWith(
        permission: _readState().permission.copyWith(
          permissionState: permission,
          clearError: permission == LocationPermissionState.granted,
          errorMessage: permissionMessage(permission),
        ),
      ),
    );
    await refreshGpsSignal();
  }

  Future<void> requestRequiredLocationPermissions({
    required bool phaseTransitionInFlight,
    required Future<void> Function(LocationPermissionState) onPermissionLoss,
    required Future<void> Function() refreshGpsSignal,
    required void Function(bool) setPhaseTransitionInFlight,
  }) async {
    final currentState = _readState();
    if (phaseTransitionInFlight ||
        currentState.phase == RecordScreenPhase.requestingPermissions ||
        currentState.phase == RecordScreenPhase.finishing) {
      return;
    }

    setPhaseTransitionInFlight(true);
    final previousPhase = currentState.phase;
    try {
      _writeState(
        _readState().copyWith(
          phase: RecordScreenPhase.requestingPermissions,
          permission: _readState().permission.copyWith(clearError: true),
        ),
      );

      final permission =
          await _locationTrackingRepository.ensurePermissions();

      if (previousPhase == RecordScreenPhase.recording &&
          permission != LocationPermissionState.granted) {
        await onPermissionLoss(permission);
        await refreshGpsSignal();
        return;
      }

      final RecordScreenPhase nextPhase;
      if (previousPhase == RecordScreenPhase.preRecord ||
          previousPhase == RecordScreenPhase.requestingPermissions) {
        nextPhase = RecordScreenPhase.ready;
      } else {
        nextPhase = previousPhase;
      }

      _writeState(
        _readState().copyWith(
          phase: nextPhase,
          permission: _readState().permission.copyWith(
            permissionState: permission,
            clearError: permission == LocationPermissionState.granted,
            errorMessage: permissionMessage(permission),
          ),
        ),
      );
      await refreshGpsSignal();
    } finally {
      setPhaseTransitionInFlight(false);
    }
  }

  Future<void> openLocationPermissionSettings() async {
    final opened = await _locationTrackingRepository.openAppSettings();
    if (!opened) {
      _writeState(
        _readState().copyWith(
          permission: _readState().permission.copyWith(
            errorMessage: _openSettingsFailedMessage,
          ),
        ),
      );
    }
  }

  Future<void> openLocationServiceSettings() async {
    final opened =
        await _locationTrackingRepository.openLocationSettings();
    if (!opened) {
      _writeState(
        _readState().copyWith(
          permission: _readState().permission.copyWith(
            errorMessage: _openLocationSettingsFailedMessage,
          ),
        ),
      );
    }
  }

  /// Returns the user-facing message for a given [permission] state, or `null`
  /// when no message is needed (i.e. permission is granted).
  static String? permissionMessage(LocationPermissionState permission) {
    switch (permission) {
      case LocationPermissionState.granted:
        return null;
      case LocationPermissionState.grantedForegroundOnly:
        return _allTimePermissionMessage;
      case LocationPermissionState.denied:
        return _locationPermissionMessage;
      case LocationPermissionState.deniedForever:
        return _locationDeniedForeverMessage;
      case LocationPermissionState.serviceDisabled:
        return _locationServiceDisabledMessage;
    }
  }

  void dispose() {
    // No timers or subscriptions to clean up.
  }
}
