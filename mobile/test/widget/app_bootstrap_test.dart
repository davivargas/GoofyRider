import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';
import 'package:goofyrider_mobile/main.dart';

void main() {
  testWidgets('bootstrap app shows loading until local storage is ready',
      (WidgetTester tester) async {
    final Completer<DriftLocalDatabase> completer =
        Completer<DriftLocalDatabase>();

    await tester.pumpWidget(
      GoofyRiderBootstrapApp(
        databaseLoader: () => completer.future,
        appBuilder: (_) => const MaterialApp(
          home: Scaffold(body: Text('Ready')),
        ),
      ),
    );

    expect(find.text('Opening local storage...'), findsOneWidget);

    completer.complete(await DriftLocalDatabase.openInMemory());
    await tester.pumpAndSettle();

    expect(find.text('Ready'), findsOneWidget);
  });

  testWidgets('bootstrap app shows retryable error when storage open fails',
      (WidgetTester tester) async {
    int attempts = 0;

    await tester.pumpWidget(
      GoofyRiderBootstrapApp(
        databaseLoader: () async {
          attempts += 1;
          if (attempts == 1) {
            throw StateError('disk unavailable');
          }
          return DriftLocalDatabase.openInMemory();
        },
        appBuilder: (_) => const MaterialApp(
          home: Scaffold(body: Text('Ready')),
        ),
      ),
    );

    await tester.pumpAndSettle();
    final Object? error = tester.takeException();
    expect(find.textContaining('Local storage could not be opened'),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    expect(
      error,
      isA<StateError>().having(
        (StateError stateError) => stateError.message,
        'message',
        'disk unavailable',
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Ready'), findsOneWidget);
    expect(attempts, 2);
  });
}
