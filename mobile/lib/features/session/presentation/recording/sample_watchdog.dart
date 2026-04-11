import 'dart:async';

import '../../domain/location_tracking_repository.dart';
import '../../domain/session_models.dart';
import '../../domain/tracking_mode_profiles.dart';
import '../recording_view_state.dart';

const Duration _sampleWatchdogRestartCooldown = Duration(seconds: 30);
const Duration _sampleWatchdogInitialSampleRestartGrace =
    Duration(seconds: 12);
const int _recoveryModeStaleEventsBeforeRestart = 3;

/// Monitors the location stream for stale-sample conditions and triggers
/// recovery actions (mode downgrade, stream restart) when GPS updates stop
/// arriving.
///
/// Does **not** extend `StateNotifier` — the coordinator owns the state.
class SampleWatchdog {
  SampleWatchdog({
    required LocationTrackingRepository locationTrackingRepository,
    required RecordingViewState Function() readState,
    required void Function(RecordingViewState) writeState,
  })  : _locationTrackingRepository = locationTrackingRepository,
        _readState = readState,
        _writeState = writeState;

  final LocationTrackingRepository _locationTrackingRepository;
  final RecordingViewState Function() _readState;
  final void Function(RecordingViewState) _writeState;

  Timer? _sampleWatchdogTimer;
  int consecutiveWatchdogStaleEvents = 0;

  /// Starts the watchdog by scheduling the first check.
  void startSampleWatchdog({
    required TrackingMode activeTrackingMode,
    required DateTime? lastSampleReceivedAtUtc,
    required DateTime? currentStreamStartedAtUtc,
  }) {
    rescheduleSampleWatchdog(
      activeTrackingMode: activeTrackingMode,
      lastSampleReceivedAtUtc: lastSampleReceivedAtUtc,
      currentStreamStartedAtUtc: currentStreamStartedAtUtc,
    );
  }

  /// Cancels any pending watchdog timer.
  void stopSampleWatchdog() {
    _sampleWatchdogTimer?.cancel();
    _sampleWatchdogTimer = null;
  }

  /// Reschedules the watchdog timer based on the current tracking mode and
  /// the most recent sample timestamp.
  void rescheduleSampleWatchdog({
    required TrackingMode activeTrackingMode,
    required DateTime? lastSampleReceivedAtUtc,
    required DateTime? currentStreamStartedAtUtc,
  }) {
    _sampleWatchdogTimer?.cancel();
    _sampleWatchdogTimer = null;

    if (_readState().phase != RecordScreenPhase.recording) {
      return;
    }

    final LocalRideSession? session = _readState().session;
    if (session == null) {
      return;
    }

    final DateTime? referenceTime =
        lastSampleReceivedAtUtc ?? currentStreamStartedAtUtc;
    if (referenceTime == null) {
      return;
    }

    final Duration staleThreshold =
        TrackingModeProfiles.forMode(activeTrackingMode)
            .sampleWatchdogThreshold;
    final DateTime deadline = referenceTime.add(staleThreshold);
    final DateTime now = DateTime.now().toUtc();
    final Duration delay = deadline.difference(now);

    if (delay <= Duration.zero) {
      unawaited(_onWatchdogCheck?.call());
      return;
    }

    _scheduleSampleWatchdogAfter(delay);
  }

  /// Schedules a single watchdog check after [delay].
  void _scheduleSampleWatchdogAfter(Duration delay) {
    _sampleWatchdogTimer?.cancel();
    _sampleWatchdogTimer = Timer(delay, () {
      unawaited(_onWatchdogCheck?.call());
    });
  }

  // ---------------------------------------------------------------------------
  // Watchdog check callback
  // ---------------------------------------------------------------------------

  /// The coordinator sets this callback so the watchdog can trigger the full
  /// check logic that lives in the coordinator (because it touches epoch
  /// management, stream restart, diagnostics, etc.).
  Future<void> Function()? _onWatchdogCheck;

  /// Registers the callback invoked when the watchdog timer fires.
  set onWatchdogCheck(Future<void> Function() callback) {
    _onWatchdogCheck = callback;
  }

  // ---------------------------------------------------------------------------
  // Check logic helpers
  // ---------------------------------------------------------------------------

