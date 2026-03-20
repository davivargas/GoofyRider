import 'session_models.dart';

abstract class SessionRepository {
  Future<LocalRideSession> startLocalSession({String? resortId});
  Future<LocalRideSession> pauseLocalSession(int localSessionId);
  Future<LocalRideSession> resumeLocalSession(int localSessionId);
  Future<void> appendLocationPoint(int localSessionId, NewSessionPoint point);
  Future<LocalRideSession> finishLocalSession(
    int localSessionId, {
    int? activeDurationS,
  });
  Future<LocalRideSession?> recoverInProgressSession();
  Future<SessionStats> computeSessionStats(int localSessionId);
  Future<LocalRideSession> syncSession(int localSessionId);
  Future<LocalRideSession> retryFailedSync(int localSessionId);
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory();
  Future<List<LocalRideSession>> listPendingSyncSessions();
  Future<void> refreshRemoteSessionHistoryCache();
  Future<SessionDetail> getSessionDetail(int localSessionId);
  Future<void> recordTrackingDiagnostic(
    int localSessionId, {
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  });
  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit,
  });
  Future<int> unsyncedCount();
}

class SessionDetail {
  const SessionDetail({
    required this.session,
    required this.points,
    required this.acceptedPoints,
    required this.trackingDiagnostics,
  });

  final LocalRideSession session;
  final List<LocalSessionPoint> points;
  final List<LocalSessionPoint> acceptedPoints;
  final List<TrackingDiagnosticEvent> trackingDiagnostics;
}
