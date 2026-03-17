import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/presentation/history_screen.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';

LocalRideSession buildSession() {
  final DateTime now = DateTime.utc(2026, 1, 1);
  return LocalRideSession(
    localId: 1,
    remoteId: null,
    resortId: 'Whistler',
    startedAt: now,
    endedAt: now,
    activeDurationS: 360,
    distanceM: 1234,
    maxSpeedMps: 18.5,
    avgSpeedMps: 9.1,
    elevationGainM: 10,
    elevationLossM: 200,
    state: LocalSessionState.syncPending,
    pointCount: 20,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  testWidgets('history screen renders session card with sync badge', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          historyProvider.overrideWith((Ref ref) async => <LocalRideSession>[buildSession()]),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: <RouteBase>[
              GoRoute(path: '/', builder: (_, __) => const HistoryScreen()),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Whistler'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
  });
}
