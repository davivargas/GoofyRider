const Set<String> canonicalMotionStates = <String>{
  'initializing_fix',
  'active_descent',
  'lift_uphill',
  'stopped_idle',
  'low_confidence_recovery',
};

const Set<String> canonicalQualityClasses = <String>{
  'accept',
  'accept_low_confidence',
  'reject',
};

const Set<String> canonicalProviders = <String>{
  'gps',
  'fused',
  'network',
  'passive',
  'unknown',
};

String? canonicalizeMotionStateForSync(String? value) {
  final normalized = _normalizeVocabularyValue(value);
  if (normalized == null) {
    return null;
  }
  if (canonicalMotionStates.contains(normalized)) {
    return normalized;
  }
  return null;
}

String? canonicalizeQualityClassForSync(String? value) {
  final normalized = _normalizeVocabularyValue(value);
  if (normalized == null) {
    return null;
  }
  if (canonicalQualityClasses.contains(normalized)) {
    return normalized;
  }
  return null;
}

String? canonicalizeProviderForSync(String? value) {
  final normalized = _normalizeVocabularyValue(value);
  if (normalized == null) {
    return null;
  }
  if (canonicalProviders.contains(normalized)) {
    return normalized;
  }
  if (normalized == 'flp' ||
      normalized == 'fusedlocationprovider' ||
      normalized == 'fused_location_provider') {
    return 'fused';
  }
  if (normalized == 'cell' || normalized == 'cellular') {
    return 'network';
  }
  return 'unknown';
}

String? _normalizeVocabularyValue(String? value) {
  if (value == null) {
    return null;
  }
  final normalized =
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  if (normalized.isEmpty) {
    return null;
  }
  return normalized;
}
