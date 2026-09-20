/// Horizontal distance travelled. Vertical measurements (elevation loss,
/// altitude) use `VerticalUnit` instead.
enum DistanceUnit {
  kilometers,
  miles,
}

const double _metersPerKilometer = 1000;
const double _metersPerMile = 1609.344;

extension DistanceUnitFormatting on DistanceUnit {
  String get shortLabel {
    switch (this) {
      case DistanceUnit.kilometers:
        return 'km';
      case DistanceUnit.miles:
        return 'mi';
    }
  }

  String get displayName {
    switch (this) {
      case DistanceUnit.kilometers:
        return 'Kilometers';
      case DistanceUnit.miles:
        return 'Miles';
    }
  }

  double convertFromMeters(double valueMeters) {
    switch (this) {
      case DistanceUnit.kilometers:
        return valueMeters / _metersPerKilometer;
      case DistanceUnit.miles:
        return valueMeters / _metersPerMile;
    }
  }

  String formatFromMeters(
    double valueMeters, {
    int fractionDigits = 1,
  }) {
    final converted = convertFromMeters(valueMeters);
    return '${converted.toStringAsFixed(fractionDigits)} $shortLabel';
  }
}
