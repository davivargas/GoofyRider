import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:goofyrider_mobile/features/session/data/gps_warmup_service.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';

class _FakeLocationRepository implements LocationTrackingRepository {
  _FakeLocationRepository({this.permission = LocationPermissionState.granted});

  LocationPermissionState permission;
  int checkCallCount = 0;

  @override
  Future<LocationPermissionState> checkPermissions() async {
    checkCallCount += 1;
    return permission;
  }

  @override
  Future<LocationPermissionState> ensurePermissions() async => permission;

  @override
  Future<LocationPermissionState> ensureForegroundPermission() async =>
      permission;

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Future<String?> checkRecordingReadiness() async => null;

  @override
  Future<LocationSample?> getCurrentLocationSample() async => null;

  @override
  Stream<LocationSample> watchPosition() => const Stream<LocationSample>.empty();

  @override
  Future<void> setTrackingMode(TrackingMode mode) async {}
}

class _PositionStreamFactory {
  StreamController<Position>? _controller;
  int callCount = 0;
  LocationSettings? lastSettings;

  Stream<Position> call(LocationSettings settings) {
    callCount += 1;
    lastSettings = settings;
    _controller = StreamController<Position>();
    return _controller!.stream;
  }

  Future<void> emit(Position position) async {
    _controller!.add(position);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> emitError(Object error) async {
    _controller!.addError(error);
    await Future<void>.delayed(Duration.zero);
  }

  bool get hasListener => _controller?.hasListener ?? false;
}

Position _makePosition({double latitude = 49, double longitude = -123}) {
  return Position(
    longitude: longitude,
    latitude: latitude,
    timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
    accuracy: 5,
    altitude: 100,
    altitudeAccuracy: 3,
    heading: 90,
    headingAccuracy: 1,
    speed: 2,
    speedAccuracy: 1,
    isMocked: false,
  );
}

void main() {
  group('GpsWarmupService', () {
    test('onAppForeground starts the position stream when permission granted',
        () async {
      final repo = _FakeLocationRepository();
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
      );

      await service.onAppForeground();

      expect(service.isRunning, isTrue);
      expect(factory.callCount, 1);
      expect(
        factory.lastSettings!.accuracy,
        LocationAccuracy.high,
        reason: 'warmup should request high accuracy, not bestForNavigation',
      );
      expect(factory.lastSettings!.distanceFilter, 0);
      await service.dispose();
    });

    test('onAppForeground is a no-op when permission is not granted',
        () async {
      final repo = _FakeLocationRepository(
        permission: LocationPermissionState.denied,
      );
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
      );

      await service.onAppForeground();

      expect(service.isRunning, isFalse);
      expect(factory.callCount, 0);
      await service.dispose();
    });

    test('samples stream replays the latest sample to late subscribers',
        () async {
      final repo = _FakeLocationRepository();
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
      );

      await service.onAppForeground();
      await factory.emit(_makePosition(latitude: 50, longitude: -120));

      final received = await service.samples.first;
      expect(received.latitude, 50);
      expect(received.longitude, -120);
      expect(service.latestSample!.latitude, 50);
      await service.dispose();
    });

    test('notifyRecordingStarted tears down warmup stream immediately',
        () async {
      final repo = _FakeLocationRepository();
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
      );

      await service.onAppForeground();
      expect(service.isRunning, isTrue);

      service.notifyRecordingStarted();

      expect(service.isRunning, isFalse);
      await service.dispose();
    });

    test('notifyRecordingStopped resumes warmup while app is foreground',
        () async {
      final repo = _FakeLocationRepository();
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
      );

      await service.onAppForeground();
      service.notifyRecordingStarted();
      expect(service.isRunning, isFalse);

      await service.notifyRecordingStopped();

      expect(service.isRunning, isTrue);
      expect(factory.callCount, 2);
      await service.dispose();
    });

    test('onAppBackground stops after the debounce window elapses', () async {
      final repo = _FakeLocationRepository();
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
        stopDebounce: const Duration(milliseconds: 50),
      );

      await service.onAppForeground();
      expect(service.isRunning, isTrue);

      service.onAppBackground();
      // Still running immediately after — debounce protects micro-transitions.
      expect(service.isRunning, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(service.isRunning, isFalse);
      await service.dispose();
    });

    test('debounced stop is cancelled if app returns to foreground in time',
        () async {
      final repo = _FakeLocationRepository();
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
        stopDebounce: const Duration(milliseconds: 100),
      );

      await service.onAppForeground();
      service.onAppBackground();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await service.onAppForeground();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(service.isRunning, isTrue);
      expect(factory.callCount, 1,
          reason: 'stream should not have been torn down and restarted');
      await service.dispose();
    });

    test('stream error stops warmup and clears running state', () async {
      final repo = _FakeLocationRepository();
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
      );

      await service.onAppForeground();
      expect(service.isRunning, isTrue);

      await factory.emitError(StateError('simulated provider failure'));

      expect(service.isRunning, isFalse);
      await service.dispose();
    });

    test('dispose closes the samples stream', () async {
      final repo = _FakeLocationRepository();
      final factory = _PositionStreamFactory();
      final service = GpsWarmupService(
        locationTrackingRepository: repo,
        positionStreamFactory: factory.call,
      );

      await service.onAppForeground();
      await service.dispose();

      expect(service.isRunning, isFalse);
      // Subscribing to a disposed service should complete without events.
      final samples = <LocationSample>[];
      final sub = service.samples.listen(samples.add);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(samples, isEmpty);
    });
  });
}
