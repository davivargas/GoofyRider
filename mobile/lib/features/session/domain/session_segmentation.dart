import '../../../core/constants/session_constants.dart';
import 'location_tracking_repository.dart';
import 'session_models.dart';
import 'tracking_pipeline.dart';

/// LRU-style in-memory cache for [SessionTimelineAnalysis] results.
///
/// Keyed by `(localSessionId, pointCount)` so repeated views of the same
/// session skip the expensive [TrackingPipelineEngine] replay.
class _TimelineAnalysisCache {
  static const int _maxEntries = 5;

  final Map<String, SessionTimelineAnalysis> _cache = {};
  final List<String> _keys = [];

  String _key(int localSessionId, int pointCount) =>
      '$localSessionId:$pointCount';

  SessionTimelineAnalysis? get(int localSessionId, int pointCount) {
    return _cache[_key(localSessionId, pointCount)];
  }

  void put(int localSessionId, int pointCount, SessionTimelineAnalysis analysis) {
    final key = _key(localSessionId, pointCount);
    if (_cache.containsKey(key)) return;
    if (_keys.length >= _maxEntries) {
      final evicted = _keys.removeAt(0);
      _cache.remove(evicted);
    }
    _keys.add(key);
    _cache[key] = analysis;
  }
}

final _timelineCache = _TimelineAnalysisCache();

class SessionTimelineAnalysis {
  const SessionTimelineAnalysis({
    required this.segments,
    required this.distanceM,
    required this.descentDurationS,
    required this.liftDurationS,
    required this.idleDurationS,
    required this.descentDistanceM,
    required this.liftDistanceM,
    required this.idleDistanceM,
  });

  final List<SessionTimelineSegment> segments;
  final double distanceM;
  final int descentDurationS;
  final int liftDurationS;
  final int idleDurationS;
  final double descentDistanceM;
  final double liftDistanceM;
  final double idleDistanceM;
}

