import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/main.dart';

void main() {
  testWidgets(
      'runAppWith shows BootstrapErrorApp with error details when storage open fails',
      (WidgetTester tester) async {
    var attempts = 0;

    await runAppWith(
      loader: () async {
        attempts += 1;
        throw StateError('disk unavailable #$attempts');
      },
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('App bootstrap failed.'), findsOneWidget);
    expect(find.textContaining('disk unavailable #1'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    expect(attempts, 1);
  });

  testWidgets('BootstrapErrorApp retry button re-invokes the loader',
      (WidgetTester tester) async {
    var attempts = 0;

    await runAppWith(
      loader: () async {
        attempts += 1;
        throw StateError('disk unavailable #$attempts');
      },
    );
    await tester.pumpAndSettle();

    expect(attempts, 1);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.textContaining('disk unavailable #2'), findsOneWidget);
  });
}
