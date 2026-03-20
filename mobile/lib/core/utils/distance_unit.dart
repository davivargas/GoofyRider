enum DistanceUnit {
  meters,
  feet,
}

extension DistanceUnitFormatting on DistanceUnit {
  String get shortLabel {
    switch (this) {
      case DistanceUnit.meters:
        return 'm';
      case DistanceUnit.feet:
        return 'ft';
    }
  }

  String get displayName {
    switch (this) {
      case DistanceUnit.meters:
        return 'Meters';
      case DistanceUnit.feet:
        return 'Feet';
    }
  }

  double convertFromMeters(double valueMeters) {
    switch (this) {
      case DistanceUnit.meters:
        return valueMeters;
      case DistanceUnit.feet:
        return valueMeters * 3.280839895;
    }
  }

  String formatFromMeters(
    double valueMeters, {
    int fractionDigits = 0,
  }) {
    final double converted = convertFromMeters(valueMeters);
    return '${converted.toStringAsFixed(fractionDigits)} $shortLabel';
  }
}
