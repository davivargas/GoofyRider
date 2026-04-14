import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/location_tracking_repository.dart';

/// Keeps the GPS chip warm while the app is foregrounded and not recording,
/// so the first fix on pre-record screens and recording start is instantaneous.
///
/// Intentionally bypasses [LocationTrackingRepository.watchPosition], because
/// that path attaches `AndroidSettings.foregroundNotificationConfig` and would
/// spin up the recording foreground service. Warmup uses a plain
/// [LocationSettings] stream that stops as soon as listeners go away.
class GpsWarmupService {
  GpsWarmupService({
    required LocationTrackingRepository locationTrackingRepository,
    AppLogger logger = const AppLogger(),
    Duration stopDebounce = const Duration(milliseconds: 500),
    Stream<Position> Function(LocationSettings settings)? positionStreamFactory,
  })  : _locationTrackingRepository = locationTrackingRepository,
        _logger = logger,
        _stopDebounce = stopDebounce,
        _positionStreamFactory = positionStreamFactory ?? _defaultPositionStreamFactory;

  static Stream<Position> _defaultPositionStreamFactory(LocationSettings settings) {
    return Geolocator.getPositionStream(locationSettings: settings);
  }

  static const LocationSettings _warmupSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 0,
  );

  final LocationTrackingRepository _locationTrackingRepository;
  final AppLogger _logger;
  final Duration _stopDebounce;
  final Stream<Position> Function(LocationSettings settings) _positionStreamFactory;

  final StreamController<LocationSample> _samplesController =
      StreamController<LocationSample>.broadcast();

  bool _appForeground = false;
  bool _recordingActive = false;
  bool _isStreamRunning = false;
  bool _permissionDeniedLogged = false;
  Timer? _stopDebounceTimer;
  StreamSubscription<Position>? _positionSubscription;
  LocationSample? _latestSample;

  /// Stream of warmup samples. Each new listener first receives the latest
  /// cached sample (if any) so consumers rendering a marker don't need to
  /// wait for the next GPS update after they subscribe.
  Stream<LocationSample> get samples async* {
    final cached = _latestSample;
    if (cached != null) {
      yield cached;
    }
    yield* _samplesController.stream;
  }

  /// Most recent warmup sample, if any. Handy for rendering an immediate
  /// marker when a consumer subscribes after the first fix has already landed.
  LocationSample? get latestSample => _latestSample;

  bool get isRunning => _isStreamRunning;

  Future<void> onAppForeground() async {
    _appForeground = true;
    await _reconcile();
  }

  void onAppBackground() {
    _appForeground = false;
    _reconcileSync();
  }

  void notifyRecordingStarted() {
    _recordingActive = true;
    // Recording takes over the GPS immediately — cancel any pending debounced
    // stop and tear down synchronously so there is no provider contention.
    _stopDebounceTimer?.cancel();
    _stopDebounceTimer = null;
    if (_isStreamRunning) {
      _stopImmediate(reason: 'recording_started');
    }
  }

  Future<void> notifyRecordingStopped() async {
    _recordingActive = false;
    // Reset permission log so a denied->granted transition across a session
    // gets a fresh warning.
    _permissionDeniedLogged = false;
    await _reconcile();
  }

  Future<void> dispose() async {
    _stopDebounceTimer?.cancel();
    _stopDebounceTimer = null;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _isStreamRunning = false;
    await _samplesController.close();
  }

  Future<void> _reconcile() async {
    final shouldRun = _appForeground && !_recordingActive;
    if (shouldRun) {
      _stopDebounceTimer?.cancel();
      _stopDebounceTimer = null;
      if (!_isStreamRunning) {
        await _start();
      }
      return;
    }
    _scheduleDebouncedStop();
  }

  void _reconcileSync() {
    final shouldRun = _appForeground && !_recordingActive;
    if (shouldRun) {
      return;
    }
    _scheduleDebouncedStop();
  }

  void _scheduleDebouncedStop() {
    if (!_isStreamRunning) {
      return;
    }
    _stopDebounceTimer?.cancel();
    _stopDebounceTimer = Timer(_stopDebounce, () {
      _stopDebounceTimer = null;
      if (_appForeground && !_recordingActive) {
        return;
      }
      _stopImmediate(reason: 'debounce_elapsed');
    });
  }

  Future<void> _start() async {
    final permission =
        await _locationTrackingRepository.checkPermissions();
    if (permission != LocationPermissionState.granted &&
        permission != LocationPermissionState.grantedForegroundOnly) {
      if (!_permissionDeniedLogged) {
        _logger.info(
          'GpsWarmupService: skipping warmup; permission state is $permission',
        );
        _permissionDeniedLogged = true;
      }
      return;
    }
    _permissionDeniedLogged = false;

    try {
      final stream = _positionStreamFactory(_warmupSettings);
      _positionSubscription = stream.listen(
        _handlePosition,
        onError: _handleStreamError,
        cancelOnError: false,
      );
      _isStreamRunning = true;
      _logger.info('GpsWarmupService: warmup stream started');
    } on Object catch (error, stackTrace) {
      _logger.error(
        'GpsWarmupService: failed to start warmup stream',
        error: error,
        stackTrace: stackTrace,
      );
      _isStreamRunning = false;
      await _positionSubscription?.cancel();
      _positionSubscription = null;
    }
  }

  void _stopImmediate({required String reason}) {
    final sub = _positionSubscription;
    _positionSubscription = null;
    _isStreamRunning = false;
    _latestSample = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    _logger.info('GpsWarmupService: warmup stream stopped ($reason)');
  }

  void _handlePosition(Position position) {
    final sample = _toLocationSample(position);
    _latestSample = sample;
    if (!_samplesController.isClosed) {
      _samplesController.add(sample);
    }
  }

  void _handleStreamError(Object error, StackTrace stackTrace) {
    _logger.error(
      'GpsWarmupService: warmup stream error',
      error: error,
      stackTrace: stackTrace,
    );
    _stopImmediate(reason: 'stream_error');
  }

  LocationSample _toLocationSample(Position position) {
    return LocationSample(
      timestamp: position.timestamp.toUtc(),
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyM: position.accuracy,
      altitudeM: position.altitude,
      speedMps: position.speed,
      headingDeg: position.heading,
      verticalAccuracyM: position.altitudeAccuracy,
      speedAccuracyMps: position.speedAccuracy,
      bearingAccuracyDeg: position.headingAccuracy,
      isMocked: position.isMocked,
    );
  }
}
