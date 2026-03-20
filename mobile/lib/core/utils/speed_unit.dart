enum SpeedUnit {
  kilometersPerHour,
  metersPerSecond,
  milesPerHour,
}

extension SpeedUnitFormatting on SpeedUnit {
  String get shortLabel {
    switch (this) {
      case SpeedUnit.kilometersPerHour:
        return 'km/h';
      case SpeedUnit.metersPerSecond:
        return 'm/s';
      case SpeedUnit.milesPerHour:
        return 'mph';
    }
  }

  String get displayName {
    switch (this) {
      case SpeedUnit.kilometersPerHour:
        return 'Kilometers per hour';
      case SpeedUnit.metersPerSecond:
        return 'Meters per second';
      case SpeedUnit.milesPerHour:
        return 'Miles per hour';
    }
  }

  double convertFromMetersPerSecond(double valueMps) {
    switch (this) {
      case SpeedUnit.kilometersPerHour:
        return valueMps * 3.6;
      case SpeedUnit.metersPerSecond:
        return valueMps;
      case SpeedUnit.milesPerHour:
        return valueMps * 2.2369362921;
    }
  }

  String formatFromMetersPerSecond(
    double valueMps, {
    int fractionDigits = 1,
  }) {
    final double converted = convertFromMetersPerSecond(valueMps);
    return '${converted.toStringAsFixed(fractionDigits)} $shortLabel';
  }
}
