import 'dart:async';

import '../../domain/session_models.dart';
import '../../domain/session_repository.dart';
import '../recording_view_state.dart';

const Duration _backgroundSyncRetryInterval = Duration(minutes: 2);

/// Manages the periodic background sync loop that pushes finished sessions to
/// the server.
///
/// Does **not** extend `StateNotifier` — the coordinator owns the state.
class BackgroundSyncManager {
  BackgroundSyncManager({
    required SessionRepository sessionRepository,
    required RecordingViewState Function() readState,
    required void Function(RecordingViewState) writeState,
  })  : _sessionRepository = sessionRepository,
        _readState = readState,
        _writeState = writeState;

  final SessionRepository _sessionRepository;
  final RecordingViewState Function() _readState;
  final void Function(RecordingViewState) _writeState;

  Timer? _backgroundSyncTicker;
  bool _backgroundSyncInFlight = false;
  bool _backgroundSyncQueued = false;
  Completer<void>? _backgroundSyncCycleCompleter;

  /// Starts the periodic timer that triggers [runPendingSyncPass] every
  /// [_backgroundSyncRetryInterval].
  void startBackgroundSyncLoop() {
    _backgroundSyncTicker?.cancel();
    _backgroundSyncTicker = Timer.periodic(_backgroundSyncRetryInterval, (_) {
      unawaited(runPendingSyncPass());
    });
  }

  /// Runs a single sync pass, syncing all pending sessions and refreshing the
  /// remote history cache.
  ///
  /// The [isMounted] callback lets the caller gate writes on whether the
  /// owning `StateNotifier` is still alive.
  Future<void> runPendingSyncPass({
    bool showDebugStatus = false,
    bool Function()? isMounted,
  }) async {
    bool mounted() => isMounted?.call() ?? true;

    if (_readState().phase == RecordScreenPhase.recording) {
      if (showDebugStatus && mounted()) {
        _writeState(
          _readState().copyWith(
            sync: _readState().sync.copyWith(
              lastSyncMessage: 'Sync deferred until recording finishes.',
            ),
          ),
        );
      }
      return;
    }

    if (_backgroundSyncInFlight) {
      _backgroundSyncQueued = true;
      final activeCycle = _backgroundSyncCycleCompleter;
      if (activeCycle != null) {
        await activeCycle.future;
      }
      if (_backgroundSyncQueued && mounted()) {
        _backgroundSyncQueued = false;
        return runPendingSyncPass(
          showDebugStatus: showDebugStatus,
          isMounted: isMounted,
        );
      }
      return;
    }

    _backgroundSyncInFlight = true;
    _backgroundSyncCycleCompleter = Completer<void>();
    try {
      final pending =
          await _sessionRepository.listPendingSyncSessions();

      var syncedCount = 0;
      var failedCount = 0;
      for (final session in pending) {
        try {
          final result =
              await _sessionRepository.syncSession(session.localId);
          if (result.state == LocalSessionState.synced) {
            syncedCount += 1;
          } else if (result.state == LocalSessionState.syncFailed) {
            failedCount += 1;
          }
        } catch (_) {
          failedCount += 1;
        }
      }

      await _sessionRepository.refreshRemoteSessionHistoryCache();

      if (!mounted()) {
        return;
      }
      _writeState(
        _readState().copyWith(
          sync: _readState().sync.copyWith(
            historyRevision: _readState().sync.historyRevision + 1,
            lastSyncMessage: showDebugStatus
                ? _syncDebugMessage(
                    totalCount: pending.length,
                    syncedCount: syncedCount,
                    failedCount: failedCount,
                  )
                : _readState().sync.lastSyncMessage,
          ),
        ),
      );
    } catch (_) {
      if (showDebugStatus && mounted()) {
        _writeState(
          _readState().copyWith(
            sync: _readState().sync.copyWith(
              lastSyncMessage: 'Sync pass failed.',
            ),
          ),
        );
      }
    } finally {
      _backgroundSyncInFlight = false;
      final activeCycle = _backgroundSyncCycleCompleter;
      _backgroundSyncCycleCompleter = null;
      if (activeCycle != null && !activeCycle.isCompleted) {
        activeCycle.complete();
      }
    }
  }

  String _syncDebugMessage({
    required int totalCount,
    required int syncedCount,
    required int failedCount,
  }) {
    if (totalCount == 0) {
      return 'No pending sync work.';
    }
    return 'Sync pass: $syncedCount/$totalCount synced'
        '${failedCount > 0 ? ', $failedCount failed' : ''}.';
  }

  void dispose() {
    _backgroundSyncTicker?.cancel();
    _backgroundSyncTicker = null;
  }
}
