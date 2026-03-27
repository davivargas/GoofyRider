import '../../../core/constants/session_constants.dart';
import 'location_tracking_repository.dart';

const int _maxStaleSampleThresholdSeconds = 120;

enum TrackingModePriority {
  highAccuracy,
  balancedPower,
}

/// Defines the location-request configuration used for a specific tracking mode.
///
/// A [TrackingModeProfile] describes how aggressively the app should request
/// location samples from Android for a particular motion state, such as active
/// downhill riding, lift travel, or idle periods.
///
/// Each attribute controls a different part of the trade-off between:
/// - spatial fidelity,
/// - temporal responsiveness,
/// - robustness against GNSS jitter,
/// - and battery consumption.
///
/// Attribute overview:
///
/// [priority]
/// Determines the requested location quality / power behavior.
///
/// A high-accuracy profile is used when the application needs the best possible
/// position quality and frequent updates, especially during motion states where
/// the path geometry matters and the user is covering distance quickly.
///
/// A balanced-power profile is used when the application can tolerate lower
/// update aggressiveness in exchange for reduced battery consumption, typically
/// during low-motion or stationary periods.
///
/// [intervalMs]
/// The target interval, in milliseconds, between requested location updates.
///
/// This value expresses the app's preferred cadence under normal conditions.
/// Smaller values increase temporal resolution and improve the ability to
/// reconstruct fast changes in movement, but they also increase power use.
///
/// [minIntervalMs]
/// The fastest interval, in milliseconds, at which the app is willing to accept
/// updates.
///
/// This value allows Android to deliver updates sooner than [intervalMs] when
/// fresher data is available. It is useful during dynamic motion because the
/// platform may occasionally provide valid fixes faster than the nominal target
/// interval.
///
/// [maxDelayMs]
/// The maximum amount of batching delay, in milliseconds, allowed before
/// updates are delivered.
///
/// If this value is larger than [intervalMs], Android may batch multiple
/// location samples and deliver them later together. This can reduce battery
/// usage, but it also reduces the "live" feel of tracking and can make motion
/// state transitions appear delayed.
///
/// For sports tracking, this value should remain tight in modes where the app
/// needs continuity and timely reaction, and can be more relaxed only in
/// low-motion states where delayed delivery is acceptable.
///
/// [minDistanceM]
/// The minimum displacement, in meters, required before a new location update
/// should be delivered.
///
/// This acts as a spatial filter. It helps reject tiny movements that are more
/// likely to represent GNSS noise than meaningful user motion.
///
/// A smaller value preserves more detail and is appropriate for fast or curved
/// motion, while a larger value suppresses noise and reduces unnecessary
/// updates in slower or stationary states.
///
/// [waitForAccurate]
/// Indicates whether the request should prefer waiting for a more accurate fix
/// before delivering early samples.
///
/// This is particularly useful during initialization or recovery, when the app
/// is trying to re-establish a trustworthy position solution. It is less useful
/// during normal tracking, where continuity is often more important than
/// waiting for a perfect fix.
///
/// Design intent:
///
/// The profiles in this file are chosen to match the physics of snow sports and
/// the behavior of Android location delivery:
/// - fast downhill motion needs dense, timely, high-quality samples;
/// - lift travel needs continuity but not descent-level density;
/// - stationary periods should strongly suppress jitter-driven false movement;
/// - recovery states should temporarily prioritize fix quality over efficiency.
///
/// Together, these settings aim to produce tracks that are smooth, believable,
/// and battery-conscious without sacrificing the quality needed for a
/// snowboarding session timeline.
class TrackingModeProfile {
  const TrackingModeProfile({
    required this.priority,
    required this.intervalMs,
    required this.minIntervalMs,
    required this.maxDelayMs,
    required this.minDistanceM,
    required this.waitForAccurate,
    required this.watchdogThresholdMs
  });

  final TrackingModePriority priority;
  final int intervalMs;
  final int minIntervalMs;
  final int maxDelayMs;
  final double minDistanceM;
  final bool waitForAccurate;
  final int watchdogThresholdMs;

  int get staleSampleThresholdSeconds =>
      ((watchdogThresholdMs + 999) ~/ 1000).clamp(
        SessionConstants.staleSampleThresholdSeconds,
        _maxStaleSampleThresholdSeconds,
      );

  Duration get sampleWatchdogThreshold =>
      Duration(milliseconds: watchdogThresholdMs);

  Map<String, dynamic> toChannelPayload() {
    return <String, dynamic>{
      'priority': switch (priority) {
        TrackingModePriority.highAccuracy => 'high_accuracy',
        TrackingModePriority.balancedPower => 'balanced_power',
      },
      'intervalMs': intervalMs,
      'minIntervalMs': minIntervalMs,
      'maxDelayMs': maxDelayMs,
      'minDistanceM': minDistanceM,
      'waitForAccurate': waitForAccurate,
    };
  }
}

