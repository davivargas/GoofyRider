import 'dart:async';

import '../recording_view_state.dart';

/// Manages the elapsed-time clock for an active recording session.
///
/// Tracks the accumulated duration across pause/resume cycles and drives a
/// one-second periodic ticker that pushes elapsed updates into the view state.
///
/// Does **not** extend `StateNotifier` — the coordinator owns the state.
class ElapsedTimerManager {
  ElapsedTimerManager({
    required RecordingViewState Function() readState,
    required void Function(RecordingViewState) writeState,
  })  : _readState = readState,
        _writeState = writeState;

  final RecordingViewState Function() _readState;
  final void Function(RecordingViewState) _writeState;

  Timer? _elapsedTicker;
  Duration elapsedBeforeActive = Duration.zero;
  DateTime? activeSegmentStartedAtUtc;

  // ---------------------------------------------------------------------------
  // Clock lifecycle
  // ---------------------------------------------------------------------------

  /// Begins (or resumes) the active elapsed clock.
  void startActiveElapsedClock() {
    activeSegmentStartedAtUtc = DateTime.now().toUtc();
    _startElapsedTicker();
    _pushElapsedTick();
  }

  /// Pauses the elapsed clock, accumulating the active segment duration.
  void pauseElapsedClock() {
    final DateTime? activeStartedAt = activeSegmentStartedAtUtc;
    if (activeStartedAt != null) {
      final Duration delta =
          DateTime.now().toUtc().difference(activeStartedAt);
      if (!delta.isNegative) {
        elapsedBeforeActive += delta;
      }
    }
    activeSegmentStartedAtUtc = null;
    stopElapsedTicker();
    _pushElapsedTick();
  }

  /// Returns the total elapsed duration including the current active segment.
  Duration currentElapsedDuration() {
    final DateTime? activeStartedAt = activeSegmentStartedAtUtc;
    if (activeStartedAt == null) {
      return elapsedBeforeActive;
    }

    final Duration activeDelta =
        DateTime.now().toUtc().difference(activeStartedAt);
    if (activeDelta.isNegative) {
      return elapsedBeforeActive;
    }
    return elapsedBeforeActive + activeDelta;
  }

  /// Stops the periodic ticker without accumulating the active segment.
  void stopElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
  }

  /// Resets all timing state to zero.
  void reset() {
    elapsedBeforeActive = Duration.zero;
    activeSegmentStartedAtUtc = null;
    stopElapsedTicker();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _startElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      _pushElapsedTick();
    });
  }

  void _pushElapsedTick() {
    final Duration elapsed = currentElapsedDuration();
    if (elapsed.inSeconds == _readState().tracking.elapsed.inSeconds) {
      return;
    }
    _writeState(
      _readState().copyWith(
        tracking: _readState().tracking.copyWith(elapsed: elapsed),
      ),
    );
  }

  void dispose() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
  }
}
