import 'dart:math' as math;

import '../../../../core/constants/session_constants.dart';
import '../location_tracking_repository.dart';
import '../session_models.dart';
import '../tracking_pipeline.dart';
import 'pipeline_types.dart';

/// Pipeline stage 5: tracks filtered altitude and accumulates elevation
/// gain / loss.
class ElevationTracker {
  int _elevationGainMeters = 0;
  int _elevationLossMeters = 0;

  int get elevationGainMeters => _elevationGainMeters;
  int get elevationLossMeters => _elevationLossMeters;

  void reset() {
    _elevationGainMeters = 0;
    _elevationLossMeters = 0;
  }

  void seedFromPersistedPoints({required SessionStats stats}) {
    _elevationGainMeters = stats.elevationGainM ?? 0;
    _elevationLossMeters = stats.elevationLossM ?? 0;
  }

  /// Compute the filtered altitude and vertical delta for [sample].
  ///
  /// [lastFilteredAltitude] is provided by the coordinate filter stage.
  /// Elevation gain/loss accumulators are updated internally when the sample
  /// is accepted and vertical accuracy is reliable.
  VerticalResult updateVertical({
    required LocationSample sample,
    required QualityDecision quality,
    required double? lastFilteredAltitude,
  }) {
    if (sample.altitudeM == null) {
      return VerticalResult(
        filteredAltitudeM: lastFilteredAltitude,
        deltaM: 0,
      );
    }

    final double? previousFilteredAltitude = lastFilteredAltitude;
    final double alpha = _verticalAlpha(sample.verticalAccuracyM);
    final double filteredAltitude = previousFilteredAltitude == null
        ? sample.altitudeM!
        : previousFilteredAltitude +
            (alpha * (sample.altitudeM! - previousFilteredAltitude));

    final bool acceptedForVerticalState =
        quality.qualityClass != TrackingQualityClass.reject;
    if (!acceptedForVerticalState) {
      return VerticalResult(
        filteredAltitudeM: previousFilteredAltitude,
        deltaM: 0,
      );
    }

    final double delta = previousFilteredAltitude == null
        ? 0
        : filteredAltitude - previousFilteredAltitude;

    if (!_isVerticalReliable(sample.verticalAccuracyM)) {
      return VerticalResult(filteredAltitudeM: filteredAltitude, deltaM: delta);
    }

    final double hysteresisThreshold = math.max(
      SessionConstants.verticalHysteresisFloorMeters,
      (sample.verticalAccuracyM ??
              SessionConstants.verticalAccuracyWeakThresholdMeters) *
          SessionConstants.verticalHysteresisAccuracyFactor,
    );

    if (delta.abs() >= hysteresisThreshold) {
      if (delta > 0) {
        _elevationGainMeters += delta.round();
      } else {
        _elevationLossMeters += delta.abs().round();
      }
    }

    return VerticalResult(filteredAltitudeM: filteredAltitude, deltaM: delta);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  bool _isVerticalReliable(double? verticalAccuracyM) {
    if (verticalAccuracyM == null) {
      return false;
    }
    return verticalAccuracyM <=
        SessionConstants.verticalAccuracyWeakThresholdMeters;
  }

  double _verticalAlpha(double? verticalAccuracyM) {
    if (verticalAccuracyM == null) {
      return SessionConstants.verticalSmoothingAlphaWeak;
    }
    if (verticalAccuracyM <=
        SessionConstants.verticalAccuracyStrongThresholdMeters) {
      return SessionConstants.verticalSmoothingAlphaStrong;
    }
    return SessionConstants.verticalSmoothingAlphaWeak;
  }
}
