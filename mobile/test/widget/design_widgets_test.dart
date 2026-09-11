import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/app/theme/app_theme.dart';
import 'package:goofyrider_mobile/core/constants/app_constants.dart';
import 'package:goofyrider_mobile/core/widgets/design_widgets.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('MonoLabel uppercases and uses the mono family',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const MonoLabel('your mountains')));
    final text = tester.widget<Text>(find.text('YOUR MOUNTAINS'));
    expect(text.style?.fontFamily, AppFonts.mono);
  });

  testWidgets('StatBlock renders value and label', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const StatBlock(value: '45.9', label: 'top km/h')),
    );
    expect(find.text('45.9'), findsOneWidget);
    expect(find.text('TOP KM/H'), findsOneWidget);
  });

  testWidgets('Wordmark renders the brand constant with a volt period',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(const Wordmark()));
    expect(find.textContaining(AppConstants.brandWordmark), findsOneWidget);
  });

  testWidgets('VoltButton shows spinner when busy and disables tap',
      (WidgetTester tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(VoltButton(label: 'log in', busy: true, onPressed: () => taps++)),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(taps, 0);
  });

  testWidgets('PillToggle reports selection changes', (WidgetTester tester) async {
    String? picked;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(builder: (BuildContext context, StateSetter setState) {
          return PillToggle<String>(
            options: const <(String, String)>[('a', 'KM/H'), ('b', 'MPH')],
            selected: picked ?? 'a',
            onChanged: (String v) => setState(() => picked = v),
          );
        }),
      ),
    );
    await tester.tap(find.text('MPH'));
    await tester.pump();
    expect(picked, 'b');
  });

  testWidgets('SegmentSwatch maps descent to volt', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const SegmentSwatch(type: SessionActivityType.descent)),
    );
    final box = tester.widget<Container>(find.byType(Container));
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, AppTokens.dark.volt);
  });

  test('initialsFor takes first letters of up to two words', () {
    expect(initialsFor('Alex Rider'), 'AR');
    expect(initialsFor('rider'), 'R');
    expect(initialsFor(''), '?');
  });
}