/// Rebuilds user-facing timeline segments from accepted analytics points.
///
/// When a stored `distanceDeltaM` is present, it is treated as authoritative,
/// including explicit zeroes from the pipeline. That keeps stationary accepted
/// intervals from being re-inflated by a fallback haversine recomputation.
///
/// When [localSessionId] is provided, results are cached in an LRU cache keyed
/// by `(localSessionId, points.length)` so repeated views of the same session
/// avoid re-replaying the tracking pipeline.
SessionTimelineAnalysis analyzeSessionTimeline({
  required List<LocalSessionPoint> points,
  int? localSessionId,
}) {
  if (localSessionId != null) {
    final cached = _timelineCache.get(localSessionId, points.length);
    if (cached != null) return cached;
  }

  final accepted = points
      .where((LocalSessionPoint point) => point.acceptedForAnalytics)
      .toList(growable: false)
    ..sort(
      (LocalSessionPoint a, LocalSessionPoint b) =>
          a.recordedAt.compareTo(b.recordedAt),
    );

  if (accepted.length < 2) {
    return const SessionTimelineAnalysis(
      segments: <SessionTimelineSegment>[],
      distanceM: 0,
      descentDurationS: 0,
      liftDurationS: 0,
      idleDurationS: 0,
      descentDistanceM: 0,
      liftDistanceM: 0,
      idleDistanceM: 0,
    );
  }

  final activities = _resolvedActivityTypes(accepted);
  final maxDeltaMilliseconds = SessionConstants.maxDeltaSeconds * 1000;

  final durationByTypeMs =
      <SessionActivityType, int>{
    SessionActivityType.descent: 0,
    SessionActivityType.lift: 0,
    SessionActivityType.idle: 0,
  };
  final distanceByTypeM =
      <SessionActivityType, double>{
    SessionActivityType.descent: 0,
    SessionActivityType.lift: 0,
    SessionActivityType.idle: 0,
  };

  final segments = <SessionTimelineSegment>[];
  _SegmentBuilder? currentSegment;

  for (var index = 1; index < accepted.length; index++) {
    final previous = accepted[index - 1];
    final current = accepted[index];
    final deltaMilliseconds =
        current.recordedAt.difference(previous.recordedAt).inMilliseconds;

    if (deltaMilliseconds <= 0 || deltaMilliseconds > maxDeltaMilliseconds) {
      if (currentSegment != null) {
        segments.add(currentSegment.build());
        currentSegment = null;
      }
      continue;
    }

    final activity = activities[index];
    final intervalDistanceM =
        _intervalDistanceMeters(previous: previous, current: current);
    durationByTypeMs[activity] =
        durationByTypeMs[activity]! + deltaMilliseconds;
    distanceByTypeM[activity] = distanceByTypeM[activity]! + intervalDistanceM;

    if (currentSegment == null || currentSegment.type != activity) {
      if (currentSegment != null) {
        segments.add(currentSegment.build());
      }
      currentSegment = _SegmentBuilder.start(
        type: activity,
        previous: previous,
        current: current,
        durationMs: deltaMilliseconds,
        distanceM: intervalDistanceM,
      );
      continue;
    }

    currentSegment.add(
      point: current,
      durationMs: deltaMilliseconds,
      distanceM: intervalDistanceM,
    );
  }

  if (currentSegment != null) {
    segments.add(currentSegment.build());
  }

  final result = SessionTimelineAnalysis(
    segments: segments,
    distanceM: distanceByTypeM.values.fold<double>(
      0,
      (double total, double value) => total + value,
    ),
    descentDurationS: _millisecondsToSeconds(
      durationByTypeMs[SessionActivityType.descent]!,
    ),
    liftDurationS: _millisecondsToSeconds(
      durationByTypeMs[SessionActivityType.lift]!,
    ),
    idleDurationS: _millisecondsToSeconds(
      durationByTypeMs[SessionActivityType.idle]!,
    ),
    descentDistanceM: distanceByTypeM[SessionActivityType.descent]!,
    liftDistanceM: distanceByTypeM[SessionActivityType.lift]!,
    idleDistanceM: distanceByTypeM[SessionActivityType.idle]!,
  );

  if (localSessionId != null) {
    _timelineCache.put(localSessionId, points.length, result);
  }

  return result;
}

List<SessionActivityType> _resolvedActivityTypes(
    List<LocalSessionPoint> points) {
  final hasStoredMotionStates = points.every(
    (LocalSessionPoint point) =>
        point.motionState != null && point.motionState!.isNotEmpty,
  );

  if (!hasStoredMotionStates) {
    return _replayedActivityTypes(points);
  }

  final resolved = <SessionActivityType>[];
  SessionActivityType? lastStableActivity;
  for (final point in points) {
    final activity = _activityFromMotionState(
      point.motionState,
      lastStableActivity: lastStableActivity,
    );
    resolved.add(activity);
    if (_isStableMotionState(point.motionState)) {
      lastStableActivity = activity;
    }
  }
  return resolved;
}

List<SessionActivityType> _replayedActivityTypes(
    List<LocalSessionPoint> points) {
  final engine = TrackingPipelineEngine();
  final sessionStartedAtUtc = points.first.recordedAt.toUtc();
  final resolved = <SessionActivityType>[];
  var cumulativeAcceptedMilliseconds = 0;
  DateTime? previousAcceptedAtUtc;

  for (final point in points) {
    final pointTimeUtc = point.recordedAt.toUtc();
    if (previousAcceptedAtUtc != null) {
      final deltaMilliseconds =
          pointTimeUtc.difference(previousAcceptedAtUtc).inMilliseconds;
      if (deltaMilliseconds > 0 &&
          deltaMilliseconds <= SessionConstants.maxDeltaSeconds * 1000) {
        cumulativeAcceptedMilliseconds += deltaMilliseconds;
      }
    }

    final replayed = engine.processSample(
      sample: LocationSample(
        timestamp: pointTimeUtc,
        latitude: point.latitude,
        longitude: point.longitude,
        accuracyM: point.accuracyM,
        altitudeM: point.altitudeM,
        speedMps: point.speedMps,
        headingDeg: point.headingDeg,
        elapsedRealtimeNs: point.elapsedRealtimeNs,
        verticalAccuracyM: point.verticalAccuracyM,
        speedAccuracyMps: point.speedAccuracyMps,
        bearingAccuracyDeg: point.bearingAccuracyDeg,
        provider: point.provider,
        isMocked: point.isMocked,
      ),
      sessionStartedAtUtc: sessionStartedAtUtc,
      activeDurationS: _millisecondsToSeconds(cumulativeAcceptedMilliseconds),
    );
    resolved.add(
      _activityFromMotionState(replayed.point.motionState),
    );
    previousAcceptedAtUtc = pointTimeUtc;
  }

  return resolved;
}

