import '../../../../core/constants/session_constants.dart';
import '../../domain/session_models.dart';

/// Tracks sustained stillness during an active recording so the controller
/// can auto-pause the session after [stillnessThresholdSeconds] of contiguous
/// low-speed samples that stayed inside [maxDriftMeters] of the anchor fix.
///
/// Follows §4.2 of the GPS stack overhaul plan: the stream stays at 1 Hz
/// HIGH_ACCURACY during recording, and auto-pause is what turns the lodge
/// break into near-zero drain instead of 40 min of polling.
///
/// Any motion (speed ≥ [SessionConstants.stoppedSpeedThresholdMetersPerSecond])
/// or a drift excursion beyond [maxDriftMeters] resets the window — a slow
/// traverse or a walk across the lodge patio should not accidentally pause.
class AutoPauseTracker {
  AutoPauseTracker({
    this.stillnessThresholdSeconds =
        SessionConstants.autoPauseStillnessThresholdSeconds,
    this.maxDriftMeters = SessionConstants.autoPauseMaxDriftMeters,
  });

  final int stillnessThresholdSeconds;
  final double maxDriftMeters;

  DateTime? _stillnessStartedAtUtc;
  double? _anchorLatitude;
  double? _anchorLongitude;

  /// Whether the tracker is currently inside a stillness window.
  bool get isTrackingStillness => _stillnessStartedAtUtc != null;

  DateTime? get stillnessStartedAtUtc => _stillnessStartedAtUtc;

  /// Feed an accepted sample into the tracker. Returns a decision describing
  /// whether this sample just crossed the auto-pause threshold.
  ///
  /// The caller must only pass samples that belong to the currently active
  /// recording epoch and that were accepted by the pipeline — rejected
  /// samples would otherwise falsely lengthen a stillness window during GPS
  /// glitches.
  AutoPauseDecision observe({
    required DateTime sampleTimeUtc,
    required double latitude,
    required double longitude,
    required double speedMps,
  }) {
    if (speedMps >= SessionConstants.stoppedSpeedThresholdMetersPerSecond) {
      reset();
      return const AutoPauseDecision.moving();
    }

    final startedAt = _stillnessStartedAtUtc;
    if (startedAt == null) {
      _stillnessStartedAtUtc = sampleTimeUtc;
      _anchorLatitude = latitude;
      _anchorLongitude = longitude;
      return const AutoPauseDecision.still(
        stillnessDurationS: 0,
        triggered: false,
      );
    }

    final driftM = haversineDistanceMeters(
      _anchorLatitude!,
      _anchorLongitude!,
      latitude,
      longitude,
    );
    if (driftM > maxDriftMeters) {
      // Walked out of the anchor radius — treat as motion and re-anchor.
      _stillnessStartedAtUtc = sampleTimeUtc;
      _anchorLatitude = latitude;
      _anchorLongitude = longitude;
      return const AutoPauseDecision.moving();
    }

    final stillnessDurationS =
        sampleTimeUtc.difference(startedAt).inSeconds;
    return AutoPauseDecision.still(
      stillnessDurationS: stillnessDurationS,
      triggered: stillnessDurationS >= stillnessThresholdSeconds,
    );
  }

  /// Clears the stillness window — call on start / pause / resume / finish
  /// / stream restart so the next active phase starts from a clean anchor.
  void reset() {
    _stillnessStartedAtUtc = null;
    _anchorLatitude = null;
    _anchorLongitude = null;
  }
}

class AutoPauseDecision {
  const AutoPauseDecision._({
    required this.isStill,
    required this.stillnessDurationS,
    required this.triggered,
  });

  const AutoPauseDecision.moving()
      : isStill = false,
        stillnessDurationS = 0,
        triggered = false;

  const AutoPauseDecision.still({
    required int stillnessDurationS,
    required bool triggered,
  }) : this._(
          isStill: true,
          stillnessDurationS: stillnessDurationS,
          triggered: triggered,
        );

  final bool isStill;
  final int stillnessDurationS;
  final bool triggered;
}