/// Central registry of location-tracking profiles used by the session tracker.
///
/// Each predefined profile is tuned for a specific motion state observed during
/// a snowboarding session. The values are intentionally different because the
/// physical movement, acceptable latency, and tolerance for GNSS noise are not
/// the same across downhill riding, lift travel, walking, stationary time, and
/// recovery.
///
/// Even though [walkingSlow] and [stoppedIdle] are modeled as separate internal
/// modes, the app does not need to present that distinction to the user. For
/// display and session-summary purposes, both are treated as the same
/// user-facing category: "not on the tracks".
///
/// In other words, the tracking engine distinguishes more states than the UI
/// exposes. This allows the system to choose better Android location settings
/// for slow walking versus true idleness, while still keeping the visual
/// presentation simple. The app therefore displays only three high-level
/// movement categories:
/// - downhill,
/// - uphill,
/// - and "not on the tracks".
///
/// This separation is intentional:
/// - [walkingSlow] exists because real low-speed movement should still be
///   tracked continuously and should not be filtered as aggressively as a truly
///   stationary state;
/// - [stoppedIdle] exists because stationary periods are highly vulnerable to
///   GNSS drift and therefore benefit from much more conservative settings.
///
/// Mode design summary:
///
/// [activeDescent]
/// Used while the rider is moving downhill.
///
/// This is the most demanding mode because downhill motion is the fastest and
/// contains the most important path geometry, such as turns, speed changes, and
/// run shape. For this reason, it uses:
/// - high accuracy,
/// - near-real-time delivery,
/// - a short target interval,
/// - and a small spatial filter.
///
/// The chosen [minDistanceM] is intentionally low enough to preserve the shape
/// of the run, but still large enough to avoid overreacting to minor GNSS
/// jitter.
///
/// [initializingFix]
/// Used when the tracker is starting and needs an initial trustworthy fix.
///
/// This mode favors fix quality over continuity. The tracker is not yet trying
/// to reconstruct a ride segment in real time; instead, it is trying to
/// establish a reliable starting point before normal tracking begins.
///
/// For that reason, this mode:
/// - uses high accuracy,
/// - allows zero minimum distance,
/// - and enables [waitForAccurate].
///
/// [liftUphill]
/// Used while the rider is traveling uphill on a lift.
///
/// Lift motion is slower and usually follows a simple, low-curvature path.
/// However, it is still part of the session timeline and must remain continuous.
/// This mode therefore still favors accurate and timely updates, but does not
/// need the same density as [activeDescent].
///
/// The chosen values intentionally:
/// - keep delivery responsive enough to avoid apparent gaps,
/// - reduce sampling density relative to downhill mode,
/// - and increase the spatial filter because lift motion is smoother and less
///   geometrically demanding.
///
/// [walkingSlow]
/// Used when the user is moving slowly on foot rather than riding.
///
/// This mode covers real low-speed movement, such as walking near the base
/// area, moving between lifts, or repositioning with the snowboard off.
/// Although this state is shown in the app as part of "not on the tracks", it
/// is internally separated from [stoppedIdle] because walking is genuine motion
/// and should be preserved with more responsive and less aggressive filtering.
///
/// The chosen values intentionally:
/// - maintain good positional quality,
/// - keep updates reasonably timely,
/// - and apply a moderate distance threshold that is sensitive enough for
///   walking while still filtering out small GNSS fluctuations.
///
/// [stoppedIdle]
/// Used when the rider is stationary or nearly stationary.
///
/// In this mode, the main risk is not missing real path detail, but incorrectly
/// interpreting GNSS drift as actual motion. For that reason, the profile is
/// designed to be conservative.
///
/// Although this mode is presented in the app under the same user-facing
/// category as [walkingSlow], it is kept separate internally because true
/// idleness requires much stronger filtering and lower update pressure than
/// genuine slow movement.
///
/// The chosen values:
/// - reduce power usage,
/// - lengthen the update interval,
/// - and use a significantly larger minimum distance threshold.
///
/// This helps suppress false movement while still allowing the tracker to remain
/// aware of the session state.
///
/// [lowConfidenceRecovery]
/// Used when the tracker believes recent samples are not trustworthy and it
/// must recover a stable position solution.
///
/// This mode behaves similarly to [initializingFix]. Its purpose is to restore
/// confidence in the location stream as quickly as possible before returning to
/// a normal operational mode.
///
/// As a result, it temporarily prioritizes:
/// - high accuracy,
/// - short intervals,
/// - zero minimum distance,
/// - and waiting for a more accurate fix.
///
/// Practical note:
///
/// These profiles should not be viewed as isolated numeric presets. Their
/// behavior emerges from the interaction of:
/// - timing,
/// - batching,
/// - spatial filtering,
/// - Android provider behavior,
/// - and the movement classifier that selects the active mode.
///
/// Small changes to one field can materially affect how stable, responsive,
/// and believable the final session track appears.
class TrackingModeProfiles {
  TrackingModeProfiles._();
  
