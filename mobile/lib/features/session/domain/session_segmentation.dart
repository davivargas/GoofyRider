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
    this.reclassifiedIdleDurationS = 0,
  });

  final List<SessionTimelineSegment> segments;
  final double distanceM;
  final int descentDurationS;
  final int liftDurationS;
  final int idleDurationS;
  final double descentDistanceM;
  final double liftDistanceM;
  final double idleDistanceM;

  /// Duration (in seconds) of idle segments that were reclassified as descent
  /// by the Layer-2 post-finish pass. Zero when no reclassification fired.
  final int reclassifiedIdleDurationS;
}

/// Layer-2 reclassification rules (§4.3 of the GPS overhaul plan).
class _IdleReclassificationRules {
  static const int maxDurationMs = 8 * 60 * 1000; // 8 min
  static const double maxDriftMeters = 30;
  static const double maxElevationDeltaMeters = 20;
  static const int maxInternalGapMs = 60 * 1000; // 60 s
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
///
/// [applyIdleReclassification] toggles the Layer-2 post-finish pass that flips
/// mid-run idle segments (bracketed by descent on both sides and matching the
/// on-slope-stop criteria) into descent. Defaults to true for production use;
/// the stats-replay parity tests pass false to verify the Layer-1 agreement
/// surface with the live accumulator.
SessionTimelineAnalysis analyzeSessionTimeline({
  required List<LocalSessionPoint> points,
  int? localSessionId,
  bool applyIdleReclassification = true,
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

  final builders = <_SegmentBuilder>[];
  _SegmentBuilder? currentBuilder;

  for (var index = 1; index < accepted.length; index++) {
    final previous = accepted[index - 1];
    final current = accepted[index];
    final deltaMilliseconds =
        current.recordedAt.difference(previous.recordedAt).inMilliseconds;

    if (deltaMilliseconds <= 0 || deltaMilliseconds > maxDeltaMilliseconds) {
      if (currentBuilder != null) {
        builders.add(currentBuilder);
        currentBuilder = null;
      }
      continue;
    }

    final activity = activities[index];
    final intervalDistanceM =
        _intervalDistanceMeters(previous: previous, current: current);

    if (currentBuilder == null || currentBuilder.type != activity) {
      if (currentBuilder != null) {
        builders.add(currentBuilder);
      }
      currentBuilder = _SegmentBuilder.start(
        type: activity,
        previous: previous,
        current: current,
        durationMs: deltaMilliseconds,
        distanceM: intervalDistanceM,
      );
      continue;
    }

    currentBuilder.add(
      point: current,
      durationMs: deltaMilliseconds,
      distanceM: intervalDistanceM,
    );
  }

  if (currentBuilder != null) {
    builders.add(currentBuilder);
  }

  // Layer-2 post-finish reclassification: idle segments bracketed by descent
  // on both sides get flipped to descent when they look like an on-slope stop.
  final reclassifiedIdleDurationMs = applyIdleReclassification
      ? _mergeMidRunIdleIntoDescent(builders)
      : 0;
  final mergedBuilders = applyIdleReclassification
      ? _mergeAdjacentContiguousSameType(builders)
      : builders;

  final durationByTypeMs = <SessionActivityType, int>{
    SessionActivityType.descent: 0,
    SessionActivityType.lift: 0,
    SessionActivityType.idle: 0,
  };
  final distanceByTypeM = <SessionActivityType, double>{
    SessionActivityType.descent: 0,
    SessionActivityType.lift: 0,
    SessionActivityType.idle: 0,
  };
  for (final builder in mergedBuilders) {
    durationByTypeMs[builder.type] =
        durationByTypeMs[builder.type]! + builder.durationMs;
    distanceByTypeM[builder.type] =
        distanceByTypeM[builder.type]! + builder.distanceM;
  }

  final segments = <SessionTimelineSegment>[
    for (final builder in mergedBuilders) builder.build(),
  ];

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
    reclassifiedIdleDurationS:
        _millisecondsToSeconds(reclassifiedIdleDurationMs),
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
  final fallRuleState = _FallRuleState();
  for (final point in points) {
    resolved.add(
      fallRuleState.activityFor(
        motionState: point.motionState,
        sampleTimeUtc: point.recordedAt.toUtc(),
        latitude: point.filteredLatitude ?? point.latitude,
        longitude: point.filteredLongitude ?? point.longitude,
      ),
    );
  }
  return resolved;
}

/// Layer-1 fall-rule state walker — mirrors
/// [MotionStateDetector.activityTypeForMotionState] for replay/segmentation so
/// the finished-session per-bucket totals match the live accumulator.
class _FallRuleState {
  SessionActivityType? _lastStableActivityType;
  DateTime? _stoppedSinceUtc;
  double? _stopAnchorLatitude;
  double? _stopAnchorLongitude;
  double _stopMaxDriftM = 0;

  SessionActivityType activityFor({
    required String? motionState,
    required DateTime sampleTimeUtc,
    required double latitude,
    required double longitude,
  }) {
    switch (motionState) {
      case 'active_descent':
        _lastStableActivityType = SessionActivityType.descent;
        _clearStop();
        return SessionActivityType.descent;
      case 'lift_uphill':
        _lastStableActivityType = SessionActivityType.lift;
        _clearStop();
        return SessionActivityType.lift;
      case 'stopped_idle':
        return _stoppedIdleBucket(
          sampleTimeUtc: sampleTimeUtc,
          latitude: latitude,
          longitude: longitude,
        );
      case 'low_confidence_recovery':
      case 'initializing_fix':
      default:
        return _lastStableActivityType ?? SessionActivityType.idle;
    }
  }

  SessionActivityType _stoppedIdleBucket({
    required DateTime sampleTimeUtc,
    required double latitude,
    required double longitude,
  }) {
    if (_stoppedSinceUtc == null ||
        _stopAnchorLatitude == null ||
        _stopAnchorLongitude == null) {
      _stoppedSinceUtc = sampleTimeUtc;
      _stopAnchorLatitude = latitude;
      _stopAnchorLongitude = longitude;
      _stopMaxDriftM = 0;
    } else {
      final drift = haversineDistanceMeters(
        _stopAnchorLatitude!,
        _stopAnchorLongitude!,
        latitude,
        longitude,
      );
      if (drift > _stopMaxDriftM) {
        _stopMaxDriftM = drift;
      }
    }

    if (_lastStableActivityType != SessionActivityType.descent) {
      return SessionActivityType.idle;
    }
    final stopDurationS =
        sampleTimeUtc.difference(_stoppedSinceUtc!).inSeconds;
    if (stopDurationS >= SessionConstants.fallMaxStopDurationSeconds) {
      return SessionActivityType.idle;
    }
    if (_stopMaxDriftM >= SessionConstants.fallMaxDriftMeters) {
      return SessionActivityType.idle;
    }
    return SessionActivityType.descent;
  }

  void _clearStop() {
    _stoppedSinceUtc = null;
    _stopAnchorLatitude = null;
    _stopAnchorLongitude = null;
    _stopMaxDriftM = 0;
  }
}

List<SessionActivityType> _replayedActivityTypes(
    List<LocalSessionPoint> points) {
  final engine = TrackingPipelineEngine();
  final sessionStartedAtUtc = points.first.recordedAt.toUtc();
  final resolved = <SessionActivityType>[];
  final fallRuleState = _FallRuleState();
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
      fallRuleState.activityFor(
        motionState: replayed.point.motionState,
        sampleTimeUtc: pointTimeUtc,
        latitude: replayed.point.filteredLatitude ?? replayed.point.latitude,
        longitude: replayed.point.filteredLongitude ?? replayed.point.longitude,
      ),
    );
    previousAcceptedAtUtc = pointTimeUtc;
  }

