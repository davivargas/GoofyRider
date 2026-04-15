import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/app/shell/home_screen.dart';
import 'package:goofyrider_mobile/core/providers/distance_unit_preference_provider.dart';
import 'package:goofyrider_mobile/core/utils/date_time_formatting.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_models.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_repository.dart';
import 'package:goofyrider_mobile/features/auth/presentation/auth_controller.dart';
import 'package:goofyrider_mobile/features/auth/presentation/auth_providers.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_models.dart';
import 'package:goofyrider_mobile/features/resorts/presentation/resort_providers.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';
import 'package:goofyrider_mobile/features/weather/domain/weather_models.dart';
import 'package:goofyrider_mobile/features/weather/presentation/weather_providers.dart';

class _FakeAuthRepository implements AuthRepository {
  const _FakeAuthRepository();

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
  _FakeAuthController() : super(const _FakeAuthRepository()) {
    state = const AuthState(
      status: AuthStatus.authenticated,
      session: AuthSession(
        accessToken: 'access',
        refreshToken: 'refresh',
        user: UserProfile(
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

ResortSummary _buildResort({
  String id = 'resort-1',
  String name = 'Whistler Blackcomb',
  String? cachedWeatherText = 'Sunny',
  double? cachedWeatherTempC = -2,
  bool isFavorite = true,
}) {
  return ResortSummary(
    id: id,
    name: name,
    country: 'Canada',
    region: 'BC',
    city: 'Whistler',
    latitude: 50.1163,
    longitude: -122.9574,
    elevationBaseM: 653,
    elevationTopM: 2240,
    isFavorite: isFavorite,
    cachedWeatherText: cachedWeatherText,
    cachedWeatherTempC: cachedWeatherTempC,
    isStale: false,
  );
}

ResortWeather _buildWeather({
  required String resortId,
  required String conditionsText,
  required double tempC,
}) {
  return ResortWeather(
    resortId: resortId,
    observedAt: DateTime.utc(2026, 1, 1, 18),
    tempC: tempC,
    windKph: null,
    snowfallCm24h: null,
    conditionsText: conditionsText,
    todayHighC: null,
    todayLowC: null,
    snowfallNext24hCm: null,
    weatherCodeText: null,
    fromCache: false,
    stale: false,
  );
}

void main() {
  testWidgets('home shows recent sessions above favorite resorts',
      (WidgetTester tester) async {
    final startedAt = DateTime.utc(2026, 1, 1, 16, 30);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider.overrideWith((_) => _FakeAuthController()),
          distanceUnitPreferenceProvider
              .overrideWith((_) => DistanceUnitPreferenceController()),
          historyProvider.overrideWith(
              (_) async => <LocalRideSession>[_buildSession(startedAt)]),
          favoriteResortsProvider
              .overrideWith((_) async => <ResortSummary>[_buildResort()]),
          resortWeatherProvider.overrideWith(
            (Ref ref, String resortId) async => null,
          ),
          unsyncedSessionCountProvider.overrideWith((_) async => 0),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.pumpAndSettle();

    final recentTitle = find.text('Recent sessions');
    final favoritesTitle = find.text('Favorite resorts');
    expect(recentTitle, findsOneWidget);
    expect(favoritesTitle, findsOneWidget);

    final recentTop = tester.getTopLeft(recentTitle).dy;
    final favoritesTop = tester.getTopLeft(favoritesTitle).dy;
    expect(recentTop, lessThan(favoritesTop));
  });

  testWidgets('home recent session row renders formatted timestamp',
      (WidgetTester tester) async {
    final startedAt = DateTime.utc(2026, 1, 1, 16, 30);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider.overrideWith((_) => _FakeAuthController()),
          distanceUnitPreferenceProvider
              .overrideWith((_) => DistanceUnitPreferenceController()),
          historyProvider.overrideWith(
              (_) async => <LocalRideSession>[_buildSession(startedAt)]),
          favoriteResortsProvider
              .overrideWith((_) async => <ResortSummary>[_buildResort()]),
          resortWeatherProvider.overrideWith(
            (Ref ref, String resortId) async => null,
          ),
          unsyncedSessionCountProvider.overrideWith((_) async => 0),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.textContaining(startedAt.toDayLabel()), findsOneWidget);
    expect(find.textContaining(startedAt.toTimeLabel()), findsOneWidget);
  });

  testWidgets(
      'home favorite cards update after favorites provider invalidation',
      (WidgetTester tester) async {
    final favoritesStateProvider =
        StateProvider<List<ResortSummary>>(
      (Ref ref) => <ResortSummary>[
        _buildResort(id: 'resort-1', name: 'Whistler Blackcomb'),
      ],
    );

    final container = ProviderContainer(
      overrides: <Override>[
        authControllerProvider.overrideWith((_) => _FakeAuthController()),
        distanceUnitPreferenceProvider
            .overrideWith((_) => DistanceUnitPreferenceController()),
        historyProvider.overrideWith((_) async => <LocalRideSession>[]),
        favoriteResortsProvider
            .overrideWith((Ref ref) async => ref.watch(favoritesStateProvider)),
        resortWeatherProvider.overrideWith(
          (Ref ref, String resortId) async => null,
        ),
        unsyncedSessionCountProvider.overrideWith((_) async => 0),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Whistler Blackcomb'), findsOneWidget);

    container.read(favoritesStateProvider.notifier).state = <ResortSummary>[
      _buildResort(id: 'resort-2', name: 'Sun Peaks'),
    ];
    container.invalidate(favoriteResortsProvider);

    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Whistler Blackcomb'), findsNothing);
    expect(find.text('Sun Peaks'), findsOneWidget);
  });

  testWidgets(
      'home favorite card resolves live weather when no cached weather exists',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authControllerProvider.overrideWith((_) => _FakeAuthController()),
          distanceUnitPreferenceProvider
              .overrideWith((_) => DistanceUnitPreferenceController()),
          historyProvider.overrideWith((_) async => <LocalRideSession>[]),
          favoriteResortsProvider.overrideWith(
            (_) async => <ResortSummary>[
              _buildResort(
                id: 'resort-1',
                cachedWeatherText: null,
                cachedWeatherTempC: null,
              ),
            ],
          ),
          resortWeatherProvider.overrideWith(
            (Ref ref, String resortId) async {
              await Future<void>.delayed(const Duration(milliseconds: 20));
              return _buildWeather(
                resortId: resortId,
                conditionsText: 'Powder',
                tempC: -7,
              );
            },
          ),
          unsyncedSessionCountProvider.overrideWith((_) async => 0),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.pump();
    expect(find.text('Conditions unavailable • -- C'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpAndSettle();

    expect(find.text('Powder • -7.0 C'), findsOneWidget);
  });
}
