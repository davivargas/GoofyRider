import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fall_line_mobile/app/shell/app_tab_bar.dart';
import 'package:fall_line_mobile/app/theme/app_theme.dart';

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

  testWidgets('bottomClearance measures to the visible bar top, not the puck strip',
      (WidgetTester tester) async {
    late double insideShell;
    late double outsideShell;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Column(
          children: <Widget>[
            // Scaffold.extendBody hands the body padding.bottom == full bar box.
            MediaQuery(
              data: const MediaQueryData(
                padding: EdgeInsets.only(
                  bottom: AppTabBar.height + AppTabBar.puckOverhang + 34,
                ),
              ),
              child: Builder(builder: (BuildContext context) {
                insideShell = AppTabBar.bottomClearance(context);
                return const SizedBox();
              }),
            ),
            MediaQuery(
              data: const MediaQueryData(),
              child: Builder(builder: (BuildContext context) {
                outsideShell = AppTabBar.bottomClearance(context);
                return const SizedBox();
              }),
            ),
          ],
        ),
      ),
    );
    expect(insideShell, AppTabBar.height + 34);
    expect(outsideShell, 0);
  });
}