  return resolved;
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

/// Layer-2 idle → descent reclassification (§4.3 of the GPS overhaul plan).
///
/// Walks the (pre-merge) segment list and flips an idle segment's type to
/// descent when it is bracketed by descent on both sides and the whole segment
/// looks like an on-slope stop: short duration, tight drift radius, small
/// elevation delta, and no internal GPS gap. Returns the total idle duration
/// (in milliseconds) that was reclassified, so the caller can surface a
/// "recovered N of descent" hint.
int _mergeMidRunIdleIntoDescent(List<_SegmentBuilder> segments) {
  if (segments.length < 3) return 0;

  var reclassifiedMs = 0;
  for (var i = 1; i < segments.length - 1; i++) {
    final previous = segments[i - 1];
    final current = segments[i];
    final next = segments[i + 1];

    if (current.type != SessionActivityType.idle) continue;
    if (previous.type != SessionActivityType.descent) continue;
    if (next.type != SessionActivityType.descent) continue;
    if (!_isOnSlopeStop(current)) continue;

    reclassifiedMs += current.durationMs;
    current.type = SessionActivityType.descent;
  }
  return reclassifiedMs;
}

bool _isOnSlopeStop(_SegmentBuilder segment) {
  if (segment.durationMs > _IdleReclassificationRules.maxDurationMs) {
    return false;
  }

  final points = segment._points;
  if (points.length < 2) return false;

  final firstAltitude =
      points.first.filteredAltitudeM ?? points.first.altitudeM;
  final lastAltitude = points.last.filteredAltitudeM ?? points.last.altitudeM;
  if (firstAltitude != null && lastAltitude != null) {
    if ((lastAltitude - firstAltitude).abs() >=
        _IdleReclassificationRules.maxElevationDeltaMeters) {
      return false;
    }
  }

  for (var i = 1; i < points.length; i++) {
    final gapMs = points[i]
        .recordedAt
        .difference(points[i - 1].recordedAt)
        .inMilliseconds;
    if (gapMs > _IdleReclassificationRules.maxInternalGapMs) {
      return false;
    }
  }

  double sumLatitude = 0;
  double sumLongitude = 0;
  for (final point in points) {
    sumLatitude += point.filteredLatitude ?? point.latitude;
    sumLongitude += point.filteredLongitude ?? point.longitude;
  }
  final centroidLatitude = sumLatitude / points.length;
  final centroidLongitude = sumLongitude / points.length;

  for (final point in points) {
    final drift = haversineDistanceMeters(
      centroidLatitude,
      centroidLongitude,
      point.filteredLatitude ?? point.latitude,
      point.filteredLongitude ?? point.longitude,
    );
    if (drift > _IdleReclassificationRules.maxDriftMeters) {
      return false;
    }
  }

  return true;
}

/// Merge adjacent segments that share the same activity type AND touch at the
/// same boundary point (no GPS gap between them). The temporal-contiguity
/// check keeps gap-separated runs visible as distinct segments in the UI.
List<_SegmentBuilder> _mergeAdjacentContiguousSameType(
  List<_SegmentBuilder> segments,
) {
  if (segments.length < 2) return segments;
  final merged = <_SegmentBuilder>[segments.first];
  for (var i = 1; i < segments.length; i++) {
    final previous = merged.last;
    final current = segments[i];
    if (previous.type == current.type &&
        previous.endedAt == current.startedAt) {
      previous.mergeFrom(current);
    } else {
      merged.add(current);
    }
  }
  return merged;
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

  SessionActivityType type;
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

  /// Merge [other] into this builder. Caller must ensure [other] is the next
  /// temporally-contiguous segment (its startedAt equals this endedAt) and
  /// both segments share the same activity type.
  void mergeFrom(_SegmentBuilder other) {
    if (_points.isNotEmpty &&
        other._points.isNotEmpty &&
        identical(_points.last, other._points.first)) {
      _points.addAll(other._points.skip(1));
    } else {
      _points.addAll(other._points);
    }
    durationMs += other.durationMs;
    distanceM += other.distanceM;
    endedAt = other.endedAt;
    endOffsetMs = other.endOffsetMs;
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