SessionActivityType _activityFromMotionState(
  String? motionState, {
  SessionActivityType? lastStableActivity,
}) {
  switch (motionState) {
    case 'active_descent':
      return SessionActivityType.descent;
    case 'lift_uphill':
      return SessionActivityType.lift;
    case 'stopped_idle':
      return SessionActivityType.idle;
    case 'low_confidence_recovery':
    case 'initializing_fix':
    default:
      return lastStableActivity ?? SessionActivityType.idle;
  }
}

bool _isStableMotionState(String? motionState) {
  return motionState == 'active_descent' ||
      motionState == 'lift_uphill' ||
      motionState == 'stopped_idle';
}

/// Uses the persisted distance delta when available so replayed segmentation
/// matches the pipeline's accepted movement, including zero-distance intervals.
double _intervalDistanceMeters({
  required LocalSessionPoint previous,
  required LocalSessionPoint current,
}) {
  if (current.distanceDeltaM != null) {
    return current.distanceDeltaM! > 0 ? current.distanceDeltaM! : 0;
  }

  final startLat = previous.filteredLatitude ?? previous.latitude;
  final startLng = previous.filteredLongitude ?? previous.longitude;
  final endLat = current.filteredLatitude ?? current.latitude;
  final endLng = current.filteredLongitude ?? current.longitude;
  return haversineDistanceMeters(startLat, startLng, endLat, endLng);
}

int _millisecondsToSeconds(int milliseconds) {
  return (milliseconds / 1000).round();
}

class _SegmentBuilder {
  _SegmentBuilder._({
    required this.type,
    required this.startedAt,
    required this.startOffsetMs,
    required List<LocalSessionPoint> points,
    required this.durationMs,
    required this.distanceM,
    required this.endedAt,
    required this.endOffsetMs,
  }) : _points = points;

  factory _SegmentBuilder.start({
    required SessionActivityType type,
    required LocalSessionPoint previous,
    required LocalSessionPoint current,
    required int durationMs,
    required double distanceM,
  }) {
    return _SegmentBuilder._(
      type: type,
      startedAt: previous.recordedAt,
      startOffsetMs: previous.elapsedOffsetMs,
      points: <LocalSessionPoint>[previous, current],
      durationMs: durationMs,
      distanceM: distanceM,
      endedAt: current.recordedAt,
      endOffsetMs: current.elapsedOffsetMs,
    );
  }

  final SessionActivityType type;
  final DateTime startedAt;
  final int startOffsetMs;
  final List<LocalSessionPoint> _points;
  int durationMs;
  double distanceM;
  DateTime endedAt;
  int endOffsetMs;

  void add({
    required LocalSessionPoint point,
    required int durationMs,
    required double distanceM,
  }) {
    _points.add(point);
    this.durationMs += durationMs;
    this.distanceM += distanceM;
    endedAt = point.recordedAt;
    endOffsetMs = point.elapsedOffsetMs;
  }

  SessionTimelineSegment build() {
    return SessionTimelineSegment(
      type: type,
      startedAt: startedAt,
      endedAt: endedAt,
      startOffsetMs: startOffsetMs,
      endOffsetMs: endOffsetMs,
      durationS: _millisecondsToSeconds(durationMs),
      distanceM: distanceM,
      points: List<LocalSessionPoint>.unmodifiable(_points),
    );
  }
}
