import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:goofyrider_mobile/core/constants/session_constants.dart';
import 'package:goofyrider_mobile/features/session/data/geolocator_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

void main() {
  late GeolocatorPlatform originalPlatform;
  late StreamController<Position> positionController;
  late _FakeGeolocatorPlatform fakePlatform;

  setUp(() {
    originalPlatform = GeolocatorPlatform.instance;
    positionController = StreamController<Position>.broadcast();
    fakePlatform = _FakeGeolocatorPlatform(
      positionStream: positionController.stream,
    );
    GeolocatorPlatform.instance = fakePlatform;
  });

  tearDown(() async {
    GeolocatorPlatform.instance = originalPlatform;
    await positionController.close();
  });

  test('watchPosition drops stale pre-session samples', () async {
    final streamStartUtc = DateTime.utc(2026, 1, 1, 10, 0, 0);
    final repository =
        GeolocatorTrackingRepository(nowUtc: () => streamStartUtc);

    final samplesFuture =
        repository.watchPosition().take(2).toList();

    await Future<void>.delayed(Duration.zero);
    positionController.add(_positionAt(
      streamStartUtc.subtract(
        const Duration(seconds: SessionConstants.staleSampleThresholdSeconds),
      ),
      latitude: 49.0,
      longitude: -123.0,
    ));
    positionController.add(_positionAt(
      streamStartUtc.subtract(const Duration(seconds: 29)),
      latitude: 49.1,
      longitude: -123.1,
    ));
    positionController.add(_positionAt(
      streamStartUtc.add(const Duration(seconds: 1)),
      latitude: 49.2,
      longitude: -123.2,
    ));

    final samples = await samplesFuture;
    expect(samples, hasLength(2));
    expect(samples[0].latitude, 49.1);
    expect(samples[0].longitude, -123.1);
    expect(samples[1].latitude, 49.2);
    expect(samples[1].longitude, -123.2);
  });

  test('ensurePermissions requests again to escalate while-in-use access',
      () async {
    fakePlatform.permission = LocationPermission.whileInUse;
    fakePlatform.nextRequestPermissions.addAll(<LocationPermission>[
      LocationPermission.always,
    ]);
    final repository =
        GeolocatorTrackingRepository();

    final state = await repository.ensurePermissions();

    expect(state, LocationPermissionState.granted);
    expect(fakePlatform.requestPermissionCalls, 1);
  });

  test(
      'ensurePermissions retries after foreground grant so denied is not a dead-end',
      () async {
    fakePlatform.permission = LocationPermission.denied;
    fakePlatform.nextRequestPermissions.addAll(<LocationPermission>[
      LocationPermission.whileInUse,
      LocationPermission.always,
    ]);
    final repository =
        GeolocatorTrackingRepository();

    final state = await repository.ensurePermissions();

    expect(state, LocationPermissionState.granted);
    expect(fakePlatform.requestPermissionCalls, 2);
  });

  test('checkRecordingReadiness fails when permission is foreground-only',
      () async {
    fakePlatform.permission = LocationPermission.whileInUse;
    final repository =
        GeolocatorTrackingRepository();

    final readiness = await repository.checkRecordingReadiness();

    expect(readiness, isNotNull);
    expect(readiness, contains('Allow all the time'));
  });
}

class _FakeGeolocatorPlatform extends GeolocatorPlatform
    with MockPlatformInterfaceMixin {
  _FakeGeolocatorPlatform({
    required this.positionStream,
  });

  final Stream<Position> positionStream;
  LocationPermission permission = LocationPermission.always;
  bool serviceEnabled = true;
  int requestPermissionCalls = 0;
  final List<LocationPermission> nextRequestPermissions = <LocationPermission>[];

  @override
  Future<LocationPermission> checkPermission() async {
    return permission;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    return positionStream;
  }

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) {
    throw UnimplementedError();
  }

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async {
    return null;
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    return serviceEnabled;
  }

  @override
  Future<bool> openAppSettings() async {
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    return true;
  }

  @override
  Future<LocationAccuracyStatus> requestTemporaryFullAccuracy({
    required String purposeKey,
  }) async {
    return LocationAccuracyStatus.precise;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestPermissionCalls += 1;
    if (nextRequestPermissions.isNotEmpty) {
      permission = nextRequestPermissions.removeAt(0);
    }
    return permission;
  }

  @override
  Stream<ServiceStatus> getServiceStatusStream() {
    return const Stream<ServiceStatus>.empty();
  }
}

Position _positionAt(
  DateTime timestampUtc, {
  required double latitude,
  required double longitude,
}) {
  return Position(
    longitude: longitude,
    latitude: latitude,
    timestamp: timestampUtc,
    accuracy: 5,
    altitude: 1000,
    altitudeAccuracy: 6,
    heading: 90,
    headingAccuracy: 2,
    speed: 12,
    speedAccuracy: 1,
    isMocked: false,
  );
}
