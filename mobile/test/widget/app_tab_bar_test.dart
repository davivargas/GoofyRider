import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/app/shell/app_tab_bar.dart';
import 'package:goofyrider_mobile/app/theme/app_theme.dart';

void main() {
  testWidgets('tab bar shows five labels and reports taps',
      (WidgetTester tester) async {
    int? tapped;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          bottomNavigationBar: AppTabBar(
            selectedIndex: 0,
            onSelected: (int i) => tapped = i,
          ),
        ),
      ),
    );

    for (final String label in AppTabBar.labels) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('SEASONS'));
    expect(tapped, 3);
    expect(find.byKey(const ValueKey<String>('tab-record-puck')), findsOneWidget);
    await tester.tap(find.text('RECORD'));
    expect(tapped, 2);

    // The puck protrudes above the visible bar; the tab bar's own box now
    // includes that strip so the protruding part is hit-testable.
    tapped = null;
    await tester.tap(find.byKey(const ValueKey<String>('tab-record-puck')));
    expect(tapped, 2);
  });

  testWidgets('active tab gets a volt dot', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          bottomNavigationBar: AppTabBar(selectedIndex: 1, onSelected: (_) {}),
        ),
      ),
    );
    final dot = tester.widget<Container>(find.byKey(const ValueKey<String>('tab-dot-1')));
    expect((dot.decoration! as BoxDecoration).color, AppTokens.dark.volt);
    final idle = tester.widget<Container>(find.byKey(const ValueKey<String>('tab-dot-0')));
    expect((idle.decoration! as BoxDecoration).color, Colors.transparent);
  });
}
