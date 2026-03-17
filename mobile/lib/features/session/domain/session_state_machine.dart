import 'session_models.dart';

class SessionStateMachine {
  const SessionStateMachine();

  LocalSessionState transition(
    LocalSessionState current,
    LocalSessionState target,
  ) {
    if (!_allowed(current).contains(target)) {
      throw StateError('Invalid transition: ${current.wireValue} -> ${target.wireValue}');
    }
    return target;
  }

  Set<LocalSessionState> _allowed(LocalSessionState current) {
    switch (current) {
      case LocalSessionState.idle:
        return <LocalSessionState>{LocalSessionState.recording};
      case LocalSessionState.recording:
        return <LocalSessionState>{
          LocalSessionState.paused,
          LocalSessionState.locallyCompleted,
        };
      case LocalSessionState.paused:
        return <LocalSessionState>{
          LocalSessionState.recording,
          LocalSessionState.locallyCompleted,
        };
      case LocalSessionState.locallyCompleted:
        return <LocalSessionState>{LocalSessionState.syncPending};
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
}
