import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/presentation/season_summary.dart';

LocalRideSession _s({
  required int id,
  required DateTime startedAt,
  int? vert = 100,
  double maxMps = 10,
  double distanceM = 1000,
  int activeS = 600,
}) {
  return LocalRideSession(
    localId: id,
    ownerUserId: 'u',
    remoteId: null,
    resortId: 'r',
    startedAt: startedAt,
    endedAt: startedAt,
    activeDurationS: activeS,
    distanceM: distanceM,
    maxSpeedMps: maxMps,
    avgSpeedMps: 5,
    elevationGainM: 0,
    elevationLossM: vert,
    state: LocalSessionState.synced,
    pointCount: 1,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: startedAt,
    updatedAt: startedAt,
  );
}

void main() {
  test('aggregates only sessions in the current season', () {
    final now = DateTime(2027, 1, 15);
    final summary = buildSeasonSummary(<LocalRideSession>[
      _s(id: 1, startedAt: DateTime(2026, 12, 20, 9), vert: 300, maxMps: 12),
      _s(id: 2, startedAt: DateTime(2026, 12, 20, 14), vert: 200, maxMps: 15),
      _s(id: 3, startedAt: DateTime(2027, 1, 3), vert: null, maxMps: 8),
      _s(id: 4, startedAt: DateTime(2026, 3, 1), vert: 999, maxMps: 40),
    ], now: now);

    expect(summary.label, '2026/2027');
    expect(summary.sessionCount, 3);
    expect(summary.daysRidden, 2);
    expect(summary.totalVertM, 500);
    expect(summary.topSpeedMps, 15);
    expect(summary.totalDistanceM, 3000);
    expect(summary.rideTimeS, 1800);
  });

  test('empty history gives zeros', () {
    final summary = buildSeasonSummary(const <LocalRideSession>[], now: DateTime(2026, 9, 10));
    expect(summary.sessionCount, 0);
    expect(summary.daysRidden, 0);
    expect(summary.totalVertM, 0);
  });

  test('shortSeasonLabel trims centuries', () {
    expect(shortSeasonLabel('2026/2027'), '26/27');
  });
}
