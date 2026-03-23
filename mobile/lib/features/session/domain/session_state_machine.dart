import 'session_models.dart';

class SessionStateMachine {
  const SessionStateMachine();

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
    switch (current) {
      case LocalSessionState.idle:
        return <LocalSessionState>{LocalSessionState.recording};
      case LocalSessionState.recording:
        return <LocalSessionState>{
          LocalSessionState.paused,
          LocalSessionState.syncPending,
        };
      case LocalSessionState.paused:
        return <LocalSessionState>{
          LocalSessionState.recording,
          LocalSessionState.syncPending,
        };
      case LocalSessionState.locallyCompleted:
        // Canonicalization absorbs this legacy value before transition checks.
        return <LocalSessionState>{};
      case LocalSessionState.syncPending:
        return <LocalSessionState>{LocalSessionState.syncing};
      case LocalSessionState.syncing:
        return <LocalSessionState>{
          LocalSessionState.synced,
          LocalSessionState.syncFailed,
        };
      case LocalSessionState.syncFailed:
        return <LocalSessionState>{LocalSessionState.syncing};
      case LocalSessionState.synced:
        return <LocalSessionState>{};
    }
  }

  LocalSessionState _canonical(LocalSessionState value) {
    if (value == LocalSessionState.locallyCompleted) {
      return LocalSessionState.syncPending;
    }
    return value;
  }
}
