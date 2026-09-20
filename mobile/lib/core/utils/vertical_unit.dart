/// Vertical measurements: elevation loss, altitude. Distinct from
/// [DistanceUnit], which covers horizontal distance travelled.
enum VerticalUnit {
  meters,
  feet,
}

extension VerticalUnitFormatting on VerticalUnit {
  String get shortLabel {
    switch (this) {
      case VerticalUnit.meters:
        return 'm';
      case VerticalUnit.feet:
        return 'ft';
    }
  }

  String get displayName {
    switch (this) {
      case VerticalUnit.meters:
        return 'Meters';
      case VerticalUnit.feet:
        return 'Feet';
    }
  }

  double convertFromMeters(double valueMeters) {
    switch (this) {
      case VerticalUnit.meters:
        return valueMeters;
      case VerticalUnit.feet:
        return valueMeters * 3.280839895;
    }
  }

  String formatFromMeters(
    double valueMeters, {
    int fractionDigits = 0,
  }) {
    final converted = convertFromMeters(valueMeters);
    return '${converted.toStringAsFixed(fractionDigits)} $shortLabel';
  }
}