  /// Core watchdog check.  Returns a [WatchdogAction] describing what the
  /// coordinator should do next.
  Future<WatchdogAction> checkSampleWatchdog({
    required TrackingMode activeTrackingMode,
    required DateTime? lastSampleReceivedAtUtc,
    required DateTime? currentStreamStartedAtUtc,
    required DateTime? lastWatchdogRestartAtUtc,
    required int recordingEpoch,
    required bool Function(int recordingEpoch, {required int? sessionId})
        isActiveRecordingEpoch,
  }) async {
    if (_readState().phase != RecordScreenPhase.recording) {
      return const WatchdogAction.none();
    }

    final LocalRideSession? session = _readState().session;
    if (session == null) {
      return const WatchdogAction.none();
    }

    final DateTime? referenceTime =
        lastSampleReceivedAtUtc ?? currentStreamStartedAtUtc;
    if (referenceTime == null) {
      return const WatchdogAction.none();
    }

    final DateTime now = DateTime.now().toUtc();
    final Duration staleFor = now.difference(referenceTime);
    final Duration staleThreshold =
        TrackingModeProfiles.forMode(activeTrackingMode)
            .sampleWatchdogThreshold;
    final bool hasReceivedSample = lastSampleReceivedAtUtc != null;

    if (staleFor < staleThreshold) {
      return WatchdogAction.reschedule(
        activeTrackingMode: activeTrackingMode,
        lastSampleReceivedAtUtc: lastSampleReceivedAtUtc,
        currentStreamStartedAtUtc: currentStreamStartedAtUtc,
      );
    }

    if (!isActiveRecordingEpoch(recordingEpoch, sessionId: session.localId)) {
      return const WatchdogAction.none();
    }

    final DateTime? lastRestart = lastWatchdogRestartAtUtc;
    final bool restartCoolingDown = lastRestart != null &&
        now.difference(lastRestart) < _sampleWatchdogRestartCooldown;

    consecutiveWatchdogStaleEvents += 1;

    // --- Attempt recovery mode ---
    final bool shouldAttemptRecoveryMode =
        activeTrackingMode != TrackingMode.lowConfidenceRecovery &&
            consecutiveWatchdogStaleEvents == 1;

    if (shouldAttemptRecoveryMode) {
      try {
        await _locationTrackingRepository
            .setTrackingMode(TrackingMode.lowConfidenceRecovery);
        if (!isActiveRecordingEpoch(recordingEpoch,
            sessionId: session.localId)) {
          return const WatchdogAction.none();
        }

        _writeState(
          _readState().copyWith(
            permission: _readState().permission.copyWith(
              errorMessage:
                  'Location updates stalled for ${staleFor.inSeconds}s. Recovering GPS...',
            ),
            tracking: _readState().tracking.copyWith(
              gpsSignal: const GpsSignalState(
                bars: 0,
                description: 'Searching',
              ),
            ),
          ),
        );

        final Duration recoveryThreshold = TrackingModeProfiles.forMode(
          TrackingMode.lowConfidenceRecovery,
        ).sampleWatchdogThreshold;

        return WatchdogAction.switchedToRecoveryMode(
          staleFor: staleFor,
          staleThreshold: staleThreshold,
          hasReceivedSample: hasReceivedSample,
          recoveryThreshold: recoveryThreshold,
        );
      } catch (_) {
        // Fall through to stream restart below.
      }
    }

    // --- Wait for initial sample grace ---
    final bool shouldKeepWaitingForInitialSample = !hasReceivedSample &&
        staleFor < staleThreshold + _sampleWatchdogInitialSampleRestartGrace;
    if (shouldKeepWaitingForInitialSample) {
      _writeState(
        _readState().copyWith(
          permission: _readState().permission.copyWith(
            errorMessage:
                'Still waiting for initial GPS fix (${staleFor.inSeconds}s). Continuing recovery...',
          ),
          tracking: _readState().tracking.copyWith(
            gpsSignal: const GpsSignalState(
              bars: 0,
              description: 'Searching',
            ),
          ),
        ),
      );
      return WatchdogAction.waitingForInitialSample(
        staleFor: staleFor,
        staleThreshold: staleThreshold,
        activeTrackingMode: activeTrackingMode,
      );
    }

    // --- Delay restart after recovery mode ---
    final bool shouldDelayRestartAfterRecovery =
        activeTrackingMode == TrackingMode.lowConfidenceRecovery &&
            consecutiveWatchdogStaleEvents <
                _recoveryModeStaleEventsBeforeRestart;
    if (shouldDelayRestartAfterRecovery) {
      return WatchdogAction.recoveryWait(
        staleFor: staleFor,
        staleThreshold: staleThreshold,
        activeTrackingMode: activeTrackingMode,
      );
    }

    // --- Restart cooldown ---
    if (restartCoolingDown) {
      final int cooldownRemainingSeconds =
          _sampleWatchdogRestartCooldown.inSeconds -
              now.difference(lastRestart).inSeconds;
      return WatchdogAction.restartCooldown(
        staleFor: staleFor,
        staleThreshold: staleThreshold,
        cooldownRemainingSeconds: cooldownRemainingSeconds.clamp(0, 600),
        activeTrackingMode: activeTrackingMode,
      );
    }

    // --- Trigger stream restart ---
    _writeState(
      _readState().copyWith(
        permission: _readState().permission.copyWith(
          errorMessage:
              'No location updates for ${staleFor.inSeconds}s. Reconnecting...',
        ),
        tracking: _readState().tracking.copyWith(
          gpsSignal: const GpsSignalState(
            bars: 0,
            description: 'Searching',
          ),
        ),
      ),
    );

    return WatchdogAction.restart(
      staleFor: staleFor,
      staleThreshold: staleThreshold,
      hasReceivedSample: hasReceivedSample,
      activeTrackingMode: activeTrackingMode,
    );
  }

