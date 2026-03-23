import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_models.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_repository.dart';
import 'package:goofyrider_mobile/features/auth/presentation/auth_providers.dart';
import 'package:goofyrider_mobile/features/auth/presentation/login_screen.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/record_screen.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';
import 'package:integration_test/integration_test.dart';

class FakeAuthRepository implements AuthRepository {
  @override
  Future<String?> currentAccessToken() async => 'token';

  @override
  Future<String?> currentRefreshToken() async => 'refresh';

  @override
  Future<AuthSession> login(
      {required String email, required String password}) async {
    return const AuthSession(
      accessToken: 'token',
      refreshToken: 'refresh',
      user: UserProfile(
          id: '1', email: 'test@example.com', displayName: 'Tester'),
    );
  }

  @override
  Future<void> logout() async {}

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<String?> refreshAccessToken(String refreshToken) async => 'token';

  @override
  Future<AuthSession?> restoreSession() async => null;
}

class FakeLocationRepository implements LocationTrackingRepository {
  @override
  Future<LocationPermissionState> checkPermissions() async =>
      LocationPermissionState.granted;

  @override
  Future<LocationPermissionState> ensurePermissions() async =>
      LocationPermissionState.granted;

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Future<String?> checkRecordingReadiness() async => null;

  @override
  Future<LocationSample?> getCurrentLocationSample() async {
    return LocationSample(
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
      latitude: 50.0,
      longitude: -122.0,
      accuracyM: 5,
      altitudeM: 1000,
      speedMps: 0,
      headingDeg: 0,
    );
  }

  @override
  Stream<LocationSample> watchPosition() {
    return Stream<LocationSample>.fromIterable(<LocationSample>[
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
        latitude: 50.0,
        longitude: -122.0,
        accuracyM: 5,
        altitudeM: 1000,
        speedMps: 5,
        headingDeg: 0,
      ),
      LocationSample(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 2),
        latitude: 50.0005,
        longitude: -122.0005,
        accuracyM: 5,
        altitudeM: 1005,
        speedMps: 6,
        headingDeg: 0,
      ),
    ]);
  }

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {}
}

class FakeSessionRepository implements SessionRepository {
  bool syncCalled = false;

  @override
  Future<void> appendLocationPoint(
      int localSessionId, NewSessionPoint point) async {}

  @override
  Future<SessionStats> computeSessionStats(int localSessionId) async =>
      SessionStats.zero;

  @override
  Future<LocalRideSession> finishLocalSession(
    int localSessionId, {
    int? activeDurationS,
  }) async {
    return _session(LocalSessionState.syncPending);
  }

  @override
  Future<SessionDetail> getSessionDetail(int localSessionId) async {
    throw UnimplementedError();
  }

  @override
  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit = 120,
  }) async {
    return const <TrackingDiagnosticEvent>[];
  }

  @override
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async =>
      <LocalRideSession>[];

  @override
  Future<List<LocalRideSession>> listPendingSyncSessions() async =>
      <LocalRideSession>[];

  @override
  Future<void> refreshRemoteSessionHistoryCache() async {}

  @override
  Future<LocalRideSession> pauseLocalSession(int localSessionId) async =>
      _session(LocalSessionState.paused);

  @override
  Future<LocalRideSession?> recoverInProgressSession() async => null;

  @override
  Future<LocalRideSession> resumeLocalSession(int localSessionId) async =>
      _session(LocalSessionState.recording);

  @override
  Future<LocalRideSession> retryFailedSync(int localSessionId) async =>
      _session(LocalSessionState.synced);

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async =>
      _session(LocalSessionState.recording);

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
    syncCalled = true;
    return _session(LocalSessionState.synced);
  }

  @override
  Future<void> recordTrackingDiagnostic(
    int localSessionId, {
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) async {}

  @override
  Future<int> unsyncedCount() async => 0;

  LocalRideSession _session(LocalSessionState state) {
    final DateTime now = DateTime.utc(2026, 1, 1);
    return LocalRideSession(
      localId: 1,
      ownerUserId: 'user-1',
      remoteId: null,
      resortId: null,
      startedAt: now,
      endedAt: now,
      activeDurationS: 10,
      distanceM: 100,
      maxSpeedMps: 6,
      avgSpeedMps: 4,
      elevationGainM: 5,
      elevationLossM: 2,
      state: state,
      pointCount: 2,
      syncAttemptCount: 0,
      lastSyncError: null,
      createdAt: now,
      updatedAt: now,
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('login -> record -> finish -> sync flow',
      (WidgetTester tester) async {
    final FakeSessionRepository fakeSessionRepository = FakeSessionRepository();

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        sessionRepositoryProvider.overrideWithValue(fakeSessionRepository),
        locationTrackingRepositoryProvider
            .overrideWithValue(FakeLocationRepository()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

    await tester.enterText(
        find.byType(TextFormField).at(0), 'test@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('Log In'));
    await tester.pumpAndSettle();

    expect(container.read(authControllerProvider).status,
        AuthStatus.authenticated);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RecordScreen()),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Recording'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();

    expect(fakeSessionRepository.syncCalled, isTrue);
  });
}
