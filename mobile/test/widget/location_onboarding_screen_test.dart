import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fall_line_mobile/app/theme/app_theme.dart';
import 'package:fall_line_mobile/core/storage/app_preferences.dart';
import 'package:fall_line_mobile/features/session/data/gps_warmup_permission_preference.dart';
import 'package:fall_line_mobile/features/session/data/gps_warmup_service.dart';
import 'package:fall_line_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:fall_line_mobile/features/session/presentation/onboarding/location_onboarding_screen.dart';
import 'package:fall_line_mobile/features/session/presentation/session_providers.dart';

class _FakePreference extends GpsWarmupPermissionPreference {
  _FakePreference() : super(AppPreferences.inMemory());

  bool marked = false;

  @override
  Future<bool> hasBeenRequested() async => marked;

  @override
  Future<void> markRequested() async {
    marked = true;
  }
}

class _FakeLocationRepository implements LocationTrackingRepository {
  int foregroundRequests = 0;

  final StreamController<LocationSample> _positionController =
      StreamController<LocationSample>.broadcast();

  @override
  Future<LocationPermissionState> checkPermissions() async {
    return LocationPermissionState.denied;
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async {
    return LocationPermissionState.denied;
  }

  @override
  Future<LocationPermissionState> ensureForegroundPermission() async {
    foregroundRequests++;
    return LocationPermissionState.grantedForegroundOnly;
  }

  @override
  Future<LocationSample?> getCurrentLocationSample() async => null;

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

/// Counts warm-up restarts without touching the platform location plugin.
class _CountingWarmupService extends GpsWarmupService {
  _CountingWarmupService({required super.locationTrackingRepository});

  int foregroundCalls = 0;

  @override
  Future<void> onAppForeground() async {
    foregroundCalls++;
  }
}

Widget _host({
  required _FakePreference preference,
  required _FakeLocationRepository repository,
  required _CountingWarmupService warmup,
}) {
  final router = GoRouter(
    initialLocation: '/onboarding/location',
    routes: <RouteBase>[
      GoRoute(
          path: '/onboarding/location',
          builder: (_, __) => const LocationOnboardingScreen()),
      GoRoute(
          path: '/home',
          builder: (_, __) => const Scaffold(body: Text('HOME SCREEN'))),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      gpsWarmupPermissionPreferenceProvider.overrideWithValue(preference),
      locationTrackingRepositoryProvider.overrideWithValue(repository),
      gpsWarmupServiceProvider.overrideWithValue(warmup),
    ],
    child: MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
  );
}

void main() {
  testWidgets('ALLOW LOCATION requests permission, marks seen and goes home',
      (WidgetTester tester) async {
    final preference = _FakePreference();
    final repository = _FakeLocationRepository();
    final warmup =
        _CountingWarmupService(locationTrackingRepository: repository);
    await tester.pumpWidget(
      _host(preference: preference, repository: repository, warmup: warmup),
    );
    await tester.pumpAndSettle();

    expect(find.text('STEP 1 OF 2'), findsOneWidget);
    await tester.tap(find.text('ALLOW LOCATION'));
    await tester.pumpAndSettle();

    expect(repository.foregroundRequests, 1);
    expect(warmup.foregroundCalls, 1);
    expect(preference.marked, isTrue);
    expect(find.text('HOME SCREEN'), findsOneWidget);
  });

  testWidgets('NOT NOW marks seen without requesting permission',
      (WidgetTester tester) async {
    final preference = _FakePreference();
    final repository = _FakeLocationRepository();
    final warmup =
        _CountingWarmupService(locationTrackingRepository: repository);
    await tester.pumpWidget(
      _host(preference: preference, repository: repository, warmup: warmup),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('NOT NOW'));
    await tester.pumpAndSettle();

    expect(repository.foregroundRequests, 0);
    expect(warmup.foregroundCalls, 0);
    expect(preference.marked, isTrue);
    expect(find.text('HOME SCREEN'), findsOneWidget);
  });
}
