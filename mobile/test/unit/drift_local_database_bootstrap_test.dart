import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';

void main() {
  group('DriftLocalDatabase.openOrFallback', () {
    test('returns primary database when primary open succeeds', () async {
      var fallbackCalled = false;
      final database = await DriftLocalDatabase.openOrFallback(
        primaryOpen: DriftLocalDatabase.openInMemory,
        fallbackOpen: () async {
          fallbackCalled = true;
          return DriftLocalDatabase.openInMemory();
        },
      );

      expect(fallbackCalled, isFalse);
      await database.close();
    });

    test('returns fallback database when primary open throws', () async {
      Object? capturedError;
      StackTrace? capturedStackTrace;
      final database = await DriftLocalDatabase.openOrFallback(
        primaryOpen: () async => throw StateError('primary failed'),
        fallbackOpen: DriftLocalDatabase.openInMemory,
        onPrimaryOpenError: (Object error, StackTrace stackTrace) {
          capturedError = error;
          capturedStackTrace = stackTrace;
        },
      );

      expect(capturedError, isA<StateError>());
      expect(capturedStackTrace, isNotNull);
      await database.close();
    });
  });
}
