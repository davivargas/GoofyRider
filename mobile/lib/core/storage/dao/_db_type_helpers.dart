/// Shared type-conversion helpers used by multiple DAOs.
///
/// These are extracted from [DriftLocalDatabase] so that each DAO can map
/// raw [QueryRow] data without depending on private database methods.
library;

int asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.parse(value.toString());
}

double asDouble(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.parse(value.toString());
}

double? asNullableDouble(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value.toString());
}

int? asNullableInt(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value.toString());
}

bool? asNullableBool(Object? value) {
  final int? integerValue = asNullableInt(value);
  if (integerValue == null) {
    return null;
  }
  return integerValue == 1;
}
