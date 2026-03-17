import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_state_machine.dart';

void main() {
  const SessionStateMachine machine = SessionStateMachine();

  test('allows recording -> paused -> recording', () {
    final LocalSessionState paused =
        machine.transition(LocalSessionState.recording, LocalSessionState.paused);
    final LocalSessionState resumed =
        machine.transition(paused, LocalSessionState.recording);

    expect(paused, LocalSessionState.paused);
    expect(resumed, LocalSessionState.recording);
  });

  test('allows syncFailed -> syncing', () {
    final LocalSessionState syncing =
        machine.transition(LocalSessionState.syncFailed, LocalSessionState.syncing);
    expect(syncing, LocalSessionState.syncing);
  });

  test('rejects synced -> recording', () {
    expect(
      () => machine.transition(LocalSessionState.synced, LocalSessionState.recording),
      throwsStateError,
    );
  });

  test('rejects locallyCompleted -> recording', () {
    expect(
      () => machine.transition(LocalSessionState.locallyCompleted, LocalSessionState.recording),
      throwsStateError,
    );
  });
}
