import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/constants/app_constants.dart';
import 'package:goofyrider_mobile/core/providers.dart';
import 'package:goofyrider_mobile/core/providers/distance_unit_preference_provider.dart';
import 'package:goofyrider_mobile/core/utils/distance_unit.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/domain/session_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/record_screen.dart';
import 'package:goofyrider_mobile/features/session/presentation/recording_controller.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';
import 'package:latlong2/latlong.dart';

class FakeLocationRepository implements LocationTrackingRepository {
  final StreamController<LocationSample> _positionController =
      StreamController<LocationSample>.broadcast();

  @override
  Future<LocationPermissionState> checkPermissions() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    return LocationPermissionState.granted;
  }

  @override
  Future<LocationSample?> getCurrentLocationSample() async {
    return LocationSample(
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
      latitude: 49,
      longitude: -123,
      accuracyM: 6,
      altitudeM: 500,
      speedMps: 0,
      headingDeg: 0,
    );
  }

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Future<String?> checkRecordingReadiness() async => null;

  @override
  Stream<LocationSample> watchPosition() => _positionController.stream;

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {}
}

class FakeSessionRepository implements SessionRepository {
  LocalRideSession? session;

  @override
  Future<void> appendLocationPoint(
    int localSessionId,
    NewSessionPoint point,
  ) async {}

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
  Future<DeleteSessionResult> deleteSession(LocalRideSession session) async {
    return const DeleteSessionResult(
      disposition: DeleteSessionDisposition.localOnly,
    );
  }

  @override
  Future<String> resolveSessionResortLabel(LocalRideSession session) async {
    return session.resortId ?? 'Unknown resort';
  }

  @override
  Future<LocalRideSession> pauseLocalSession(int localSessionId) async {
    session = _buildSession(LocalSessionState.paused);
    return session!;
  }

  @override
  Future<LocalRideSession?> recoverInProgressSession() async => null;

  @override
  Future<void> recordTrackingDiagnostic(
    int localSessionId, {
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) async {}

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
      ownerUserId: 'user-1',
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

class _FakeDistanceUnitPreferenceController
    extends DistanceUnitPreferenceController {
  _FakeDistanceUnitPreferenceController(DistanceUnit unit)
      : super() {
    state = unit;
  }
}

class _FakeRecordingController extends RecordingController {
  _FakeRecordingController({
    required super.sessionRepository,
    required super.locationTrackingRepository,
    required RecordingViewState initialState,
  }) {
    state = initialState;
  }

  @override
  Future<void> bootstrap({String? preselectedResortId}) async {}
}

void main() {
  testWidgets('record screen shows gps badge and resets after finish',
      (WidgetTester tester) async {
    final FakeSessionRepository fakeRepository = FakeSessionRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(fakeRepository),
          locationTrackingRepositoryProvider
              .overrideWithValue(FakeLocationRepository()),
          activeMapTileProviderConfigProvider
              .overrideWithValue(MapTileProviderConfig.devFallback),
        ],
        child: const MaterialApp(home: RecordScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Start Recording'), findsOneWidget);
    expect(find.text('GPS'), findsOneWidget);

    await tester.tap(find.text('Start Recording'));
    await tester.pumpAndSettle();
    expect(find.text('Finish'), findsOneWidget);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(find.text('Start Recording'), findsOneWidget);
  });

  testWidgets('record screen renders vertical and altitude cards in meters',
      (WidgetTester tester) async {
    final FakeSessionRepository fakeRepository = FakeSessionRepository();
    final FakeLocationRepository fakeLocationRepository =
        FakeLocationRepository();
    final _FakeRecordingController fakeController = _FakeRecordingController(
      sessionRepository: fakeRepository,
      locationTrackingRepository: fakeLocationRepository,
      initialState: RecordingViewState.initial().copyWith(
        phase: RecordScreenPhase.recording,
        permission: const PermissionViewState(
          permissionState: LocationPermissionState.granted,
        ),
        tracking: const TrackingViewState(
          liveStats: SessionStats(
            durationS: 180,
            distanceM: 1200,
            maxSpeedMps: 15,
            avgSpeedMps: 8,
            elevationGainM: 40,
            elevationLossM: 320,
          ),
          route: <LatLng>[],
          currentSpeedMps: 10,
          currentAltitudeM: 1550,
          maxSpeedMps: 15,
          elapsed: Duration(minutes: 3),
          lowAccuracy: false,
          gpsSignal: GpsSignalState(bars: 4, description: 'Excellent'),
        ),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(fakeRepository),
          locationTrackingRepositoryProvider
              .overrideWithValue(fakeLocationRepository),
          recordingControllerProvider.overrideWith((_) => fakeController),
          distanceUnitPreferenceProvider.overrideWith(
            (_) => _FakeDistanceUnitPreferenceController(DistanceUnit.meters),
          ),
          activeMapTileProviderConfigProvider
              .overrideWithValue(MapTileProviderConfig.devFallback),
        ],
        child: const MaterialApp(home: RecordScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Vertical'), findsOneWidget);
    expect(find.text('320 m'), findsOneWidget);
    expect(find.text('Altitude'), findsOneWidget);
    expect(find.text('1550 m'), findsOneWidget);
  });

  testWidgets('record screen renders vertical and altitude cards in feet',
      (WidgetTester tester) async {
    final FakeSessionRepository fakeRepository = FakeSessionRepository();
    final FakeLocationRepository fakeLocationRepository =
        FakeLocationRepository();
    final _FakeRecordingController fakeController = _FakeRecordingController(
      sessionRepository: fakeRepository,
      locationTrackingRepository: fakeLocationRepository,
      initialState: RecordingViewState.initial().copyWith(
        phase: RecordScreenPhase.recording,
        permission: const PermissionViewState(
          permissionState: LocationPermissionState.granted,
        ),
        tracking: const TrackingViewState(
          liveStats: SessionStats(
            durationS: 180,
            distanceM: 1200,
            maxSpeedMps: 15,
            avgSpeedMps: 8,
            elevationGainM: 40,
            elevationLossM: 320,
          ),
          route: <LatLng>[],
          currentSpeedMps: 10,
          currentAltitudeM: 1550,
          maxSpeedMps: 15,
          elapsed: Duration(minutes: 3),
          lowAccuracy: false,
          gpsSignal: GpsSignalState(bars: 4, description: 'Excellent'),
        ),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(fakeRepository),
          locationTrackingRepositoryProvider
              .overrideWithValue(fakeLocationRepository),
          recordingControllerProvider.overrideWith((_) => fakeController),
          distanceUnitPreferenceProvider.overrideWith(
            (_) => _FakeDistanceUnitPreferenceController(DistanceUnit.feet),
          ),
          activeMapTileProviderConfigProvider
              .overrideWithValue(MapTileProviderConfig.devFallback),
        ],
        child: const MaterialApp(home: RecordScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('1050 ft'), findsOneWidget);
    expect(find.text('5085 ft'), findsOneWidget);
  });
}
