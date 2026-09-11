import 'dart:math' as math;

import '../domain/session_models.dart';
import 'history_view_models.dart';

/// Aggregated numbers for the season that contains [now].
class SeasonSummary {
  const SeasonSummary({
    required this.label,
    required this.daysRidden,
    required this.sessionCount,
    required this.totalVertM,
    required this.topSpeedMps,
    required this.totalDistanceM,
    required this.rideTimeS,
  });

  final String label;
  final int daysRidden;
  final int sessionCount;
  final double totalVertM;
  final double topSpeedMps;
  final double totalDistanceM;
  final int rideTimeS;
}

SeasonSummary buildSeasonSummary(
  List<LocalRideSession> sessions, {
  required DateTime now,
}) {
  final label = seasonLabelForDate(now);
  final days = <String>{};
  var count = 0;
  var vert = 0.0;
  var top = 0.0;
  var distance = 0.0;
  var rideTime = 0;
  for (final session in sessions) {
    if (seasonLabelForDate(session.startedAt) != label) {
      continue;
    }
    final local = session.startedAt.toLocal();
    days.add('${local.year}-${local.month}-${local.day}');
    count += 1;
    vert += (session.elevationLossM ?? 0).toDouble();
    top = math.max(top, session.maxSpeedMps);
    distance += session.distanceM;
    rideTime += session.activeDurationS;
  }
  return SeasonSummary(
    label: label,
    daysRidden: days.length,
    sessionCount: count,
    totalVertM: vert,
    topSpeedMps: top,
    totalDistanceM: distance,
    rideTimeS: rideTime,
  );
}

/// `2026/2027` -> `26/27`.
String shortSeasonLabel(String label) {
  final parts = label.split('/');
  if (parts.length != 2) {
    return label;
  }
  String tail(String s) => s.length > 2 ? s.substring(s.length - 2) : s;
  return '${tail(parts[0])}/${tail(parts[1])}';
}