  /// Profile used while acquiring the initial reliable position fix.
  ///
  /// At startup, the tracker benefits more from obtaining a trustworthy
  /// position than from immediately streaming ordinary samples. This mode is
  /// therefore intentionally aggressive about quality and permissive about
  /// distance, allowing the system to lock onto a solid location solution
  /// before the session transitions into regular tracking.
  ///
  /// Chosen values:
  /// - [TrackingModePriority.highAccuracy] to maximize fix quality.
  /// - [intervalMs] = 1000 to request frequent attempts without being extreme.
  /// - [minIntervalMs] = 500 to allow somewhat faster delivery if available.
  /// - [maxDelayMs] = 0 to avoid batching during initialization.
  /// - [minDistanceM] = 0 because no displacement filtering should block the
  ///   first useful fix.
  /// - [waitForAccurate] = true because initialization should favor confidence
  ///   over immediate continuity.
  static const TrackingModeProfile initializingFix = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 1000,
    minIntervalMs: 500,
    maxDelayMs: 0,
    minDistanceM: 0,
    waitForAccurate: true,
    watchdogThresholdMs: 5000,
  );

  /// Profile used during active downhill riding.
  ///
  /// This mode prioritizes track fidelity because downhill movement is fast and
  /// direction changes matter for reconstructing the run shape. The request is
  /// configured to behave close to real time, with minimal batching and a small
  /// distance threshold so that the tracker captures meaningful motion without
  /// being polluted by very small GNSS fluctuations.
  ///
  /// Chosen values:
  /// - [TrackingModePriority.highAccuracy] because descent is the most demanding
  ///   state for spatial precision.
  /// - [intervalMs] = 900 to target roughly 1 Hz tracking with enough density
  ///   for consumer sports recording.
  /// - [minIntervalMs] = 250 to allow short bursts of faster delivery when the
  ///   provider has fresher samples available.
  /// - [maxDelayMs] = 900 to avoid meaningful batching and preserve continuity.
  /// - [minDistanceM] = 5 to preserve downhill geometry while filtering out
  ///   minor jitter.
  /// - [waitForAccurate] = false because continuity during motion is more
  ///   important than pausing for an ideal fix.
  static const TrackingModeProfile activeDescent = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 900,
    minIntervalMs: 250,
    maxDelayMs: 900,
    minDistanceM: 5,
    waitForAccurate: false,
    watchdogThresholdMs: 4000,
  );


  /// Profile used during uphill lift travel.
  ///
  /// Lift motion is slower and usually follows a simple path, so it does not
  /// require the same point density as downhill riding. However, it still forms
  /// part of the session timeline and should remain continuous and believable.
  ///
  /// This profile therefore reduces sampling aggressiveness compared with
  /// downhill mode while still preserving timely delivery and sufficient
  /// accuracy for reliable state tracking.
  ///
  /// Chosen values:
  /// - [TrackingModePriority.highAccuracy] because mountain environments can be
  ///   challenging and the app still needs consistent positional quality.
  /// - [intervalMs] = 2500 because lift travel does not require near-1 Hz
  ///   density, but still benefits from regular updates.
  /// - [minIntervalMs] = 1500 to accept moderately faster samples when useful.
  /// - [maxDelayMs] = 2500 to keep delivery close to live and avoid noticeable
  ///   batching gaps.
  /// - [minDistanceM] = 10 because lift motion is smooth and low-curvature, so
  ///   a larger spatial filter reduces unnecessary samples without harming the
  ///   reconstructed path.
  /// - [waitForAccurate] = false because continuity is preferable during normal
  ///   uphill session tracking.
  static const TrackingModeProfile liftUphill = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 2500,
    minIntervalMs: 1500,
    maxDelayMs: 2500,
    minDistanceM: 10,
    waitForAccurate: false,
    watchdogThresholdMs: 7000,
  );

  /// Profile used when the user is moving slowly on foot rather than riding.
  ///
  /// This mode is intended for real movement that is slower than lift travel and
  /// far less dynamic than downhill descent, such as walking near the base area,
  /// moving between lifts, or repositioning with the snowboard off.
  ///
  /// Walking should not be treated the same as true idle. Unlike stationary
  /// periods, the user is genuinely changing position and the tracker should
  /// preserve that motion. At the same time, walking does not require the point
  /// density used for downhill riding.
  ///
  /// This profile therefore keeps location quality reasonably high, uses a
  /// moderate request interval, and applies a middle-ground spatial filter that
  /// captures real foot movement while suppressing very small GNSS fluctuations.
  ///
  /// Chosen values:
  /// - [TrackingModePriority.highAccuracy] because walking still represents real
  ///   movement and should remain spatially believable in the session timeline.
  /// - [intervalMs] = 3000 because walking does not need dense sub-second updates,
  ///   but should still feel continuous.
  /// - [minIntervalMs] = 1500 to allow somewhat faster delivery when fresher
  ///   samples are available.
  /// - [maxDelayMs] = 3000 to keep the stream close to live and avoid noticeable
  ///   batching during slow motion.
  /// - [minDistanceM] = 8 because walking covers distance more slowly than lift
  ///   or descent modes, yet still benefits from a threshold small enough to
  ///   represent genuine movement without reacting to tiny jitter.
  /// - [waitForAccurate] = false because this is a normal operating mode, not an
  ///   initialization or recovery state.
  static const TrackingModeProfile walkingSlow = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 3000,
    minIntervalMs: 1500,
    maxDelayMs: 3000,
    minDistanceM: 8,
    waitForAccurate: false,
    watchdogThresholdMs: 8000,
  );

  /// Profile used when the rider is stationary or nearly stationary.
  ///
  /// In idle conditions, the dominant technical problem is often GNSS drift
  /// rather than true motion. If the profile is too sensitive, the tracker may
  /// incorrectly interpret noise as movement and create false path segments.
  ///
  /// This mode is intentionally conservative. It slows the request cadence,
  /// allows lower power behavior, and uses a much larger distance threshold to
  /// suppress jitter-driven updates.
  ///
  /// Chosen values:
  /// - [TrackingModePriority.balancedPower] because idle tracking does not need
  ///   the same intensity as active motion states.
  /// - [intervalMs] = 15000 because the app only needs periodic awareness while
  ///   stopped.
  /// - [minIntervalMs] = 10000 to avoid unnecessary update pressure in a state
  ///   where little meaningful movement is expected.
  /// - [maxDelayMs] = 15000 to keep behavior predictable without introducing
  ///   very long batching windows.
  /// - [minDistanceM] = 25 to strongly suppress false movement caused by normal
  ///   location jitter while stationary.
  /// - [waitForAccurate] = false because the tracker is not attempting to
  ///   recover or initialize a new fix in this state.
  static const TrackingModeProfile stoppedIdle = TrackingModeProfile(
    priority: TrackingModePriority.balancedPower,
    intervalMs: 15000,
    minIntervalMs: 10000,
    maxDelayMs: 15000,
    minDistanceM: 25,
    waitForAccurate: false,
    watchdogThresholdMs: 25000,
  );

  /// Profile used when recent samples are considered unreliable and the tracker
  /// needs to recover location confidence.
  ///
  /// This mode is a temporary corrective state. Its job is not to optimize
  /// battery usage or maintain ordinary tracking cadence, but to restore a
  /// trustworthy position stream as quickly as possible so the tracker can
  /// safely return to a normal movement mode.
  ///
  /// Chosen values:
  /// - [TrackingModePriority.highAccuracy] to maximize recovery quality.
  /// - [intervalMs] = 1000 to request frequent fresh samples.
  /// - [minIntervalMs] = 500 to allow quicker recovery if the provider can
  ///   deliver data sooner.
  /// - [maxDelayMs] = 0 to avoid batching during recovery.
  /// - [minDistanceM] = 0 because displacement filtering should not block
  ///   recovery samples.
  /// - [waitForAccurate] = true because confidence restoration is the main goal
  ///   of this mode.
  static const TrackingModeProfile lowConfidenceRecovery = TrackingModeProfile(
    priority: TrackingModePriority.highAccuracy,
    intervalMs: 1000,
    minIntervalMs: 500,
    maxDelayMs: 0,
    minDistanceM: 0,
    waitForAccurate: true,
    watchdogThresholdMs: 5000,
  );

  static TrackingModeProfile forMode(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.initializingFix:
        return initializingFix;
      case TrackingMode.activeDescent:
        return activeDescent;
      case TrackingMode.liftUphill:
        return liftUphill;
      case TrackingMode.walkingSlow:
        return walkingSlow;
      case TrackingMode.stoppedIdle:
        return stoppedIdle;
      case TrackingMode.lowConfidenceRecovery:
        return lowConfidenceRecovery;
    }
  }
}
