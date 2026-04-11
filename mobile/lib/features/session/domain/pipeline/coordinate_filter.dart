import '../../../../core/constants/session_constants.dart';
import '../session_models.dart';

/// Pipeline stage 2: applies exponential smoothing to latitude, longitude,
/// and altitude coordinates.
class CoordinateFilter {
  double? _lastFilteredLatitude;
  double? _lastFilteredLongitude;
  double? _lastFilteredAltitude;

  double? get lastFilteredLatitude => _lastFilteredLatitude;
  double? get lastFilteredLongitude => _lastFilteredLongitude;
  double? get lastFilteredAltitude => _lastFilteredAltitude;

  void reset() {
    _lastFilteredLatitude = null;
    _lastFilteredLongitude = null;
    _lastFilteredAltitude = null;
  }

  void seedFromPersistedPoints({required List<LocalSessionPoint> points}) {
    for (final LocalSessionPoint point in points) {
      if (!point.acceptedForAnalytics) {
        continue;
      }
      _lastFilteredLatitude = point.filteredLatitude ?? point.latitude;
      _lastFilteredLongitude = point.filteredLongitude ?? point.longitude;
      _lastFilteredAltitude = point.filteredAltitudeM ?? point.altitudeM;
    }
  }

  /// Apply exponential smoothing to latitude and longitude.
  ///
  /// Returns the filtered (latitude, longitude) pair as a record.
  ({double latitude, double longitude}) filter({
    required double latitude,
    required double longitude,
    required double? accuracyM,
  }) {
    final double filteredLat = _nextFilteredCoordinate(
      previous: _lastFilteredLatitude,
      current: latitude,
      accuracyM: accuracyM,
    );
    final double filteredLng = _nextFilteredCoordinate(
      previous: _lastFilteredLongitude,
      current: longitude,
      accuracyM: accuracyM,
    );
    return (latitude: filteredLat, longitude: filteredLng);
  }

  /// Commit the filtered coordinates as the new baseline.
  /// Called by the coordinator when the sample is accepted.
  void commitFiltered({
    required double latitude,
    required double longitude,
  }) {
    _lastFilteredLatitude = latitude;
    _lastFilteredLongitude = longitude;
  }

  /// Commit a filtered altitude value.
  void commitFilteredAltitude(double? altitude) {
    if (altitude != null) {
      _lastFilteredAltitude = altitude;
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  double _nextFilteredCoordinate({
    required double? previous,
    required double current,
    required double? accuracyM,
  }) {
    if (previous == null) {
      return current;
    }

    final double alpha = _horizontalAlpha(accuracyM);
    return previous + (alpha * (current - previous));
  }

  double _horizontalAlpha(double? accuracyM) {
    if (accuracyM == null) {
      return 0.35;
    }

    final double ratio = accuracyM /
        SessionConstants.qualityLowConfidenceHorizontalAccuracyMeters;
    return (0.8 - (ratio * 0.5)).clamp(0.2, 0.75).toDouble();
  }
}
