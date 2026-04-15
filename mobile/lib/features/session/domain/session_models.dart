import 'dart:math' as math;

enum LocalSessionState {
  idle,
  recording,
  paused,
  // Legacy-only transient state kept for backward compatibility with old rows.
  locallyCompleted,
  syncPending,
  syncing,
  synced,
  syncFailed,
}

extension LocalSessionStateCodec on LocalSessionState {
  String get wireValue {
    switch (this) {
      case LocalSessionState.idle:
        return 'idle';
      case LocalSessionState.recording:
        return 'recording';
      case LocalSessionState.paused:
        return 'paused';
      case LocalSessionState.locallyCompleted:
        return 'locallyCompleted';
      case LocalSessionState.syncPending:
        return 'syncPending';
      case LocalSessionState.syncing:
        return 'syncing';
      case LocalSessionState.synced:
        return 'synced';
      case LocalSessionState.syncFailed:
        return 'syncFailed';
    }
  }

  static LocalSessionState fromWire(String value) {
    switch (value) {
      case 'idle':
        return LocalSessionState.idle;
      case 'recording':
        return LocalSessionState.recording;
      case 'paused':
        return LocalSessionState.paused;
      case 'locallyCompleted':
        // Legacy rows are normalized into syncPending lifecycle.
        return LocalSessionState.syncPending;
      case 'syncPending':
        return LocalSessionState.syncPending;
      case 'syncing':
        return LocalSessionState.syncing;
      case 'synced':
        return LocalSessionState.synced;
      case 'syncFailed':
        return LocalSessionState.syncFailed;
      default:
        return LocalSessionState.idle;
    }
  }
}

class LocalRideSession {
  const LocalRideSession({
    required this.localId,
    required this.ownerUserId,
    required this.remoteId,
    required this.resortId,
    required this.startedAt,
    required this.endedAt,
    required this.activeDurationS,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.elevationGainM,
    required this.elevationLossM,
    required this.state,
    required this.pointCount,
    required this.syncAttemptCount,
    required this.lastSyncError,
    required this.createdAt,
    required this.updatedAt,
  });

  final int localId;
  final String? ownerUserId;
  final String? remoteId;
  final String? resortId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int activeDurationS;
  final double distanceM;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final int? elevationGainM;
  final int? elevationLossM;
  final LocalSessionState state;
  final int pointCount;
  final int syncAttemptCount;
  final String? lastSyncError;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isUnsynced =>
      state == LocalSessionState.syncPending ||
      state == LocalSessionState.syncing ||
      state == LocalSessionState.syncFailed;

  bool get isInProgress =>
      state == LocalSessionState.recording || state == LocalSessionState.paused;
}

/// Abstract base declaring the shared fields of every session-point variant.
///
/// Concrete subclasses keep their own `const` constructors and `final` fields
/// which automatically satisfy the abstract getters declared here.
abstract class SessionPointBase {
  const SessionPointBase();

  DateTime get recordedAt;
  int get tOffsetMs;
  double get latitude;
  double get longitude;
  double? get accuracyM;
  double? get altitudeM;
  double? get speedMps;
  double? get headingDeg;
  bool get acceptedForAnalytics;
  int? get elapsedRealtimeNs;
  double? get verticalAccuracyM;
  double? get speedAccuracyMps;
  double? get bearingAccuracyDeg;
  String? get provider;
  bool? get isMocked;
  String? get qualityClass;
  double? get qualityScore;
  String? get qualityReason;
  double? get filteredLatitude;
  double? get filteredLongitude;
  double? get filteredAltitudeM;
  double? get fusedSpeedMps;
  double? get derivedSpeedMps;
  double? get distanceDeltaM;
  String? get motionState;

  /// Alias kept for call-site readability.
  int get elapsedOffsetMs => tOffsetMs;
}

class LocalSessionPoint extends SessionPointBase {
  const LocalSessionPoint({
    required this.id,
    required this.localSessionId,
    required this.recordedAt,
    required this.tOffsetMs,
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.altitudeM,
    required this.speedMps,
    required this.headingDeg,
    required this.acceptedForAnalytics,
    this.elapsedRealtimeNs,
    this.verticalAccuracyM,
    this.speedAccuracyMps,
    this.bearingAccuracyDeg,
    this.provider,
    this.isMocked,
    this.qualityClass,
    this.qualityScore,
    this.qualityReason,
    this.filteredLatitude,
    this.filteredLongitude,
    this.filteredAltitudeM,
    this.fusedSpeedMps,
    this.derivedSpeedMps,
    this.distanceDeltaM,
    this.motionState,
  });

  final int id;
  final int localSessionId;
  @override
  final DateTime recordedAt;
  @override
  final int tOffsetMs;
  @override
  final double latitude;
  @override
  final double longitude;
  @override
  final double? accuracyM;
  @override
  final double? altitudeM;
  @override
  final double? speedMps;
  @override
  final double? headingDeg;
  @override
  final bool acceptedForAnalytics;
  @override
  final int? elapsedRealtimeNs;
  @override
  final double? verticalAccuracyM;
  @override
  final double? speedAccuracyMps;
  @override
  final double? bearingAccuracyDeg;
  @override
  final String? provider;
  @override
  final bool? isMocked;
  @override
  final String? qualityClass;
  @override
  final double? qualityScore;
  @override
  final String? qualityReason;
  @override
  final double? filteredLatitude;
  @override
  final double? filteredLongitude;
  @override
  final double? filteredAltitudeM;
  @override
  final double? fusedSpeedMps;
  @override
  final double? derivedSpeedMps;
  @override
  final double? distanceDeltaM;
  @override
  final String? motionState;
}

