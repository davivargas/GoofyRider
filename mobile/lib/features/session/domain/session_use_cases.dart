import 'session_models.dart';
import 'session_repository.dart';

class StartLocalSession {
  const StartLocalSession(this._repository);

  final SessionRepository _repository;

  Future<LocalRideSession> call({String? resortId}) {
    return _repository.startLocalSession(resortId: resortId);
  }
}

class PauseLocalSession {
  const PauseLocalSession(this._repository);

  final SessionRepository _repository;

  Future<LocalRideSession> call(int localSessionId) {
    return _repository.pauseLocalSession(localSessionId);
  }
}

class ResumeLocalSession {
  const ResumeLocalSession(this._repository);

  final SessionRepository _repository;

  Future<LocalRideSession> call(int localSessionId) {
    return _repository.resumeLocalSession(localSessionId);
  }
}

class AppendLocationPoint {
  const AppendLocationPoint(this._repository);

  final SessionRepository _repository;

  Future<void> call(int localSessionId, NewSessionPoint point) {
    return _repository.appendLocationPoint(localSessionId, point);
  }
}

class FinishLocalSession {
  const FinishLocalSession(this._repository);

  final SessionRepository _repository;

  Future<LocalRideSession> call(int localSessionId) {
    return _repository.finishLocalSession(localSessionId);
  }
}

class RecoverInProgressSession {
  const RecoverInProgressSession(this._repository);

  final SessionRepository _repository;

  Future<LocalRideSession?> call() {
    return _repository.recoverInProgressSession();
  }
}

class ComputeSessionStats {
  const ComputeSessionStats(this._repository);

  final SessionRepository _repository;

  Future<SessionStats> call(int localSessionId) {
    return _repository.computeSessionStats(localSessionId);
  }
}

class SyncSession {
  const SyncSession(this._repository);

  final SessionRepository _repository;

  Future<LocalRideSession> call(int localSessionId) {
    return _repository.syncSession(localSessionId);
  }
}

class RetryFailedSync {
  const RetryFailedSync(this._repository);

  final SessionRepository _repository;

  Future<LocalRideSession> call(int localSessionId) {
    return _repository.retryFailedSync(localSessionId);
  }
}

class ListLocalAndRemoteSessionHistory {
  const ListLocalAndRemoteSessionHistory(this._repository);

  final SessionRepository _repository;

  Future<List<LocalRideSession>> call() {
    return _repository.listLocalAndRemoteSessionHistory();
  }
}

class GetSessionDetail {
  const GetSessionDetail(this._repository);

  final SessionRepository _repository;

  Future<SessionDetail> call(int localSessionId) {
    return _repository.getSessionDetail(localSessionId);
  }
}
