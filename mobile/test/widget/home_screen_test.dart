import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/app/shell/home_screen.dart';
import 'package:goofyrider_mobile/core/providers/distance_unit_preference_provider.dart';
import 'package:goofyrider_mobile/core/utils/date_time_formatting.dart';
import 'package:goofyrider_mobile/core/utils/distance_unit.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_models.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_repository.dart';
import 'package:goofyrider_mobile/features/auth/presentation/auth_controller.dart';
import 'package:goofyrider_mobile/features/auth/presentation/auth_providers.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_models.dart';
import 'package:goofyrider_mobile/features/resorts/presentation/resort_providers.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';

class _FakeAuthRepository implements AuthRepository {
  @override
  Future<String?> currentAccessToken() async => 'access';

  @override
  Future<String?> currentRefreshToken() async => 'refresh';

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() async {}

  @override
  Future<String?> refreshAccessToken(String refreshToken) async => 'access';

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession?> restoreSession() async => null;
}

class _FakeAuthController extends AuthController {
  _FakeAuthController()
      : super(_FakeAuthRepository()) {
    state = AuthState(
      status: AuthStatus.authenticated,
      session: AuthSession(
        accessToken: 'access',
        refreshToken: 'refresh',
        user: const UserProfile(
          id: 'user-1',
          email: 'rider@example.com',
          displayName: 'Rider',
        ),
      ),
    );
  }
}

LocalRideSession _buildSession(DateTime startedAt) {
  return LocalRideSession(
    localId: 7,
    ownerUserId: 'user-1',
    remoteId: null,
    resortId: 'Whistler',
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(minutes: 6)),
    activeDurationS: 360,
    distanceM: 1234,
    maxSpeedMps: 18,
    avgSpeedMps: 10,
    elevationGainM: 50,
    elevationLossM: 420,
    state: LocalSessionState.synced,
    pointCount: 25,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: startedAt,
    updatedAt: startedAt,
  );
}

ResortSummary _buildResort() {
  return const ResortSummary(
    id: 'resort-1',
    name: 'Whistler Blackcomb',
    country: 'Canada',
    region: 'BC',
    city: 'Whistler',
    latitude: 50.1163,
    longitude: -122.9574,
    elevationBaseM: 653,
    elevationTopM: 2240,
    isFavorite: true,
    cachedWeatherText: 'Sunny',
    cachedWeatherTempC: -2,
    isStale: false,
  );
}

void main() {
  testWidgets('home shows recent sessions above favorite resorts',
      (WidgetTester tester) async {
    final DateTime startedAt = DateTime.utc(2026, 1, 1, 16, 30);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider.overrideWith((_) => _FakeAuthController()),
          distanceUnitPreferenceProvider
              .overrideWith((_) => DistanceUnitPreferenceController()),
          historyProvider
              .overrideWith((_) async => <LocalRideSession>[_buildSession(startedAt)]),
          favoriteResortsProvider
              .overrideWith((_) async => <ResortSummary>[_buildResort()]),
          unsyncedSessionCountProvider.overrideWith((_) async => 0),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.pumpAndSettle();

    final Finder recentTitle = find.text('Recent sessions');
    final Finder favoritesTitle = find.text('Favorite resorts');
    expect(recentTitle, findsOneWidget);
    expect(favoritesTitle, findsOneWidget);

    final double recentTop = tester.getTopLeft(recentTitle).dy;
    final double favoritesTop = tester.getTopLeft(favoritesTitle).dy;
    expect(recentTop, lessThan(favoritesTop));
  });

  testWidgets('home recent session row renders formatted timestamp',
      (WidgetTester tester) async {
    final DateTime startedAt = DateTime.utc(2026, 1, 1, 16, 30);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider.overrideWith((_) => _FakeAuthController()),
          distanceUnitPreferenceProvider
              .overrideWith((_) => DistanceUnitPreferenceController()),
          historyProvider
              .overrideWith((_) async => <LocalRideSession>[_buildSession(startedAt)]),
          favoriteResortsProvider
              .overrideWith((_) async => <ResortSummary>[_buildResort()]),
          unsyncedSessionCountProvider.overrideWith((_) async => 0),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.textContaining(startedAt.toDayLabel()), findsOneWidget);
    expect(find.textContaining(startedAt.toTimeLabel()), findsOneWidget);
  });
}