  /// Schedules the next watchdog check after [delay].
  void scheduleAfter(Duration delay) {
    _scheduleSampleWatchdogAfter(delay);
  }

  void dispose() {
    _sampleWatchdogTimer?.cancel();
    _sampleWatchdogTimer = null;
  }
}

// ---------------------------------------------------------------------------
// Action result type
// ---------------------------------------------------------------------------

enum WatchdogActionKind {
  none,
  reschedule,
  switchedToRecoveryMode,
  waitingForInitialSample,
  recoveryWait,
  restartCooldown,
  restart,
}

/// Describes the action the coordinator should take after a watchdog check.
class WatchdogAction {
  const WatchdogAction.none() : kind = WatchdogActionKind.none, data = null;

  const WatchdogAction.reschedule({
    required TrackingMode activeTrackingMode,
    required DateTime? lastSampleReceivedAtUtc,
    required DateTime? currentStreamStartedAtUtc,
  })  : kind = WatchdogActionKind.reschedule,
        data = null;

  WatchdogAction.switchedToRecoveryMode({
    required Duration staleFor,
    required Duration staleThreshold,
    required bool hasReceivedSample,
    required Duration recoveryThreshold,
  })  : kind = WatchdogActionKind.switchedToRecoveryMode,
        data = <String, dynamic>{
          'stale_for': staleFor,
          'stale_threshold': staleThreshold,
          'has_received_sample': hasReceivedSample,
          'recovery_threshold': recoveryThreshold,
        };

  WatchdogAction.waitingForInitialSample({
    required Duration staleFor,
    required Duration staleThreshold,
    required TrackingMode activeTrackingMode,
  })  : kind = WatchdogActionKind.waitingForInitialSample,
        data = <String, dynamic>{
          'stale_for': staleFor,
          'stale_threshold': staleThreshold,
          'active_tracking_mode': activeTrackingMode,
        };

  WatchdogAction.recoveryWait({
    required Duration staleFor,
    required Duration staleThreshold,
    required TrackingMode activeTrackingMode,
  })  : kind = WatchdogActionKind.recoveryWait,
        data = <String, dynamic>{
          'stale_for': staleFor,
          'stale_threshold': staleThreshold,
          'active_tracking_mode': activeTrackingMode,
        };

  WatchdogAction.restartCooldown({
    required Duration staleFor,
    required Duration staleThreshold,
    required int cooldownRemainingSeconds,
    required TrackingMode activeTrackingMode,
  })  : kind = WatchdogActionKind.restartCooldown,
        data = <String, dynamic>{
          'stale_for': staleFor,
          'stale_threshold': staleThreshold,
          'cooldown_remaining_seconds': cooldownRemainingSeconds,
          'active_tracking_mode': activeTrackingMode,
        };

  WatchdogAction.restart({
    required Duration staleFor,
    required Duration staleThreshold,
    required bool hasReceivedSample,
    required TrackingMode activeTrackingMode,
  })  : kind = WatchdogActionKind.restart,
        data = <String, dynamic>{
          'stale_for': staleFor,
          'stale_threshold': staleThreshold,
          'has_received_sample': hasReceivedSample,
          'active_tracking_mode': activeTrackingMode,
        };

  final WatchdogActionKind kind;
  final Map<String, dynamic>? data;
}