class TrackingDiagnosticEvent {
  const TrackingDiagnosticEvent({
    required this.id,
    required this.localSessionId,
    required this.occurredAt,
    required this.eventType,
    required this.message,
    required this.details,
  });

  final int id;
  final int localSessionId;
  final DateTime occurredAt;
  final String eventType;
  final String? message;
  final Map<String, dynamic> details;
}

class NewSessionPoint extends SessionPointBase {
  const NewSessionPoint({
    required this.recordedAt,
    required this.tOffsetMs,
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.altitudeM,
    required this.speedMps,
    required this.headingDeg,
    required this.acceptedForAnalytics,
    this.elapsedRealtimeNs,
    this.verticalAccuracyM,
    this.speedAccuracyMps,
    this.bearingAccuracyDeg,
    this.provider,
    this.isMocked,
    this.qualityClass,
    this.qualityScore,
    this.qualityReason,
    this.filteredLatitude,
    this.filteredLongitude,
    this.filteredAltitudeM,
    this.fusedSpeedMps,
    this.derivedSpeedMps,
    this.distanceDeltaM,
    this.motionState,
  });

  @override
  final DateTime recordedAt;
  @override
  final int tOffsetMs;
  @override
  final double latitude;
  @override
  final double longitude;
  @override
  final double? accuracyM;
  @override
  final double? altitudeM;
  @override
  final double? speedMps;
  @override
  final double? headingDeg;
  @override
  final bool acceptedForAnalytics;
  @override
  final int? elapsedRealtimeNs;
  @override
  final double? verticalAccuracyM;
  @override
  final double? speedAccuracyMps;
  @override
  final double? bearingAccuracyDeg;
  @override
  final String? provider;
  @override
  final bool? isMocked;
  @override
  final String? qualityClass;
  @override
  final double? qualityScore;
  @override
  final String? qualityReason;
  @override
  final double? filteredLatitude;
  @override
  final double? filteredLongitude;
  @override
  final double? filteredAltitudeM;
  @override
  final double? fusedSpeedMps;
  @override
  final double? derivedSpeedMps;
  @override
  final double? distanceDeltaM;
  @override
  final String? motionState;
}

enum SessionActivityType {
  descent,
  lift,
  idle,
}

extension SessionActivityTypePresentation on SessionActivityType {
  String get label {
    switch (this) {
      case SessionActivityType.descent:
        return 'Descent';
      case SessionActivityType.lift:
        return 'Lift';
      case SessionActivityType.idle:
        return 'Idle';
    }
  }
}

class SessionTimelineSegment {
  const SessionTimelineSegment({
    required this.type,
    required this.startedAt,
    required this.endedAt,
    required this.startOffsetMs,
    required this.endOffsetMs,
    required this.durationS,
    required this.distanceM,
    required this.points,
  });

  final SessionActivityType type;
  final DateTime startedAt;
  final DateTime endedAt;
  final int startOffsetMs;
  final int endOffsetMs;
  final int durationS;
  final double distanceM;
  final List<LocalSessionPoint> points;
}

class SessionStats {
  const SessionStats({
    required this.durationS,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.elevationGainM,
    required this.elevationLossM,
    this.descentDurationS = 0,
    this.liftDurationS = 0,
    this.idleDurationS = 0,
    this.descentDistanceM = 0,
    this.liftDistanceM = 0,
    this.idleDistanceM = 0,
  });

  final int durationS;
  final double distanceM;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final int? elevationGainM;
  final int? elevationLossM;
  final int descentDurationS;
  final int liftDurationS;
  final int idleDurationS;
  final double descentDistanceM;
  final double liftDistanceM;
  final double idleDistanceM;

  double get rideAvgSpeedMps =>
      descentDurationS == 0 ? 0 : descentDistanceM / descentDurationS;

  static const SessionStats zero = SessionStats(
    durationS: 0,
    distanceM: 0,
    maxSpeedMps: 0,
    avgSpeedMps: 0,
    elevationGainM: null,
    elevationLossM: null,
    descentDurationS: 0,
    liftDurationS: 0,
    idleDurationS: 0,
    descentDistanceM: 0,
    liftDistanceM: 0,
    idleDistanceM: 0,
  );
}

double haversineDistanceMeters(
  double startLat,
  double startLng,
  double endLat,
  double endLng,
) {
  const double earthRadiusMeters = 6371000;

  final dLat = _toRadians(endLat - startLat);
  final dLng = _toRadians(endLng - startLng);
  final radStartLat = _toRadians(startLat);
  final radEndLat = _toRadians(endLat);

  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(radStartLat) *
          math.cos(radEndLat) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}

double _toRadians(double degrees) => degrees * (math.pi / 180);
