import 'package:fall_line_mobile/core/utils/duration_formatting.dart';
import 'package:fall_line_mobile/core/utils/speed_unit.dart';
import 'package:fall_line_mobile/core/widgets/design_widgets.dart';
import 'package:fall_line_mobile/features/session/domain/session_models.dart';
import 'package:flutter_test/flutter_test.dart';

LocalRideSession _session(
    {int activeDurationS = 15120, double maxMps = 16.14}) {
  final now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: 1,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: 'resort-1',
    startedAt: now,
    endedAt: now,
    activeDurationS: activeDurationS,
    distanceM: 1000,
    maxSpeedMps: maxMps,
    avgSpeedMps: 8,
    elevationGainM: 0,
    elevationLossM: 0,
    state: LocalSessionState.synced,
    pointCount: 1,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('formatSecondsAsHoursMinutes', () {
    test('renders hours:minutes with zero padding', () {
      expect(formatSecondsAsHoursMinutes(15120), '04:12');
      expect(formatSecondsAsHoursMinutes(540), '00:09');
    });

    test('clamps negative input to zero', () {
      expect(formatSecondsAsHoursMinutes(-5), '00:00');
    });
  });

  group('formatSecondsCompact', () {
    test('renders minutes:seconds under an hour', () {
      expect(formatSecondsCompact(139), '02:19');
    });

    test('adds the hour once past 60 minutes', () {
      expect(formatSecondsCompact(3725), '1:02:05');
    });
  });

  group('sessionDataLine', () {
    test('joins run count, ride time and top speed', () {
      expect(
        sessionDataLine(_session(), SpeedUnit.kilometersPerHour, runs: 14),
        '14 runs · 04:12 · MAX 58.1 km/h',
      );
    });

    test('labels the top speed with the selected unit', () {
      expect(
        sessionDataLine(_session(), SpeedUnit.milesPerHour),
        '04:12 · MAX 36.1 mph',
      );
    });

    test('omits the run count when it is unknown', () {
      expect(
        sessionDataLine(_session(), SpeedUnit.kilometersPerHour),
        '04:12 · MAX 58.1 km/h',
      );
    });
  });
}
