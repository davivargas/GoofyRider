import 'session_models.dart';

class SessionStateMachine {
  const SessionStateMachine();

  static const Map<LocalSessionState, Set<LocalSessionState>>
      _allowedTransitions = <LocalSessionState, Set<LocalSessionState>>{
    LocalSessionState.idle: <LocalSessionState>{
      LocalSessionState.recording,
    },
    LocalSessionState.recording: <LocalSessionState>{
      LocalSessionState.paused,
      LocalSessionState.syncPending,
    },
    LocalSessionState.paused: <LocalSessionState>{
      LocalSessionState.recording,
      LocalSessionState.syncPending,
    },
    LocalSessionState.syncPending: <LocalSessionState>{
      LocalSessionState.syncing,
    },
    LocalSessionState.syncing: <LocalSessionState>{
      LocalSessionState.synced,
      LocalSessionState.syncFailed,
    },
    LocalSessionState.syncFailed: <LocalSessionState>{
      LocalSessionState.syncing,
    },
    LocalSessionState.synced: <LocalSessionState>{},
  };

  LocalSessionState transition(
    LocalSessionState current,
    LocalSessionState target,
  ) {
    final LocalSessionState canonicalCurrent = _canonical(current);
    final LocalSessionState canonicalTarget = _canonical(target);
    if (!_allowed(canonicalCurrent).contains(canonicalTarget)) {
      throw StateError(
          'Invalid transition: ${canonicalCurrent.wireValue} -> ${canonicalTarget.wireValue}');
    }
    return canonicalTarget;
  }

  Set<LocalSessionState> _allowed(LocalSessionState current) {
    return _allowedTransitions[current] ?? const <LocalSessionState>{};
  }

  LocalSessionState _canonical(LocalSessionState value) {
    if (value == LocalSessionState.locallyCompleted) {
      return LocalSessionState.syncPending;
    }
    return value;
  }
}
