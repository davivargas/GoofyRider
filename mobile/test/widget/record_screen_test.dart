import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/record_screen.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';

class FakeLocationRepository implements LocationTrackingRepository {
  @override
  Future<LocationPermissionState> checkPermissions() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Stream<LocationSample> watchPosition() =>
      const Stream<LocationSample>.empty();
}

class FakeSessionRepository implements SessionRepository {
  LocalRideSession? session;

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
    session = _buildSession(LocalSessionState.syncPending);
    return session!;
  }

  @override
  Future<SessionDetail> getSessionDetail(int localSessionId) async {
    throw UnimplementedError();
  }

  @override
  Future<List<LocalRideSession>> listLocalAndRemoteSessionHistory() async =>
      <LocalRideSession>[];

  @override
  Future<LocalRideSession> pauseLocalSession(int localSessionId) async {
    session = _buildSession(LocalSessionState.paused);
    return session!;
  }

  @override
  Future<LocalRideSession?> recoverInProgressSession() async => null;

  @override
  Future<LocalRideSession> resumeLocalSession(int localSessionId) async {
    session = _buildSession(LocalSessionState.recording);
    return session!;
  }

  @override
  Future<LocalRideSession> retryFailedSync(int localSessionId) async {
    session = _buildSession(LocalSessionState.synced);
    return session!;
  }

  @override
  Future<LocalRideSession> startLocalSession({String? resortId}) async {
    session = _buildSession(LocalSessionState.recording);
    return session!;
  }

  @override
  Future<LocalRideSession> syncSession(int localSessionId) async {
    session = _buildSession(LocalSessionState.synced);
    return session!;
  }

  @override
  Future<int> unsyncedCount() async => 0;

  LocalRideSession _buildSession(LocalSessionState state) {
    final DateTime now = DateTime.utc(2026, 1, 1);
    return LocalRideSession(
      localId: 1,
      remoteId: null,
      resortId: null,
      startedAt: now,
      endedAt: now,
      activeDurationS: 0,
      distanceM: 0,
      maxSpeedMps: 0,
      avgSpeedMps: 0,
      elevationGainM: null,
      elevationLossM: null,
      state: state,
      pointCount: 0,
      syncAttemptCount: 0,
      lastSyncError: null,
      createdAt: now,
      updatedAt: now,
    );
  }
}

void main() {
  testWidgets('record screen toggles from start to finish flow',
      (WidgetTester tester) async {
    final FakeSessionRepository fakeRepository = FakeSessionRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(fakeRepository),
          locationTrackingRepositoryProvider
              .overrideWithValue(FakeLocationRepository()),
        ],
        child: const MaterialApp(home: RecordScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Start Recording'), findsOneWidget);

    await tester.tap(find.text('Start Recording'));
    await tester.pumpAndSettle();

    expect(find.text('Finish'), findsOneWidget);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(find.text('Start Recording'), findsOneWidget);
  });
}
