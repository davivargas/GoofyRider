import 'package:latlong2/latlong.dart';

import '../domain/location_tracking_repository.dart';
import '../domain/session_models.dart';

enum RecordScreenPhase {
  preRecord,
  requestingPermissions,
  ready,
  recording,
  paused,
  finishing,
  syncPending,
}

class GpsSignalState {
  const GpsSignalState({
    required this.bars,
    required this.description,
  });

  const GpsSignalState.initial()
      : bars = 0,
        description = 'Searching';

  final int bars;
  final String description;
}

class PermissionViewState {
  const PermissionViewState({
    required this.permissionState,
    this.errorMessage,
  });

  const PermissionViewState.initial()
      : permissionState = LocationPermissionState.denied,
        errorMessage = null;

  final LocationPermissionState permissionState;
  final String? errorMessage;

  bool get hasLocationPermission =>
      permissionState == LocationPermissionState.granted ||
      permissionState == LocationPermissionState.grantedForegroundOnly;

  bool get hasConfirmedBackgroundTracking =>
      permissionState == LocationPermissionState.granted;

  bool get needsAlwaysOnPermission =>
      permissionState == LocationPermissionState.grantedForegroundOnly;

  PermissionViewState copyWith({
    LocationPermissionState? permissionState,
    String? errorMessage,
    bool clearError = false,
  }) {
    return PermissionViewState(
      permissionState: permissionState ?? this.permissionState,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class TrackingViewState {
  const TrackingViewState({
    required this.liveStats,
    required this.route,
    required this.currentSpeedMps,
    this.currentAltitudeM,
    required this.maxSpeedMps,
    required this.elapsed,
    required this.lowAccuracy,
    required this.gpsSignal,
    this.lastSampleAtUtc,
    this.lastPersistedPointAtUtc,
  });

  const TrackingViewState.initial()
      : liveStats = SessionStats.zero,
        route = const <LatLng>[],
        currentSpeedMps = 0,
        currentAltitudeM = null,
        maxSpeedMps = 0,
        elapsed = Duration.zero,
        lowAccuracy = false,
        gpsSignal = const GpsSignalState.initial(),
        lastSampleAtUtc = null,
        lastPersistedPointAtUtc = null;

  final SessionStats liveStats;
  final List<LatLng> route;
  final double currentSpeedMps;
  final double? currentAltitudeM;
  final double maxSpeedMps;
  final Duration elapsed;
  final bool lowAccuracy;
  final GpsSignalState gpsSignal;
  final DateTime? lastSampleAtUtc;
  final DateTime? lastPersistedPointAtUtc;

  TrackingViewState copyWith({
    SessionStats? liveStats,
    List<LatLng>? route,
    double? currentSpeedMps,
    double? currentAltitudeM,
    bool clearCurrentAltitudeM = false,
    double? maxSpeedMps,
    Duration? elapsed,
    bool? lowAccuracy,
    GpsSignalState? gpsSignal,
    DateTime? lastSampleAtUtc,
    bool clearLastSampleAtUtc = false,
    DateTime? lastPersistedPointAtUtc,
    bool clearLastPersistedPointAtUtc = false,
  }) {
    return TrackingViewState(
      liveStats: liveStats ?? this.liveStats,
      route: route ?? this.route,
      currentSpeedMps: currentSpeedMps ?? this.currentSpeedMps,
      currentAltitudeM: clearCurrentAltitudeM
          ? null
          : (currentAltitudeM ?? this.currentAltitudeM),
      maxSpeedMps: maxSpeedMps ?? this.maxSpeedMps,
      elapsed: elapsed ?? this.elapsed,
      lowAccuracy: lowAccuracy ?? this.lowAccuracy,
      gpsSignal: gpsSignal ?? this.gpsSignal,
      lastSampleAtUtc: clearLastSampleAtUtc
          ? null
          : (lastSampleAtUtc ?? this.lastSampleAtUtc),
      lastPersistedPointAtUtc: clearLastPersistedPointAtUtc
          ? null
          : (lastPersistedPointAtUtc ?? this.lastPersistedPointAtUtc),
    );
  }
}

class SyncViewState {
  const SyncViewState({
    this.lastSyncMessage,
    required this.historyRevision,
  });

  const SyncViewState.initial()
      : lastSyncMessage = null,
        historyRevision = 0;

  final String? lastSyncMessage;
  final int historyRevision;

  SyncViewState copyWith({
    String? lastSyncMessage,
    bool clearSyncMessage = false,
    int? historyRevision,
  }) {
    return SyncViewState(
      lastSyncMessage:
          clearSyncMessage ? null : (lastSyncMessage ?? this.lastSyncMessage),
      historyRevision: historyRevision ?? this.historyRevision,
    );
  }
}

class RecordingViewState {
  const RecordingViewState({
    required this.phase,
    required this.permission,
    required this.tracking,
    required this.sync,
    this.session,
    this.recoveryCandidate,
    this.preselectedResortId,
    required this.streamRestartCount,
  });

  factory RecordingViewState.initial() => const RecordingViewState(
        phase: RecordScreenPhase.preRecord,
        permission: PermissionViewState.initial(),
        tracking: TrackingViewState.initial(),
        sync: SyncViewState.initial(),
        streamRestartCount: 0,
      );

  final RecordScreenPhase phase;
  final PermissionViewState permission;
  final TrackingViewState tracking;
  final SyncViewState sync;
  final LocalRideSession? session;
  final LocalRideSession? recoveryCandidate;
  final String? preselectedResortId;
  final int streamRestartCount;

  bool get canStart =>
      permission.hasConfirmedBackgroundTracking &&
      phase != RecordScreenPhase.requestingPermissions &&
      phase != RecordScreenPhase.recording &&
      phase != RecordScreenPhase.paused &&
      phase != RecordScreenPhase.finishing;

  bool get hasRecovery => recoveryCandidate != null;

  RecordingViewState copyWith({
    RecordScreenPhase? phase,
    PermissionViewState? permission,
    TrackingViewState? tracking,
    SyncViewState? sync,
    LocalRideSession? session,
    bool clearSession = false,
    LocalRideSession? recoveryCandidate,
    bool clearRecovery = false,
    String? preselectedResortId,
    int? streamRestartCount,
  }) {
    return RecordingViewState(
      phase: phase ?? this.phase,
      permission: permission ?? this.permission,
      tracking: tracking ?? this.tracking,
      sync: sync ?? this.sync,
      session: clearSession ? null : (session ?? this.session),
      recoveryCandidate:
          clearRecovery ? null : (recoveryCandidate ?? this.recoveryCandidate),
      preselectedResortId: preselectedResortId ?? this.preselectedResortId,
      streamRestartCount: streamRestartCount ?? this.streamRestartCount,
    );
  }
}
