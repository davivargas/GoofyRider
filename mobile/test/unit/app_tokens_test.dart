import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fall_line_mobile/app/theme/app_theme.dart';

void main() {
  test('dark and light themes expose AppTokens with the canvas palette', () {
    final dark = AppTheme.dark().extension<AppTokens>();
    final light = AppTheme.light().extension<AppTokens>();

    expect(dark, isNotNull);
    expect(light, isNotNull);
    expect(dark!.bg, const Color(0xFF0C0F12));
    expect(dark.volt, const Color(0xFFC6F24E));
    expect(dark.ice, const Color(0xFF6BD3FF));
    expect(light!.bg, const Color(0xFFF2F4F1));
    expect(light.voltText, const Color(0xFF5E8F0A));
    expect(dark.descent, dark.volt);
    expect(dark.lift, dark.iceBar);
    expect(dark.text, isNot(light.text));
  });

  test('theme uses Archivo for body and JetBrains Mono for labels', () {
    final theme = AppTheme.dark();
    expect(theme.textTheme.bodyMedium?.fontFamily, AppFonts.archivo);
    expect(theme.textTheme.labelSmall?.fontFamily, AppFonts.mono);
    expect(theme.scaffoldBackgroundColor, const Color(0xFF0C0F12));
  });

  testWidgets('context.tokens resolves the extension',
      (WidgetTester tester) async {
    late AppTokens tokens;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(builder: (BuildContext context) {
          tokens = context.tokens;
          return const SizedBox();
        }),
      ),
    );
    expect(tokens.surface, const Color(0xFFFFFFFF));
  });
}
