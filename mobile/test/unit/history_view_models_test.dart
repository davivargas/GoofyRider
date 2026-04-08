import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/presentation/history_view_models.dart';

LocalRideSession _buildSession(DateTime startedAt) {
  return LocalRideSession(
    localId: startedAt.millisecondsSinceEpoch,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: null,
    startedAt: startedAt,
    endedAt: startedAt,
    activeDurationS: 60,
    distanceM: 100,
    maxSpeedMps: 5,
    avgSpeedMps: 4,
    elevationGainM: null,
    elevationLossM: null,
    state: LocalSessionState.synced,
    pointCount: 0,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: startedAt,
    updatedAt: startedAt,
  );
}

void main() {
  test('seasonLabelForDate uses July boundary', () {
    expect(seasonLabelForDate(DateTime(2025, 4, 23)), '2024/2025');
    expect(seasonLabelForDate(DateTime(2025, 7, 1)), '2025/2026');
    expect(seasonLabelForDate(DateTime(2025, 9, 1)), '2025/2026');
  });

  test('buildSessionHistorySections groups sessions by season', () {
    final List<SessionHistorySeasonSection> sections = buildSessionHistorySections(
      <SessionHistoryEntryViewModel>[
        SessionHistoryEntryViewModel(
          session: _buildSession(DateTime(2025, 9, 1)),
          resortLabel: 'Resort A',
        ),
        SessionHistoryEntryViewModel(
          session: _buildSession(DateTime(2025, 4, 23)),
          resortLabel: 'Resort B',
        ),
      ],
    );

    expect(sections.map((SessionHistorySeasonSection section) => section.label), <String>[
      '2025/2026',
      '2024/2025',
    ]);
  });
}
