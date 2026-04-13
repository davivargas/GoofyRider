/// Converts an enum value to its wire-format string using a lookup map.
String enumToWire<T extends Enum>(T value, Map<T, String> wireMap) {
  final String? wire = wireMap[value];
  if (wire == null) {
    throw ArgumentError('No wire value for $value');
  }
  return wire;
}

/// Converts a wire-format string back to an enum value using a reverse lookup map.
T enumFromWire<T extends Enum>(
  String wire,
  Map<String, T> reverseMap,
  T defaultValue,
) {
  return reverseMap[wire] ?? defaultValue;
}

/// Builds a reverse lookup map from a wire map.
Map<String, T> buildReverseWireMap<T extends Enum>(Map<T, String> wireMap) {
  return wireMap.map((T key, String value) => MapEntry<String, T>(value, key));
}
