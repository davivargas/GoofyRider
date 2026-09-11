# Fall Line Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle every screen of the GoofyRider Flutter app to the "Fall Line Redesign" canvas (dark-first night-ops surfaces, volt accent, mono telemetry labels, matching light mode) without changing any domain, data, or backend behaviour.

**Architecture:** A `ThemeExtension` (`AppTokens`) plus bundled Archivo / JetBrains Mono fonts become the single source of colour and type. A small set of shared widgets (`MonoLabel`, `StatBlock`, `SurfaceCard`, `StatusPill`, `VoltButton`, `GhostButton`, `Wordmark`, `SegmentSwatch`, `InitialsAvatar`) is built once, then each screen is rewritten on top of them while keeping its providers, controllers, callbacks and the copy that tests depend on. The shell gets a custom tab bar and a one-time location onboarding route.

**Tech Stack:** Flutter 3.38 / Dart 3, flutter_riverpod 2, go_router 14, flutter_map 7, intl. Tests: flutter_test.

**Spec:** `goofyrider/docs/superpowers/specs/2026-09-10-fall-line-redesign-design.md`

## Global Constraints

- All commands run from `goofyrider/mobile` unless stated. Git commands run from `goofyrider/` (repo root, branch `refactor`).
- Widgets must not call Dio or Drift directly; session lifecycle stays in `SessionStateMachine` / `RecordingController`. This plan only touches `presentation`, `app`, `core/widgets`, `core/constants`, `pubspec.yaml`, `assets/fonts`.
- No `Color(0x...)` literals in screens after this plan; colours come from `context.tokens`.
- Brand wordmark: `AppConstants.brandWordmark`, default `GOOFYRIDER`.
- Theme mode: `ThemeMode.system`.
- Fonts: Archivo (400, 600, 700, 800, 800 italic) and JetBrains Mono (400, 600, 700) bundled under `assets/fonts` with OFL licence files.
- Keep every existing provider name, controller method, tooltip (`Add favorite`, `Remove favorite`, `Session actions`, `Sync unsynced sessions`), dialog copy (`Delete session?`, `Delete`, `Cancel`) and validation message unchanged.
- Known pre-existing failures to leave alone: the three `profile_screen_test.dart` debug-export tests and the `Sync now` tooltip assertion in `history_screen_test.dart` (that code is commented out in the current app).
- Every commit message ends with `Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC`.
- Commit with `git -c core.autocrlf=false commit -F -` and a heredoc on this Windows checkout.

---

## File map

| Path | Responsibility |
|---|---|
| `assets/fonts/*.ttf`, `assets/fonts/OFL-Archivo.txt`, `assets/fonts/OFL-JetBrainsMono.txt` | Bundled type. |
| `pubspec.yaml` | Font declarations. |
| `lib/core/constants/app_constants.dart` | `brandWordmark`. |
| `lib/app/theme/app_tokens.dart` | `AppTokens` ThemeExtension, `AppFonts`, `context.tokens`. |
| `lib/app/theme/app_theme.dart` | `AppTheme.dark()` / `light()` built from tokens. |
| `lib/core/widgets/design_widgets.dart` | `MonoLabel`, `StatBlock`, `SurfaceCard`, `StatusPill`, `VoltButton`, `GhostButton`, `Wordmark`, `SegmentSwatch`, `InitialsAvatar`, `PillToggle`. |
| `lib/core/widgets/app_empty_view.dart`, `app_error_view.dart`, `app_loading_view.dart` | Restyled state views. |
| `lib/app/shell/app_tab_bar.dart`, `lib/app/shell/app_shell.dart` | Custom tab bar and shell. |
| `lib/features/session/presentation/season_summary.dart` | Pure season aggregation. |
| `lib/features/session/presentation/onboarding/location_onboarding_providers.dart`, `location_onboarding_screen.dart` | One-time location onboarding. |
| `lib/app/router/route_paths.dart`, `app_router.dart`, `lib/main.dart` | Onboarding route + redirect, theme mode. |
| `lib/features/auth/presentation/login_screen.dart`, `register_screen.dart` | Screen 1i. |
| `lib/app/shell/home_screen.dart` | Screen 1a. |
| `lib/features/resorts/presentation/resorts_list_screen.dart`, `resort_detail_screen.dart` | Screens 1f, 1g. |
| `lib/features/session/presentation/history_screen.dart` | Screen 1e. |
| `lib/features/session/presentation/session_detail_screen.dart` | Screen 1d. |
| `lib/features/session/presentation/record_screen.dart` | Screens 1b + 1c. |
| `lib/features/profile/presentation/profile_screen.dart` | Screen 1h. |
| `test/unit/app_tokens_test.dart`, `test/unit/season_summary_test.dart`, `test/widget/design_widgets_test.dart`, `test/widget/app_tab_bar_test.dart`, `test/widget/location_onboarding_screen_test.dart` | New tests. |
| Existing `test/widget/*_test.dart` | Updated presentational assertions. |

---

### Task 1: Fonts, brand constant, design tokens and theme

**Files:**
- Create: `assets/fonts/Archivo-{Regular,SemiBold,Bold,ExtraBold,ExtraBoldItalic}.ttf`, `assets/fonts/JetBrainsMono-{Regular,SemiBold,Bold}.ttf`, `assets/fonts/OFL-Archivo.txt`, `assets/fonts/OFL-JetBrainsMono.txt`
- Create: `lib/app/theme/app_tokens.dart`
- Modify: `lib/app/theme/app_theme.dart` (rewrite)
- Modify: `lib/core/constants/app_constants.dart`
- Modify: `pubspec.yaml`
- Modify: `lib/main.dart` (two `themeMode` lines)
- Test: `test/unit/app_tokens_test.dart`

**Interfaces:**
- Produces: `AppTokens` (fields `bg, canvas, surface, raised, line, text, textSecondary, textMuted, textFaint, volt, voltText, voltInk, ice, iceBar, rec, idle, idleSwatch, mapBg, mapGlow, barBg`, getters `descent`, `lift`, `idleSegment`, statics `AppTokens.dark`, `AppTokens.light`); `extension AppTokensContext on BuildContext { AppTokens get tokens; }`; `AppFonts.archivo`, `AppFonts.mono`; `AppTheme.dark()`, `AppTheme.light()`; `AppConstants.brandWordmark`.

- [ ] **Step 1: Download fonts**

```bash
cd goofyrider/mobile && mkdir -p assets/fonts
for f in Regular SemiBold Bold ExtraBold ExtraBoldItalic; do
  curl -sL -o assets/fonts/Archivo-$f.ttf "https://raw.githubusercontent.com/Omnibus-Type/Archivo/master/fonts/ttf/Archivo-$f.ttf"
done
curl -sL -o assets/fonts/OFL-Archivo.txt "https://raw.githubusercontent.com/Omnibus-Type/Archivo/master/OFL.txt"
curl -sL -o "$TEMP/jbm.zip" "https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip"
unzip -j -o "$TEMP/jbm.zip" fonts/ttf/JetBrainsMono-Regular.ttf fonts/ttf/JetBrainsMono-SemiBold.ttf fonts/ttf/JetBrainsMono-Bold.ttf -d assets/fonts
unzip -p "$TEMP/jbm.zip" OFL.txt > assets/fonts/OFL-JetBrainsMono.txt
ls -la assets/fonts
```
Expected: eight `.ttf` files each over 100 KB plus two licence files. A `.ttf` under 10 KB is an HTML error page; re-download it.

- [ ] **Step 2: Declare fonts in `pubspec.yaml`**

Replace the `flutter:` block with:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/branding/icon.png
    - assets/branding/splash_center_icon.png
  fonts:
    - family: Archivo
      fonts:
        - asset: assets/fonts/Archivo-Regular.ttf
          weight: 400
        - asset: assets/fonts/Archivo-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/Archivo-Bold.ttf
          weight: 700
        - asset: assets/fonts/Archivo-ExtraBold.ttf
          weight: 800
        - asset: assets/fonts/Archivo-ExtraBoldItalic.ttf
          weight: 800
          style: italic
    - family: JetBrainsMono
      fonts:
        - asset: assets/fonts/JetBrainsMono-Regular.ttf
          weight: 400
        - asset: assets/fonts/JetBrainsMono-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/JetBrainsMono-Bold.ttf
          weight: 700
```

- [ ] **Step 3: Add the brand constant**

In `lib/core/constants/app_constants.dart`, inside `class AppConstants` right after `androidEmulatorApiBaseUrl`:

```dart
  /// Wordmark rendered by `Wordmark`. Override with
  /// `--dart-define=BRAND_WORDMARK=...` (canvas candidates: FALL LINE,
  /// FIRST CHAIR, VERT, CORDUROY, GOOFYRIDER).
  static const String brandWordmark = String.fromEnvironment(
    'BRAND_WORDMARK',
    defaultValue: 'GOOFYRIDER',
  );
```

- [ ] **Step 4: Write the failing token test**

`test/unit/app_tokens_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/app/theme/app_theme.dart';

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
```

- [ ] **Step 5: Run it to verify it fails**

Run: `flutter test test/unit/app_tokens_test.dart`
Expected: compile error (`AppTokens` undefined).

- [ ] **Step 6: Create `lib/app/theme/app_tokens.dart`**

```dart
import 'package:flutter/material.dart';

class AppFonts {
  AppFonts._();
  static const String archivo = 'Archivo';
  static const String mono = 'JetBrainsMono';
}

/// Semantic colours from the Fall Line canvas. Screens read these via
/// `context.tokens` instead of hardcoding colours.
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.bg,
    required this.canvas,
    required this.surface,
    required this.raised,
    required this.line,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textFaint,
    required this.volt,
    required this.voltText,
    required this.voltInk,
    required this.ice,
    required this.iceBar,
    required this.rec,
    required this.idle,
    required this.idleSwatch,
    required this.mapBg,
    required this.mapGlow,
    required this.barBg,
  });

  final Color bg;
  final Color canvas;
  final Color surface;
  final Color raised;
  final Color line;
  final Color text;
  final Color textSecondary;
  final Color textMuted;
  final Color textFaint;

  /// Volt for fills (buttons, chips, active puck).
  final Color volt;

  /// Volt for text and strokes (darker in light mode).
  final Color voltText;

  /// Text colour on top of a volt fill.
  final Color voltInk;
  final Color ice;
  final Color iceBar;
  final Color rec;
  final Color idle;
  final Color idleSwatch;
  final Color mapBg;
  final Color mapGlow;
  final Color barBg;

  Color get descent => volt;
  Color get lift => iceBar;
  Color get idleSegment => idleSwatch;

  static const AppTokens dark = AppTokens(
    bg: Color(0xFF0C0F12),
    canvas: Color(0xFF07090B),
    surface: Color(0xFF14181D),
    raised: Color(0xFF1A1F25),
    line: Color(0x12FFFFFF),
    text: Color(0xFFEEF3F6),
    textSecondary: Color(0xFF93A1AD),
    textMuted: Color(0xFF5E6B76),
    textFaint: Color(0xFF3E4750),
    volt: Color(0xFFC6F24E),
    voltText: Color(0xFFC6F24E),
    voltInk: Color(0xFF0C0F12),
    ice: Color(0xFF6BD3FF),
    iceBar: Color(0xFF6BD3FF),
    rec: Color(0xFFFF5C5C),
    idle: Color(0xFF2A323B),
    idleSwatch: Color(0xFF55616C),
    mapBg: Color(0xFF10151A),
    mapGlow: Color(0xFF1B2632),
    barBg: Color(0xE60A0D10),
  );

  static const AppTokens light = AppTokens(
    bg: Color(0xFFF2F4F1),
    canvas: Color(0xFFF2F4F1),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFF2F4F1),
    line: Color(0x1410161B),
    text: Color(0xFF10161B),
    textSecondary: Color(0xFF5A6873),
    textMuted: Color(0xFF8A96A0),
    textFaint: Color(0xFFB8C0BC),
    volt: Color(0xFFC6F24E),
    voltText: Color(0xFF5E8F0A),
    voltInk: Color(0xFF10161B),
    ice: Color(0xFF1279A8),
    iceBar: Color(0xFF4FB7E8),
    rec: Color(0xFFD93B3B),
    idle: Color(0xFFD5DAD2),
    idleSwatch: Color(0xFFB8C0BC),
    mapBg: Color(0xFFE8EDEA),
    mapGlow: Color(0xFFFFFFFF),
    barBg: Color(0xEBFFFFFF),
  );

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) {
      return this;
    }
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppTokens(
      bg: mix(bg, other.bg),
      canvas: mix(canvas, other.canvas),
      surface: mix(surface, other.surface),
      raised: mix(raised, other.raised),
      line: mix(line, other.line),
      text: mix(text, other.text),
      textSecondary: mix(textSecondary, other.textSecondary),
      textMuted: mix(textMuted, other.textMuted),
      textFaint: mix(textFaint, other.textFaint),
      volt: mix(volt, other.volt),
      voltText: mix(voltText, other.voltText),
      voltInk: mix(voltInk, other.voltInk),
      ice: mix(ice, other.ice),
      iceBar: mix(iceBar, other.iceBar),
      rec: mix(rec, other.rec),
      idle: mix(idle, other.idle),
      idleSwatch: mix(idleSwatch, other.idleSwatch),
      mapBg: mix(mapBg, other.mapBg),
      mapGlow: mix(mapGlow, other.mapGlow),
      barBg: mix(barBg, other.barBg),
    );
  }
}

extension AppTokensContext on BuildContext {
  AppTokens get tokens =>
      Theme.of(this).extension<AppTokens>() ?? AppTokens.dark;
}
```

- [ ] **Step 7: Rewrite `lib/app/theme/app_theme.dart`**

```dart
import 'package:flutter/material.dart';

import 'app_tokens.dart';

export 'app_tokens.dart';

class AppTheme {
  AppTheme._();

  static ThemeData dark() => _build(AppTokens.dark, Brightness.dark);

  static ThemeData light() => _build(AppTokens.light, Brightness.light);

  static ThemeData _build(AppTokens t, Brightness brightness) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: t.volt,
      onPrimary: t.voltInk,
      secondary: t.ice,
      onSecondary: t.voltInk,
      error: t.rec,
      onError: t.text,
      surface: t.surface,
      onSurface: t.text,
      outline: t.line,
      surfaceContainerHighest: t.raised,
      onSurfaceVariant: t.textSecondary,
    );

    final archivo = TextStyle(fontFamily: AppFonts.archivo, color: t.text);
    final mono = TextStyle(fontFamily: AppFonts.mono, color: t.textSecondary);
    final textTheme = TextTheme(
      displayLarge: archivo.copyWith(
          fontSize: 68, fontWeight: FontWeight.w800, letterSpacing: -2, height: 0.95),
      displayMedium: archivo.copyWith(
          fontSize: 58, fontWeight: FontWeight.w800, letterSpacing: -1.7, height: 0.95),
      displaySmall: archivo.copyWith(
          fontSize: 40, fontWeight: FontWeight.w800, fontStyle: FontStyle.italic, letterSpacing: -0.4),
      headlineLarge: archivo.copyWith(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.7),
      headlineMedium: archivo.copyWith(fontSize: 24, fontWeight: FontWeight.w700),
      headlineSmall: archivo.copyWith(
          fontSize: 22, fontWeight: FontWeight.w800, fontStyle: FontStyle.italic),
      titleLarge: archivo.copyWith(fontSize: 20, fontWeight: FontWeight.w800),
      titleMedium: archivo.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
      titleSmall: archivo.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
      bodyLarge: archivo.copyWith(fontSize: 15, fontWeight: FontWeight.w400, height: 1.5),
      bodyMedium: archivo.copyWith(fontSize: 13, fontWeight: FontWeight.w400, height: 1.5),
      bodySmall: archivo.copyWith(fontSize: 11, fontWeight: FontWeight.w400, color: t.textMuted),
      labelLarge: mono.copyWith(
          fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: t.text),
      labelMedium: mono.copyWith(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1.4),
      labelSmall: mono.copyWith(
          fontSize: 8, fontWeight: FontWeight.w600, letterSpacing: 1.1, color: t.textMuted),
    );

    final shape14 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    OutlineInputBorder inputBorder(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color),
        );
    final fieldLabel = mono.copyWith(
        fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.7, color: t.textMuted);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: AppFonts.archivo,
      textTheme: textTheme,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      dividerColor: t.line,
      extensions: <ThemeExtension<dynamic>>[t],
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: t.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.headlineSmall,
      ),
      cardTheme: CardThemeData(
        color: t.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: t.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surface,
        hintStyle: fieldLabel,
        labelStyle: fieldLabel,
        floatingLabelStyle: fieldLabel.copyWith(color: t.voltText),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: inputBorder(t.line),
        enabledBorder: inputBorder(t.line),
        focusedBorder: inputBorder(t.voltText),
        errorBorder: inputBorder(t.rec),
        focusedErrorBorder: inputBorder(t.rec),
        errorStyle: archivo.copyWith(fontSize: 11, color: t.rec),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.volt,
          foregroundColor: t.voltInk,
          disabledBackgroundColor: t.raised,
          disabledForegroundColor: t.textMuted,
          minimumSize: const Size.fromHeight(52),
          shape: shape14,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.text,
          disabledForegroundColor: t.textMuted,
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: t.text.withValues(alpha: 0.16)),
          shape: shape14,
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.textSecondary,
          textStyle: textTheme.labelLarge?.copyWith(fontSize: 11),
        ),
      ),
      iconTheme: IconThemeData(color: t.textSecondary, size: 20),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.raised,
        contentTextStyle: textTheme.bodyMedium,
        actionTextColor: t.voltText,
        shape: shape14,
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.raised,
        textStyle: textTheme.bodyMedium,
        shape: shape14,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: t.volt),
      listTileTheme: ListTileThemeData(textColor: t.text, iconColor: t.textSecondary),
      chipTheme: ChipThemeData(
        backgroundColor: t.raised,
        selectedColor: t.volt,
        side: BorderSide(color: t.line),
        labelStyle: textTheme.labelMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.raised,
        foregroundColor: t.text,
        shape: const CircleBorder(),
      ),
    );
  }
}
```

- [ ] **Step 8: Switch theme mode to system**

In `lib/main.dart` change both `themeMode: ThemeMode.dark,` lines (in `BootstrapErrorApp.build` and `_GoofyRiderAppState.build`) to `themeMode: ThemeMode.system,`.

- [ ] **Step 9: Run tests and analyzer**

Run: `flutter pub get && flutter test test/unit/app_tokens_test.dart && flutter analyze`
Expected: 3 tests pass, analyzer clean (`AppPalette` had no users outside the old theme file).

- [ ] **Step 10: Commit**

```bash
cd goofyrider && git add mobile/assets/fonts mobile/pubspec.yaml mobile/lib/app/theme mobile/lib/core/constants/app_constants.dart mobile/lib/main.dart mobile/test/unit/app_tokens_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): add Fall Line design tokens, theme and bundled fonts

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 2: Shared design widgets and restyled state views

**Files:**
- Create: `lib/core/widgets/design_widgets.dart`
- Modify: `lib/core/widgets/app_empty_view.dart`, `app_error_view.dart`, `app_loading_view.dart`
- Test: `test/widget/design_widgets_test.dart`

**Interfaces:**
- Consumes: `context.tokens`, `AppFonts`, `AppConstants.brandWordmark`.
- Produces (all in `design_widgets.dart`):
  - `enum MonoTone { primary, secondary, muted, faint, volt, ice, rec }`
  - `MonoLabel(String text, {double size = 9, MonoTone tone = MonoTone.secondary, double letterSpacing = 1.4, FontWeight weight = FontWeight.w600, bool uppercase = true, TextAlign? textAlign, int? maxLines})`
  - `enum StatSize { hero, large, medium, small }`
  - `StatBlock({required String value, required String label, StatSize size = StatSize.medium, MonoTone labelTone = MonoTone.muted, Color? valueColor, CrossAxisAlignment alignment = CrossAxisAlignment.start})`
  - `SurfaceCard({required Widget child, EdgeInsetsGeometry padding = const EdgeInsets.all(16), double radius = 18, bool voltBorder = false, VoidCallback? onTap})`
  - `enum PillVariant { rec, volt, ice, ghost, muted }`
  - `StatusPill(String text, {PillVariant variant = PillVariant.ghost, Widget? leading})`
  - `VoltButton({required String label, VoidCallback? onPressed, bool busy = false})`
  - `GhostButton({required String label, VoidCallback? onPressed})`
  - `Wordmark({double size = 16})`
  - `SegmentSwatch({required SessionActivityType type, double size = 8})`
  - `InitialsAvatar({required String name, double size = 32, bool ring = false})`
  - `PillToggle<T>({required List<(T, String)> options, required T selected, required ValueChanged<T> onChanged})`
  - `Color segmentColor(AppTokens tokens, SessionActivityType type)`
  - `String initialsFor(String name)`

- [ ] **Step 1: Write the failing widget test**

`test/widget/design_widgets_test.dart`:

```dart
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/widget/design_widgets_test.dart`
Expected: compile error, `design_widgets.dart` missing.

- [ ] **Step 3: Create `lib/core/widgets/design_widgets.dart`**

```dart
import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../features/session/domain/session_models.dart';
import '../constants/app_constants.dart';

enum MonoTone { primary, secondary, muted, faint, volt, ice, rec }

Color _toneColor(AppTokens t, MonoTone tone) {
  switch (tone) {
    case MonoTone.primary:
      return t.text;
    case MonoTone.secondary:
      return t.textSecondary;
    case MonoTone.muted:
      return t.textMuted;
    case MonoTone.faint:
      return t.textFaint;
    case MonoTone.volt:
      return t.voltText;
    case MonoTone.ice:
      return t.ice;
    case MonoTone.rec:
      return t.rec;
  }
}

/// Uppercase JetBrains Mono caption used for every telemetry label.
class MonoLabel extends StatelessWidget {
  const MonoLabel(
    this.text, {
    super.key,
    this.size = 9,
    this.tone = MonoTone.secondary,
    this.letterSpacing = 1.4,
    this.weight = FontWeight.w600,
    this.uppercase = true,
    this.textAlign,
    this.maxLines,
    this.color,
  });

  final String text;
  final double size;
  final MonoTone tone;
  final double letterSpacing;
  final FontWeight weight;
  final bool uppercase;
  final TextAlign? textAlign;
  final int? maxLines;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      uppercase ? text.toUpperCase() : text,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: AppFonts.mono,
        fontSize: size,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color ?? _toneColor(context.tokens, tone),
        height: 1.2,
      ),
    );
  }
}

enum StatSize { hero, large, medium, small }

/// Archivo number with a mono caption beneath it.
class StatBlock extends StatelessWidget {
  const StatBlock({
    super.key,
    required this.value,
    required this.label,
    this.size = StatSize.medium,
    this.labelTone = MonoTone.muted,
    this.valueColor,
    this.alignment = CrossAxisAlignment.start,
  });

  final String value;
  final String label;
  final StatSize size;
  final MonoTone labelTone;
  final Color? valueColor;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (double fontSize, FontWeight weight, double spacing, double gap) =
        switch (size) {
      StatSize.hero => (68, FontWeight.w800, -2.0, 8),
      StatSize.large => (24, FontWeight.w700, -0.3, 3),
      StatSize.medium => (18, FontWeight.w700, 0, 2),
      StatSize.small => (15, FontWeight.w700, 0, 2),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: <Widget>[
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: AppFonts.archivo,
            fontSize: fontSize,
            fontWeight: weight,
            letterSpacing: spacing,
            height: 1,
            color: valueColor ?? t.text,
          ),
        ),
        SizedBox(height: gap),
        MonoLabel(label, size: 8, tone: labelTone),
      ],
    );
  }
}

/// Surface-coloured card with a hairline border.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
    this.voltBorder = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool voltBorder;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: voltBorder ? t.voltText.withValues(alpha: 0.35) : t.line,
        ),
      ),
      child: child,
    );
    if (onTap == null) {
      return card;
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: card,
      ),
    );
  }
}

enum PillVariant { rec, volt, ice, ghost, muted }

/// Small rounded status chip (REC, DESCENT, GPS, SYNCED...).
class StatusPill extends StatelessWidget {
  const StatusPill(
    this.text, {
    super.key,
    this.variant = PillVariant.ghost,
    this.leading,
  });

  final String text;
  final PillVariant variant;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (Color fg, Color bg, Color border) = switch (variant) {
      PillVariant.rec => (t.rec, t.bg.withValues(alpha: 0.85), t.rec.withValues(alpha: 0.5)),
      PillVariant.volt => (t.voltInk, t.volt, t.volt),
      PillVariant.ice => (t.ice, Colors.transparent, t.ice.withValues(alpha: 0.35)),
      PillVariant.ghost => (t.text, t.bg.withValues(alpha: 0.85), t.text.withValues(alpha: 0.12)),
      PillVariant.muted => (t.textSecondary, Colors.transparent, t.line),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: 6)],
          MonoLabel(text, size: 9, weight: FontWeight.w700, letterSpacing: 1.1, color: fg),
        ],
      ),
    );
  }
}

/// Primary volt action.
class VoltButton extends StatelessWidget {
  const VoltButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.voltInk),
            )
          : Text(label.toUpperCase()),
    );
  }
}

/// Secondary hairline action.
class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      child: Text(label.toUpperCase()),
    );
  }
}

/// Brand wordmark: italic 800 Archivo with a volt period.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Text.rich(
      TextSpan(
        text: AppConstants.brandWordmark,
        style: TextStyle(
          fontFamily: AppFonts.archivo,
          fontSize: size,
          fontWeight: FontWeight.w800,
          fontStyle: FontStyle.italic,
          letterSpacing: size >= 40 ? -0.4 : 0.16,
          height: 1,
          color: t.text,
        ),
        children: <InlineSpan>[
          TextSpan(text: '.', style: TextStyle(color: t.voltText)),
        ],
      ),
    );
  }
}

Color segmentColor(AppTokens tokens, SessionActivityType type) {
  switch (type) {
    case SessionActivityType.descent:
      return tokens.descent;
    case SessionActivityType.lift:
      return tokens.lift;
    case SessionActivityType.idle:
      return tokens.idleSegment;
  }
}

/// 8x8 rounded square coloured by activity type.
class SegmentSwatch extends StatelessWidget {
  const SegmentSwatch({super.key, required this.type, this.size = 8});

  final SessionActivityType type;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: segmentColor(context.tokens, type),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

String initialsFor(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
  if (parts.isEmpty) {
    return '?';
  }
  final letters = parts.take(2).map((String p) => p[0].toUpperCase()).join();
  return letters;
}

/// Circle avatar with initials, optional volt ring.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    required this.name,
    this.size = 32,
    this.ring = false,
  });

  final String name;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ring ? t.surface : t.raised,
        shape: BoxShape.circle,
        border: Border.all(color: ring ? t.voltText : t.line, width: ring ? 2 : 1),
      ),
      child: Text(
        initialsFor(name),
        style: TextStyle(
          fontFamily: ring ? AppFonts.archivo : AppFonts.mono,
          fontSize: size * (ring ? 0.32 : 0.34),
          fontWeight: ring ? FontWeight.w800 : FontWeight.w700,
          color: t.voltText,
        ),
      ),
    );
  }
}

/// Row of small mono pills where exactly one is selected (units, MAP/HUD).
class PillToggle<T> extends StatelessWidget {
  const PillToggle({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final (T value, String label) in options)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: InkWell(
              onTap: () => onChanged(value),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: value == selected ? t.volt : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: value == selected ? t.volt : t.text.withValues(alpha: 0.12),
                  ),
                ),
                child: MonoLabel(
                  label,
                  size: 9,
                  weight: FontWeight.w700,
                  letterSpacing: 0.7,
                  color: value == selected ? t.voltInk : t.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 4: Restyle the three state views**

`lib/core/widgets/app_empty_view.dart`:

```dart
import 'package:flutter/material.dart';

import 'design_widgets.dart';

class AppEmptyView extends StatelessWidget {
  const AppEmptyView({super.key, required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            MonoLabel(subtitle, size: 9, uppercase: false, letterSpacing: 0.4, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
```

`lib/core/widgets/app_error_view.dart`:

```dart
import 'package:flutter/material.dart';

import 'design_widgets.dart';

class AppErrorView extends StatelessWidget {
  const AppErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 16),
              VoltButton(label: 'Retry', onPressed: onRetry),
            ],
          ],
        ),
      ),
    );
  }
}
```

Note: `app_bootstrap_test.dart` asserts `find.widgetWithText(FilledButton, 'Retry')`. `VoltButton` uppercases to `RETRY`, so change that test's two occurrences to `find.widgetWithText(FilledButton, 'RETRY')`.

`lib/core/widgets/app_loading_view.dart`:

```dart
import 'package:flutter/material.dart';

import 'design_widgets.dart';

class AppLoadingView extends StatelessWidget {
  const AppLoadingView({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          if (label != null) ...<Widget>[
            const SizedBox(height: 14),
            MonoLabel(label!, size: 9, tone: MonoTone.muted),
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: Run tests**

Run: `flutter test test/widget/design_widgets_test.dart test/widget/app_bootstrap_test.dart && flutter analyze`
Expected: all pass, analyzer clean.

- [ ] **Step 6: Commit**

```bash
cd goofyrider && git add mobile/lib/core/widgets mobile/test/widget/design_widgets_test.dart mobile/test/widget/app_bootstrap_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): add shared Fall Line design widgets

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 3: Tab bar and shell

**Files:**
- Create: `lib/app/shell/app_tab_bar.dart`
- Modify: `lib/app/shell/app_shell.dart` (rewrite)
- Test: `test/widget/app_tab_bar_test.dart`

**Interfaces:**
- Produces: `AppTabBar({required int selectedIndex, required ValueChanged<int> onSelected})` with `static const double height = 82` and `static const List<String> labels = ['HOME', 'RESORTS', 'RECORD', 'SEASONS', 'PROFILE']`. Screens use `AppTabBar.height` as bottom padding when they scroll under the bar.

- [ ] **Step 1: Write the failing test**

`test/widget/app_tab_bar_test.dart`:

```dart
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/widget/app_tab_bar_test.dart`
Expected: compile error, `app_tab_bar.dart` missing.

- [ ] **Step 3: Create `lib/app/shell/app_tab_bar.dart`**

```dart
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/widgets/design_widgets.dart';
import '../theme/app_theme.dart';

/// Canvas TabBar: translucent bar, hairline top, volt record puck, volt dot
/// under the active tab.
class AppTabBar extends StatelessWidget {
  const AppTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  static const double height = 82;
  static const List<String> labels = <String>['HOME', 'RESORTS', 'RECORD', 'SEASONS', 'PROFILE'];
  static const List<IconData> _icons = <IconData>[
    Icons.home_outlined,
    Icons.landscape_outlined,
    Icons.circle,
    Icons.schedule_outlined,
    Icons.person_outline,
  ];

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          height: height + bottomInset,
          padding: EdgeInsets.fromLTRB(6, 10, 6, 12 + bottomInset),
          decoration: BoxDecoration(
            color: t.barBg,
            border: Border(top: BorderSide(color: t.line)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List<Widget>.generate(labels.length, (int index) {
              return Expanded(child: _item(context, index));
            }),
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int index) {
    final t = context.tokens;
    final active = index == selectedIndex;
    final color = active ? t.text : t.textMuted;
    final Widget glyph;
    if (index == 2) {
      glyph = Container(
        key: const ValueKey<String>('tab-record-puck'),
        width: 52,
        height: 52,
        alignment: Alignment.center,
        transform: Matrix4.translationValues(0, -22, 0),
        decoration: BoxDecoration(
          color: t.volt,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(color: t.volt.withValues(alpha: 0.35), blurRadius: 22, offset: const Offset(0, 8)),
            BoxShadow(color: t.barBg, spreadRadius: 5),
          ],
        ),
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: t.voltInk, shape: BoxShape.circle),
        ),
      );
    } else {
      glyph = Icon(_icons[index], size: 22, color: color);
    }
    return Semantics(
      button: true,
      selected: active,
      label: labels[index],
      child: InkWell(
        onTap: () => onSelected(index),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            SizedBox(height: index == 2 ? 30 : 22, child: OverflowBox(maxHeight: 60, child: glyph)),
            const SizedBox(height: 5),
            MonoLabel(labels[index], size: 8, weight: FontWeight.w600, color: color),
            const SizedBox(height: 5),
            Container(
              key: ValueKey<String>('tab-dot-$index'),
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: active ? t.volt : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Rewrite `lib/app/shell/app_shell.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'app_tab_bar.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: AppTabBar(
        selectedIndex: navigationShell.currentIndex,
        onSelected: (int index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Run tests**

Run: `flutter test test/widget/app_tab_bar_test.dart && flutter analyze`
Expected: 2 pass, analyzer clean.

- [ ] **Step 6: Commit**

```bash
cd goofyrider && git add mobile/lib/app/shell/app_tab_bar.dart mobile/lib/app/shell/app_shell.dart mobile/test/widget/app_tab_bar_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): replace NavigationBar with Fall Line tab bar

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 4: Season summary helper

**Files:**
- Create: `lib/features/session/presentation/season_summary.dart`
- Test: `test/unit/season_summary_test.dart`

**Interfaces:**
- Consumes: `LocalRideSession`, `seasonLabelForDate` from `history_view_models.dart`.
- Produces: `class SeasonSummary { final String label; final int daysRidden; final int sessionCount; final double totalVertM; final double topSpeedMps; final double totalDistanceM; final int rideTimeS; }` and `SeasonSummary buildSeasonSummary(List<LocalRideSession> sessions, {required DateTime now})`, `String shortSeasonLabel(String label)` (`'2026/2027'` → `'26/27'`).

- [ ] **Step 1: Write the failing test**

`test/unit/season_summary_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/session/domain/session_models.dart';
import 'package:goofyrider_mobile/features/session/presentation/season_summary.dart';

LocalRideSession _s({
  required int id,
  required DateTime startedAt,
  int? vert = 100,
  double maxMps = 10,
  double distanceM = 1000,
  int activeS = 600,
}) {
  return LocalRideSession(
    localId: id,
    ownerUserId: 'u',
    remoteId: null,
    resortId: 'r',
    startedAt: startedAt,
    endedAt: startedAt,
    activeDurationS: activeS,
    distanceM: distanceM,
    maxSpeedMps: maxMps,
    avgSpeedMps: 5,
    elevationGainM: 0,
    elevationLossM: vert,
    state: LocalSessionState.synced,
    pointCount: 1,
    syncAttemptCount: 0,
    lastSyncError: null,
    createdAt: startedAt,
    updatedAt: startedAt,
  );
}

void main() {
  test('aggregates only sessions in the current season', () {
    final now = DateTime(2027, 1, 15);
    final summary = buildSeasonSummary(<LocalRideSession>[
      _s(id: 1, startedAt: DateTime(2026, 12, 20, 9), vert: 300, maxMps: 12),
      _s(id: 2, startedAt: DateTime(2026, 12, 20, 14), vert: 200, maxMps: 15),
      _s(id: 3, startedAt: DateTime(2027, 1, 3), vert: null, maxMps: 8),
      _s(id: 4, startedAt: DateTime(2026, 3, 1), vert: 999, maxMps: 40),
    ], now: now);

    expect(summary.label, '2026/2027');
    expect(summary.sessionCount, 3);
    expect(summary.daysRidden, 2);
    expect(summary.totalVertM, 500);
    expect(summary.topSpeedMps, 15);
    expect(summary.totalDistanceM, 3000);
    expect(summary.rideTimeS, 1800);
  });

  test('empty history gives zeros', () {
    final summary = buildSeasonSummary(const <LocalRideSession>[], now: DateTime(2026, 9, 10));
    expect(summary.sessionCount, 0);
    expect(summary.daysRidden, 0);
    expect(summary.totalVertM, 0);
  });

  test('shortSeasonLabel trims centuries', () {
    expect(shortSeasonLabel('2026/2027'), '26/27');
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/unit/season_summary_test.dart`
Expected: compile error.

- [ ] **Step 3: Create `lib/features/session/presentation/season_summary.dart`**

```dart
import 'dart:math' as math;

import '../domain/session_models.dart';
import 'history_view_models.dart';

/// Aggregated numbers for the season that contains [now].
class SeasonSummary {
  const SeasonSummary({
    required this.label,
    required this.daysRidden,
    required this.sessionCount,
    required this.totalVertM,
    required this.topSpeedMps,
    required this.totalDistanceM,
    required this.rideTimeS,
  });

  final String label;
  final int daysRidden;
  final int sessionCount;
  final double totalVertM;
  final double topSpeedMps;
  final double totalDistanceM;
  final int rideTimeS;
}

SeasonSummary buildSeasonSummary(
  List<LocalRideSession> sessions, {
  required DateTime now,
}) {
  final label = seasonLabelForDate(now);
  final days = <String>{};
  var count = 0;
  var vert = 0.0;
  var top = 0.0;
  var distance = 0.0;
  var rideTime = 0;
  for (final session in sessions) {
    if (seasonLabelForDate(session.startedAt) != label) {
      continue;
    }
    final local = session.startedAt.toLocal();
    days.add('${local.year}-${local.month}-${local.day}');
    count += 1;
    vert += (session.elevationLossM ?? 0).toDouble();
    top = math.max(top, session.maxSpeedMps);
    distance += session.distanceM;
    rideTime += session.activeDurationS;
  }
  return SeasonSummary(
    label: label,
    daysRidden: days.length,
    sessionCount: count,
    totalVertM: vert,
    topSpeedMps: top,
    totalDistanceM: distance,
    rideTimeS: rideTime,
  );
}

/// `2026/2027` -> `26/27`.
String shortSeasonLabel(String label) {
  final parts = label.split('/');
  if (parts.length != 2) {
    return label;
  }
  String tail(String s) => s.length > 2 ? s.substring(s.length - 2) : s;
  return '${tail(parts[0])}/${tail(parts[1])}';
}
```

- [ ] **Step 4: Run tests, commit**

Run: `flutter test test/unit/season_summary_test.dart`
Expected: 3 pass.

```bash
cd goofyrider && git add mobile/lib/features/session/presentation/season_summary.dart mobile/test/unit/season_summary_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): add season summary aggregation for home and profile

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 5: Location onboarding route

**Files:**
- Create: `lib/features/session/presentation/onboarding/location_onboarding_providers.dart`
- Create: `lib/features/session/presentation/onboarding/location_onboarding_screen.dart`
- Modify: `lib/app/router/route_paths.dart` (add `onboardingLocation`)
- Modify: `lib/app/router/app_router.dart` (route + redirect)
- Modify: `lib/main.dart` (remove `_ensureGpsWarmupPermissionOnce`, load the seen flag)
- Test: `test/widget/location_onboarding_screen_test.dart`

**Interfaces:**
- Consumes: `gpsWarmupPermissionPreferenceProvider`, `locationTrackingRepositoryProvider` (`ensureForegroundPermission()`), `MonoLabel`, `VoltButton`, `context.tokens`.
- Produces: `locationOnboardingSeenProvider` = `StateNotifierProvider<LocationOnboardingSeenController, bool?>` with methods `Future<void> load()` and `Future<void> markSeen()`; `RoutePaths.onboardingLocation = '/onboarding/location'`; `LocationOnboardingScreen()`.

- [ ] **Step 1: Write the failing widget test**

`test/widget/location_onboarding_screen_test.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goofyrider_mobile/app/theme/app_theme.dart';
import 'package:goofyrider_mobile/features/session/data/gps_warmup_permission_preference.dart';
import 'package:goofyrider_mobile/features/session/domain/location_tracking_repository.dart';
import 'package:goofyrider_mobile/features/session/presentation/onboarding/location_onboarding_providers.dart';
import 'package:goofyrider_mobile/features/session/presentation/onboarding/location_onboarding_screen.dart';
import 'package:goofyrider_mobile/features/session/presentation/session_providers.dart';

class _FakePreference extends GpsWarmupPermissionPreference {
  bool marked = false;

  @override
  Future<bool> hasBeenRequested() async => marked;

  @override
  Future<void> markRequested() async {
    marked = true;
  }
}

class _FakeLocationRepository implements LocationTrackingRepository {
  int foregroundRequests = 0;

  @override
  Future<LocationPermissionState> ensureForegroundPermission() async {
    foregroundRequests++;
    return LocationPermissionState.grantedForegroundOnly;
  }

  @override
  Future<LocationPermissionState> checkPermissions() async =>
      LocationPermissionState.denied;

  @override
  Future<LocationPermissionState> ensurePermissions() async =>
      LocationPermissionState.denied;

  @override
  Future<LocationSample?> getCurrentLocationSample() async => null;

  @override
  Stream<LocationSample> get positionStream => const Stream<LocationSample>.empty();

  @override
  Future<void> openLocationSettings() async {}

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> startTracking(LocationStreamConfig config) async {}

  @override
  Future<void> stopTracking() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host({
  required _FakePreference preference,
  required _FakeLocationRepository repository,
}) {
  final router = GoRouter(
    initialLocation: '/onboarding/location',
    routes: <RouteBase>[
      GoRoute(path: '/onboarding/location', builder: (_, __) => const LocationOnboardingScreen()),
      GoRoute(path: '/home', builder: (_, __) => const Scaffold(body: Text('HOME SCREEN'))),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      gpsWarmupPermissionPreferenceProvider.overrideWithValue(preference),
      locationTrackingRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
  );
}

void main() {
  testWidgets('ALLOW LOCATION requests permission, marks seen and goes home',
      (WidgetTester tester) async {
    final preference = _FakePreference();
    final repository = _FakeLocationRepository();
    await tester.pumpWidget(_host(preference: preference, repository: repository));
    await tester.pumpAndSettle();

    expect(find.text('STEP 1 OF 2'), findsOneWidget);
    await tester.tap(find.text('ALLOW LOCATION'));
    await tester.pumpAndSettle();

    expect(repository.foregroundRequests, 1);
    expect(preference.marked, isTrue);
    expect(find.text('HOME SCREEN'), findsOneWidget);
  });

  testWidgets('NOT NOW marks seen without requesting permission',
      (WidgetTester tester) async {
    final preference = _FakePreference();
    final repository = _FakeLocationRepository();
    await tester.pumpWidget(_host(preference: preference, repository: repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('NOT NOW'));
    await tester.pumpAndSettle();

    expect(repository.foregroundRequests, 0);
    expect(preference.marked, isTrue);
    expect(find.text('HOME SCREEN'), findsOneWidget);
  });
}
```

The `_FakeLocationRepository` must implement every abstract member of `LocationTrackingRepository`; copy the member list from `test/widget/record_screen_test.dart`'s `FakeLocationRepository` (it is the authoritative list) and drop the `noSuchMethod` line once the class compiles.

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/widget/location_onboarding_screen_test.dart`
Expected: compile error.

- [ ] **Step 3: Create the provider**

`lib/features/session/presentation/onboarding/location_onboarding_providers.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/gps_warmup_permission_preference.dart';
import '../session_providers.dart';

/// `null` until loaded, then whether the location onboarding step has been
/// shown (it piggybacks on the existing warm-up permission preference).
class LocationOnboardingSeenController extends StateNotifier<bool?> {
  LocationOnboardingSeenController(this._preference) : super(null);

  final GpsWarmupPermissionPreference _preference;

  Future<void> load() async {
    state = await _preference.hasBeenRequested();
  }

  Future<void> markSeen() async {
    await _preference.markRequested();
    state = true;
  }
}

final locationOnboardingSeenProvider =
    StateNotifierProvider<LocationOnboardingSeenController, bool?>(
  (ref) => LocationOnboardingSeenController(
    ref.watch(gpsWarmupPermissionPreferenceProvider),
  ),
);
```

- [ ] **Step 4: Create the screen**

`lib/features/session/presentation/onboarding/location_onboarding_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/route_paths.dart';
import '../../../../app/theme/app_theme.dart';
import '../../../../core/widgets/design_widgets.dart';
import '../session_providers.dart';
import 'location_onboarding_providers.dart';

class LocationOnboardingScreen extends ConsumerStatefulWidget {
  const LocationOnboardingScreen({super.key});

  @override
  ConsumerState<LocationOnboardingScreen> createState() =>
      _LocationOnboardingScreenState();
}

class _LocationOnboardingScreenState
    extends ConsumerState<LocationOnboardingScreen> {
  bool _busy = false;

  Future<void> _finish({required bool requestPermission}) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    if (requestPermission) {
      await ref.read(locationTrackingRepositoryProvider).ensureForegroundPermission();
    }
    await ref.read(locationOnboardingSeenProvider.notifier).markSeen();
    if (mounted) {
      context.go(RoutePaths.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.4, -0.8),
                radius: 1.2,
                colors: <Color>[t.mapGlow, t.mapBg],
              ),
            ),
          ),
          CustomPaint(painter: _LinePainter(t)),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: const EdgeInsets.fromLTRB(28, 60, 28, 28),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[t.bg.withValues(alpha: 0), t.bg],
                  stops: const <double>[0, 0.26],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const MonoLabel('STEP 1 OF 2', size: 9, tone: MonoTone.volt, letterSpacing: 1.8),
                    const SizedBox(height: 12),
                    Text(
                      'YOUR LINE,\nDRAWN LIVE.',
                      style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                            fontStyle: FontStyle.italic,
                            height: 1.05,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Location powers speed, vertical and your route on the mountain. It stays on your device until you choose to sync.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
                    ),
                    const SizedBox(height: 24),
                    VoltButton(
                      label: 'Allow location',
                      busy: _busy,
                      onPressed: () => _finish(requestPermission: true),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _busy ? null : () => _finish(requestPermission: false),
                      child: const Text('NOT NOW'),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Container(width: 18, height: 4, decoration: BoxDecoration(color: t.volt, borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 6),
                        Container(width: 8, height: 4, decoration: BoxDecoration(color: t.idle, borderRadius: BorderRadius.circular(2))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Static volt line with a pulsing-dot look, matching the canvas artwork.
class _LinePainter extends CustomPainter {
  _LinePainter(this.t);

  final AppTokens t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / 390;
    final h = size.height / 844;
    final path = Path()
      ..moveTo(280 * w, 120 * h)
      ..lineTo(226 * w, 200 * h)
      ..lineTo(258 * w, 260 * h)
      ..lineTo(190 * w, 340 * h)
      ..lineTo(220 * w, 390 * h)
      ..lineTo(150 * w, 460 * h);
    canvas.drawPath(
      path,
      Paint()
        ..color = t.volt
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final end = Offset(150 * w, 460 * h);
    canvas.drawCircle(end, 8, Paint()..color = t.volt);
    canvas.drawCircle(end, 18, Paint()..color = t.volt.withValues(alpha: 0.35)..style = PaintingStyle.stroke);
    canvas.drawCircle(end, 30, Paint()..color = t.volt.withValues(alpha: 0.15)..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_LinePainter oldDelegate) => oldDelegate.t != t;
}
```

- [ ] **Step 5: Wire the route and redirect**

`lib/app/router/route_paths.dart`, add after `register`:

```dart
  static const String onboardingLocation = '/onboarding/location';
```

`lib/app/router/app_router.dart`:
1. Add imports `../../features/session/presentation/onboarding/location_onboarding_providers.dart` and `location_onboarding_screen.dart`.
2. In the provider body, after the auth listener, add:
```dart
  ref.listen<bool?>(locationOnboardingSeenProvider, (_, __) => refresh.value++);
```
3. In `redirect`, after the `authenticated && isAuthRoute` check and before `return null;`:
```dart
      final onboardingSeen = ref.read(locationOnboardingSeenProvider);
      final isOnboarding = state.matchedLocation == RoutePaths.onboardingLocation;
      if (authState.status == AuthStatus.authenticated &&
          onboardingSeen == false &&
          !isOnboarding) {
        return RoutePaths.onboardingLocation;
      }
      if (isOnboarding && onboardingSeen != false) {
        return RoutePaths.home;
      }
```
4. Add a top-level route before the shell route:
```dart
      GoRoute(
        path: RoutePaths.onboardingLocation,
        builder: (BuildContext context, GoRouterState state) => const LocationOnboardingScreen(),
      ),
```

`lib/main.dart`:
1. Import `features/session/presentation/onboarding/location_onboarding_providers.dart`.
2. Replace `_bootstrapApp` and delete `_ensureGpsWarmupPermissionOnce`:
```dart
  Future<void> _bootstrapApp() async {
    await ref.read(locationOnboardingSeenProvider.notifier).load();
    await ref.read(authControllerProvider.notifier).bootstrap();
    await ref
        .read(recordingControllerProvider.notifier)
        .onAuthenticatedSessionAvailable();
    await ref.read(gpsWarmupServiceProvider).onAppForeground();
  }
```

- [ ] **Step 6: Run tests**

Run: `flutter test test/widget/location_onboarding_screen_test.dart test/widget/app_bootstrap_test.dart && flutter analyze`
Expected: pass, analyzer clean.

- [ ] **Step 7: Commit**

```bash
cd goofyrider && git add mobile/lib/features/session/presentation/onboarding mobile/lib/app/router mobile/lib/main.dart mobile/test/widget/location_onboarding_screen_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): add one-time location onboarding step

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 6: Login and Register screens (canvas 1i)

**Files:**
- Modify: `lib/features/auth/presentation/login_screen.dart` (rewrite build)
- Modify: `lib/features/auth/presentation/register_screen.dart` (rewrite build)
- Modify: `test/widget/login_screen_test.dart`

**Interfaces:**
- Consumes: `Wordmark`, `MonoLabel`, `VoltButton`, `GhostButton`, `context.tokens`, `authControllerProvider`.

- [ ] **Step 1: Update the login test**

In `test/widget/login_screen_test.dart` change `expect(find.text('GoofyRider'), findsOneWidget);` to `expect(find.textContaining('GOOFYRIDER'), findsOneWidget);` and `await tester.tap(find.text('Log In'));` to `await tester.tap(find.text('LOG IN'));`. Keep the validation expectations.

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/widget/login_screen_test.dart`
Expected: FAIL (`GOOFYRIDER` / `LOG IN` not found).

- [ ] **Step 3: Rewrite the login `build`**

Replace everything from `@override Widget build` to the end of `build` in `login_screen.dart` with:

```dart
  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final t = context.tokens;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const _AuthBackdrop(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 40, 28, 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Wordmark(size: 44),
                        const SizedBox(height: 12),
                        const MonoLabel('Track every line.', size: 10, letterSpacing: 2.4),
                        const SizedBox(height: 44),
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'EMAIL'),
                          validator: (String? value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Email is required.';
                            }
                            if (!value.contains('@')) {
                              return 'Enter a valid email.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'PASSWORD'),
                          validator: (String? value) {
                            if (value == null || value.isEmpty) {
                              return 'Password is required.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 18),
                        if (authState.errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              authState.errorMessage!,
                              style: TextStyle(color: t.rec),
                            ),
                          ),
                        VoltButton(
                          label: 'Log in',
                          busy: authState.isBusy,
                          onPressed: _onLogin,
                        ),
                        const SizedBox(height: 12),
                        GhostButton(
                          label: 'Create account',
                          onPressed: () => context.go(RoutePaths.register),
                        ),
                        const SizedBox(height: 26),
                        Text(
                          'Rides record offline — sign in to sync them.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
```

Add at the bottom of `login_screen.dart` (and import `../../../app/theme/app_theme.dart` and `../../../core/widgets/design_widgets.dart` at the top):

```dart
/// Shared backdrop for auth screens: radial glow plus a dashed volt line.
class _AuthBackdrop extends StatelessWidget {
  const _AuthBackdrop();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -1),
          radius: 1,
          colors: <Color>[t.mapGlow, t.bg],
        ),
      ),
      child: CustomPaint(painter: _DashedLinePainter(t.volt)),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  _DashedLinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / 390;
    final points = <Offset>[
      Offset(60 * w, 40),
      Offset(180 * w, 180),
      Offset(140 * w, 250),
      Offset(250 * w, 330),
    ];
    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < points.length - 1; i++) {
      _dashed(canvas, points[i], points[i + 1], paint);
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 8.0;
    final total = (b - a).distance;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final end = (d + dash).clamp(0, total).toDouble();
      canvas.drawLine(a + dir * d, a + dir * end, paint);
      d += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter oldDelegate) => oldDelegate.color != color;
}
```

Make `_AuthBackdrop` public as `AuthBackdrop` (rename both class names and the constructor) so `register_screen.dart` can import it from `login_screen.dart`.

- [ ] **Step 4: Rewrite the register `build`**

Replace `build` in `register_screen.dart` with the same structure; differences: import `login_screen.dart` for `AuthBackdrop`, the column children are:

```dart
                        const Wordmark(size: 44),
                        const SizedBox(height: 12),
                        const MonoLabel('Create your account', size: 10, letterSpacing: 2.4),
                        const SizedBox(height: 44),
                        TextFormField(
                          controller: _nameController,
                          decoration: const InputDecoration(labelText: 'DISPLAY NAME'),
                          validator: (String? value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Display name is required.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'EMAIL'),
                          validator: (String? value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Email is required.';
                            }
                            if (!value.contains('@')) {
                              return 'Enter a valid email.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'PASSWORD'),
                          validator: (String? value) {
                            if (value == null || value.length < 8) {
                              return 'Use at least 8 characters.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 18),
                        if (authState.errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(authState.errorMessage!, style: TextStyle(color: t.rec)),
                          ),
                        VoltButton(label: 'Create account', busy: authState.isBusy, onPressed: _onRegister),
                        const SizedBox(height: 12),
                        GhostButton(label: 'Back to log in', onPressed: () => context.go(RoutePaths.login)),
```

No `AppBar` on register.

- [ ] **Step 5: Run tests and commit**

Run: `flutter test test/widget/login_screen_test.dart && flutter analyze`
Expected: pass, clean.

```bash
cd goofyrider && git add mobile/lib/features/auth/presentation mobile/test/widget/login_screen_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): restyle login and register to Fall Line

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 7: Home screen (canvas 1a)

**Files:**
- Modify: `lib/app/shell/home_screen.dart` (rewrite)
- Modify: `test/widget/home_screen_test.dart`

**Interfaces:**
- Consumes: `buildSeasonSummary`, `shortSeasonLabel`, `Wordmark`, `InitialsAvatar`, `StatBlock`, `SurfaceCard`, `MonoLabel`, `StatusPill`, `AppTabBar.height`, providers `authControllerProvider`, `distanceUnitPreferenceProvider`, `speedUnitPreferenceProvider`, `favoriteResortsProvider`, `historyProvider`, `unsyncedSessionCountProvider`, `resortWeatherProvider`, `recordingControllerProvider`.
- Keeps the private helpers `_resolveConditionsText` and `_resolveTemperatureText` and the copy `Conditions unavailable`.

- [ ] **Step 1: Update the home tests**

In `test/widget/home_screen_test.dart`:
- Test 1: replace `'Recent sessions'` with `'LAST SESSION'` (use `find.textContaining('LAST SESSION')`) and `'Favorite resorts'` with `find.text('YOUR MOUNTAINS')`; keep the ordering assertion.
- Test 2: keep as is (`toDayLabel` / `toTimeLabel` still rendered in the last-session card meta line).
- Test 4: replace `'Conditions unavailable • -- C'` with `'-- · CONDITIONS UNAVAILABLE'` and `'Powder • -7.0 C'` with `'-7.0°C · POWDER'`.
- Add `speedUnitPreferenceProvider.overrideWith((_) => SpeedUnitPreferenceController())` to every override list (import `core/providers/speed_unit_preference_provider.dart`).

- [ ] **Step 2: Run to verify failures**

Run: `flutter test test/widget/home_screen_test.dart`
Expected: tests 1 and 4 fail.

- [ ] **Step 3: Rewrite `lib/app/shell/home_screen.dart`**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_constants.dart';
import '../../core/providers/distance_unit_preference_provider.dart';
import '../../core/providers/speed_unit_preference_provider.dart';
import '../../core/utils/date_time_formatting.dart';
import '../../core/utils/distance_unit.dart';
import '../../core/utils/duration_formatting.dart';
import '../../core/utils/speed_unit.dart';
import '../../core/widgets/design_widgets.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/resorts/domain/resort_models.dart';
import '../../features/resorts/presentation/resort_providers.dart';
import '../../features/session/domain/session_models.dart';
import '../../features/session/presentation/season_summary.dart';
import '../../features/session/presentation/session_providers.dart';
import '../../features/weather/domain/weather_models.dart';
import '../../features/weather/presentation/weather_providers.dart';
import '../router/route_paths.dart';
import '../shell/app_tab_bar.dart';
import '../theme/app_theme.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final favorites = ref.watch(favoriteResortsProvider);
    final history = ref.watch(historyProvider);
    final unsyncedCount = ref.watch(unsyncedSessionCountProvider);
    final showDebugDiagnostics = kDebugMode && AppConstants.isDebugDiagnostics;
    final t = context.tokens;
    final displayName = authState.session?.user.displayName ?? 'Rider';

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(recordingControllerProvider.notifier).retryPendingSyncs();
          ref.invalidate(favoriteResortsProvider);
          ref.invalidate(historyProvider);
          ref.invalidate(unsyncedSessionCountProvider);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 18, 24, AppTabBar.height + 24),
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Wordmark(size: 16),
                InitialsAvatar(name: displayName),
              ],
            ),
            const SizedBox(height: 26),
            history.when(
              loading: () => const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
              error: (Object error, StackTrace _) => SurfaceCard(child: Text('Unable to load history: $error')),
              data: (List<LocalRideSession> sessions) => _SeasonHero(
                sessions: sessions,
                distanceUnit: distanceUnit,
                speedUnit: speedUnit,
              ),
            ),
            if (showDebugDiagnostics)
              unsyncedCount.when(
                data: (int count) => count <= 0
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: SurfaceCard(
                          voltBorder: true,
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.sync_problem, color: t.voltText),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  '$count session(s) pending sync. Open Seasons to retry any failed uploads.',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
            const SizedBox(height: 26),
            history.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
              data: (List<LocalRideSession> sessions) {
                if (sessions.isEmpty) {
                  return SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const MonoLabel('No sessions yet', size: 8, tone: MonoTone.muted, letterSpacing: 1.8),
                        const SizedBox(height: 10),
                        Text('Ready for your next run?', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 14),
                        VoltButton(label: 'Start recording', onPressed: () => context.go(RoutePaths.record)),
                      ],
                    ),
                  );
                }
                final latest = sessions.reduce(
                  (LocalRideSession a, LocalRideSession b) => a.startedAt.isAfter(b.startedAt) ? a : b,
                );
                return _LastSessionCard(session: latest, distanceUnit: distanceUnit, speedUnit: speedUnit);
              },
            ),
            const SizedBox(height: 26),
            const MonoLabel('Your mountains', size: 9, letterSpacing: 1.8),
            const SizedBox(height: 12),
            favorites.when(
              loading: () => const SizedBox(height: 110, child: Center(child: CircularProgressIndicator())),
              error: (Object error, StackTrace _) => SurfaceCard(child: Text('Unable to load favorites: $error')),
              data: (List<ResortSummary> resorts) {
                if (resorts.isEmpty) {
                  return SurfaceCard(
                    child: Text(
                      'No favorites yet. Add some from the Resorts tab.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
                    ),
                  );
                }
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    for (final ResortSummary resort in resorts)
                      SizedBox(
                        width: (MediaQuery.sizeOf(context).width - 48 - 12) / 2,
                        child: _FavoriteResortCard(resort: resort),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SeasonHero extends StatelessWidget {
  const _SeasonHero({required this.sessions, required this.distanceUnit, required this.speedUnit});

  final List<LocalRideSession> sessions;
  final DistanceUnit distanceUnit;
  final SpeedUnit speedUnit;

  @override
  Widget build(BuildContext context) {
    final summary = buildSeasonSummary(sessions, now: DateTime.now());
    final vert = summary.totalVertM > 0 ? distanceUnit.convertFromMeters(summary.totalVertM).round().toString() : '--';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MonoLabel('Season ${shortSeasonLabel(summary.label)} · ${summary.daysRidden} days ridden', size: 9, letterSpacing: 1.8),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text(vert, style: Theme.of(context).textTheme.displayLarge),
            const SizedBox(width: 10),
            MonoLabel('${distanceUnit.shortLabel} vert', size: 10, tone: MonoTone.volt, letterSpacing: 1.6),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 26,
          runSpacing: 14,
          children: <Widget>[
            StatBlock(value: speedUnit.convertFromMetersPerSecond(summary.topSpeedMps).toStringAsFixed(1), label: 'Top ${speedUnit.shortLabel}', size: StatSize.small),
            StatBlock(value: _kilometers(summary.totalDistanceM, distanceUnit), label: _distanceLabel(distanceUnit), size: StatSize.small),
            StatBlock(value: '${summary.sessionCount}', label: 'Sessions', size: StatSize.small),
            StatBlock(value: formatSecondsAsDuration(summary.rideTimeS), label: 'Ride time', size: StatSize.small),
          ],
        ),
      ],
    );
  }
}

String _kilometers(double meters, DistanceUnit unit) {
  if (unit == DistanceUnit.feet) {
    return (meters / 1609.344).toStringAsFixed(1);
  }
  return (meters / 1000).toStringAsFixed(1);
}

String _distanceLabel(DistanceUnit unit) => unit == DistanceUnit.feet ? 'MI dist' : 'KM dist';

class _LastSessionCard extends ConsumerWidget {
  const _LastSessionCard({required this.session, required this.distanceUnit, required this.speedUnit});

  final LocalRideSession session;
  final DistanceUnit distanceUnit;
  final SpeedUnit speedUnit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final synced = session.state == LocalSessionState.synced;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      onTap: session.localId > 0
          ? () => context.go(RoutePaths.sessionDetail.replaceAll(':sessionId', session.localId.toString()))
          : null,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                MonoLabel('Last session · ${session.startedAt.toDayLabel()}', size: 8, tone: MonoTone.muted, letterSpacing: 1.8),
                const SizedBox(height: 5),
                Text(session.resortId ?? 'Unknown resort', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18)),
                const SizedBox(height: 5),
                MonoLabel(
                  '${session.startedAt.toTimeLabel()} · ${formatSecondsAsDuration(session.activeDurationS)} ride · ${distanceUnit.formatFromMeters(session.distanceM)} · ${speedUnit.formatFromMetersPerSecond(session.maxSpeedMps)} max',
                  size: 9,
                  letterSpacing: 0.8,
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          StatusPill(synced ? '● Synced' : '○ Local only', variant: synced ? PillVariant.ice : PillVariant.muted),
        ],
      ),
    );
  }
}

class _FavoriteResortCard extends ConsumerWidget {
  const _FavoriteResortCard({required this.resort});

  final ResortSummary resort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weather = ref.watch(resortWeatherProvider(resort.id));
    final t = context.tokens;
    final conditions = _resolveConditionsText(weather, resort);
    final temp = _resolveTemperatureText(weather, resort);
    final snow = weather.valueOrNull?.snowfallCm24h;
    final powDay = snow != null && snow >= 10;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      onTap: () => context.go(RoutePaths.resortDetail.replaceAll(':resortId', resort.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(resort.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          MonoLabel('$temp · $conditions', size: 9, letterSpacing: 0.6, maxLines: 1),
          if (snow != null) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: powDay ? t.volt : t.raised,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: powDay ? t.volt : t.line),
              ),
              child: MonoLabel(
                '${snow.round()} cm · ${powDay ? 'Pow day' : '24h'}',
                size: 9,
                weight: FontWeight.w700,
                letterSpacing: 1,
                color: powDay ? t.voltInk : t.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _resolveConditionsText(AsyncValue<ResortWeather?> weather, ResortSummary resort) {
  final liveText = weather.valueOrNull?.conditionsText;
  if (liveText != null && liveText.trim().isNotEmpty) {
    return liveText;
  }
  final cachedText = resort.cachedWeatherText;
  if (cachedText != null && cachedText.trim().isNotEmpty) {
    return cachedText;
  }
  return 'Conditions unavailable';
}

String _resolveTemperatureText(AsyncValue<ResortWeather?> weather, ResortSummary resort) {
  final liveTemp = weather.valueOrNull?.tempC;
  if (liveTemp != null) {
    return '${liveTemp.toStringAsFixed(1)}°C';
  }
  final cachedTemp = resort.cachedWeatherTempC;
  if (cachedTemp != null) {
    return '${cachedTemp.toStringAsFixed(1)}°C';
  }
  return '--';
}
```

Note the favourite card test expects `'-- · CONDITIONS UNAVAILABLE'` then `'-7.0°C · POWDER'` (MonoLabel uppercases).

- [ ] **Step 4: Run tests and commit**

Run: `flutter test test/widget/home_screen_test.dart && flutter analyze`
Expected: 4 pass, clean.

```bash
cd goofyrider && git add mobile/lib/app/shell/home_screen.dart mobile/test/widget/home_screen_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): restyle home to Fall Line season hero

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 8: Resorts list and resort detail (canvas 1f, 1g)

**Files:**
- Modify: `lib/features/resorts/presentation/resorts_list_screen.dart` (rewrite build)
- Modify: `lib/features/resorts/presentation/resort_detail_screen.dart` (rewrite)
- Modify: `test/widget/resorts_list_screen_test.dart`, `test/widget/resort_detail_screen_test.dart`

**Interfaces:**
- Consumes: `MonoLabel`, `SurfaceCard`, `StatBlock`, `VoltButton`, `AppTabBar.height`, `context.tokens`, `MapAttribution`, providers `resortsControllerProvider`, `resortDetailControllerProvider`, `resortDetailToggleInFlightProvider`, `resortWeatherProvider`, `activeMapTileProviderConfigProvider`.

- [ ] **Step 1: Update the resorts tests**

`resorts_list_screen_test.dart`:
- Test 2: replace `expect(find.byType(ListTile), findsWidgets);` with `expect(find.text('BRITISH COLUMBIA, CANADA'), findsOneWidget);`.
- Test 3: rename to `'resorts screen uses volt favorite icon for favorite resort'`, wrap the app in `MaterialApp(theme: AppTheme.dark(), home: ...)`, and assert `expect(favoriteIcon.color, AppTokens.dark.voltText);` (import `app/theme/app_theme.dart`).

`resort_detail_screen_test.dart`:
- Wrap `MaterialApp` with `theme: AppTheme.dark()`.
- Test 1: assert `expect(icon.color, AppTokens.dark.voltText);`.
- Test 3: replace the `'BC, Canada'`, `'Whistler'`, `'Elevation'` expectations with `expect(find.text('BC, CANADA · WHISTLER'), findsOneWidget);`, `expect(find.text('SKIABLE VERT'), findsNothing);` removed, and `expect(find.textContaining('SKIABLE VERT'), findsOneWidget);`; replace `'Start recording here'` with `'START RECORDING HERE'`.

- [ ] **Step 2: Run to verify failures**

Run: `flutter test test/widget/resorts_list_screen_test.dart test/widget/resort_detail_screen_test.dart`
Expected: FAIL on new strings/colours.

- [ ] **Step 3: Rewrite the list screen `build`**

Replace `build` in `resorts_list_screen.dart` (add imports for `app_theme.dart`, `design_widgets.dart`, `app_tab_bar.dart`):

```dart
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(resortsControllerProvider);
    final t = context.tokens;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
              child: Text('RESORTS', style: Theme.of(context).textTheme.headlineSmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
              child: TextField(
                controller: _searchController,
                onChanged: (String value) {
                  _debouncer.run(() => ref.read(resortsControllerProvider.notifier).search(value));
                },
                decoration: InputDecoration(
                  hintText: 'Search resorts…',
                  prefixIcon: Icon(Icons.search, size: 18, color: t.textMuted),
                ),
              ),
            ),
            Expanded(
              child: state.when(
                loading: () => const AppLoadingView(label: 'Loading resorts...'),
                error: (Object error, StackTrace _) => AppErrorView(
                  message: error.toString(),
                  onRetry: () => ref.read(resortsControllerProvider.notifier).refresh(),
                ),
                data: (ResortListResult result) {
                  if (result.items.isEmpty) {
                    return AppEmptyView(
                      title: 'No resorts found',
                      subtitle: result.usedCache ? 'Offline cache is empty. Connect and retry.' : 'Try adjusting your search.',
                    );
                  }
                  final hasFavorite = result.items.any((ResortSummary r) => r.isFavorite);
                  return RefreshIndicator(
                    onRefresh: () => ref.read(resortsControllerProvider.notifier).refresh(),
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(24, 8, 24, AppTabBar.height + 24),
                      itemCount: result.items.length + 1,
                      itemBuilder: (BuildContext context, int index) {
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
                            child: MonoLabel(hasFavorite ? 'Favorites first' : 'All resorts', size: 8, tone: MonoTone.muted, letterSpacing: 1.8),
                          );
                        }
                        return _ResortRow(resort: result.items[index - 1]);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
```

Add the row widget at the bottom of the file:

```dart
class _ResortRow extends ConsumerWidget {
  const _ResortRow({required this.resort});

  final ResortSummary resort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final weather = resort.cachedWeatherText;
    final temp = resort.cachedWeatherTempC;
    final chip = <String>[
      if (temp != null) '${temp.toStringAsFixed(0)}°',
      if (weather != null && weather.trim().isNotEmpty) weather,
    ].join(' · ');

    return InkWell(
      onTap: () => context.go(RoutePaths.resortDetail.replaceAll(':resortId', resort.id)),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(resort.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  MonoLabel('${resort.region}, ${resort.country}', size: 8, tone: MonoTone.muted, letterSpacing: 1.1, maxLines: 1),
                ],
              ),
            ),
            if (chip.isNotEmpty) ...<Widget>[
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: t.raised, borderRadius: BorderRadius.circular(6)),
                child: MonoLabel(chip, size: 9, weight: FontWeight.w700, letterSpacing: 1, maxLines: 1),
              ),
            ],
            IconButton(
              icon: Icon(
                resort.isFavorite ? Icons.favorite : Icons.favorite_border,
                color: resort.isFavorite ? t.voltText : t.textMuted,
                size: 18,
              ),
              onPressed: () => ref.read(resortsControllerProvider.notifier).toggleFavorite(resort),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Rewrite `resort_detail_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/shell/app_tab_bar.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/providers.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../../../core/widgets/design_widgets.dart';
import '../../../core/widgets/map_attribution.dart';
import '../../weather/domain/weather_models.dart';
import '../../weather/presentation/weather_providers.dart';
import '../domain/resort_models.dart';
import 'resort_providers.dart';

class ResortDetailScreen extends ConsumerWidget {
  const ResortDetailScreen({super.key, required this.resortId});

  final String resortId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resortValue = ref.watch(resortDetailControllerProvider(resortId));
    final isFavoriteToggleInFlight = ref.watch(resortDetailToggleInFlightProvider(resortId));
    final activeMapTileProviderConfig = ref.watch(activeMapTileProviderConfigProvider);
    final t = context.tokens;

    return resortValue.when(
      loading: () => const Scaffold(body: AppLoadingView(label: 'Loading resort...')),
      error: (Object error, StackTrace _) => Scaffold(appBar: AppBar(), body: AppErrorView(message: error.toString())),
      data: (ResortSummary resort) {
        final weather = ref.watch(resortWeatherProvider(resort.id));
        final center = LatLng(resort.latitude ?? 50, resort.longitude ?? -120);
        final height = MediaQuery.sizeOf(context).height;
        final mapHeight = (height * 0.45).clamp(260.0, 400.0).toDouble();
        final base = resort.elevationBaseM;
        final top = resort.elevationTopM;
        final skiable = (base != null && top != null && top > base) ? top - base : null;
        final location = <String>[
          '${resort.region}, ${resort.country}',
          if (resort.city != null && resort.city!.trim().isNotEmpty) resort.city!,
        ].join(' · ');

        return Scaffold(
          body: ListView(
            padding: EdgeInsets.only(bottom: AppTabBar.height + 24),
            children: <Widget>[
              SizedBox(
                height: mapHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    FlutterMap(
                      options: MapOptions(initialCenter: center, initialZoom: 13),
                      children: <Widget>[
                        TileLayer(
                          urlTemplate: activeMapTileProviderConfig.urlTemplate,
                          subdomains: activeMapTileProviderConfig.subdomains,
                          retinaMode: activeMapTileProviderConfig.retinaMode,
                          userAgentPackageName: 'com.goofyrider.mobile',
                        ),
                        MarkerLayer(
                          markers: <Marker>[
                            Marker(
                              point: center,
                              width: 16,
                              height: 16,
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: t.volt, shape: BoxShape.circle, border: Border.all(color: t.bg, width: 2)),
                              ),
                            ),
                          ],
                        ),
                        MapAttribution(config: activeMapTileProviderConfig),
                      ],
                    ),
                    IgnorePointer(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          height: 120,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[t.bg.withValues(alpha: 0), t.bg],
                            ),
                          ),
                        ),
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            _RoundButton(
                              tooltip: 'Back',
                              icon: Icons.arrow_back,
                              onPressed: () {
                                if (context.canPop()) {
                                  context.pop();
                                } else {
                                  context.go(RoutePaths.resorts);
                                }
                              },
                            ),
                            _RoundButton(
                              tooltip: resort.isFavorite ? 'Remove favorite' : 'Add favorite',
                              icon: resort.isFavorite ? Icons.favorite : Icons.favorite_border,
                              iconColor: resort.isFavorite ? t.voltText : t.text,
                              volt: resort.isFavorite,
                              onPressed: isFavoriteToggleInFlight
                                  ? null
                                  : () => ref.read(resortDetailControllerProvider(resortId).notifier).toggleFavorite(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Transform.translate(
                offset: const Offset(0, -46),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(resort.name.toUpperCase(), style: Theme.of(context).textTheme.displaySmall),
                      const SizedBox(height: 4),
                      MonoLabel(location, size: 9, letterSpacing: 1.6),
                      const SizedBox(height: 16),
                      weather.when(
                        loading: () => const _WeatherTiles(temp: '--', conditions: 'Loading', snow: null, wind: null),
                        error: (_, __) => const _WeatherTiles(temp: '--', conditions: 'Unavailable', snow: null, wind: null),
                        data: (ResortWeather? value) => _WeatherTiles(
                          temp: value?.tempC == null ? '--' : '${value!.tempC!.toStringAsFixed(0)}°',
                          conditions: value?.conditionsText ?? 'Unavailable',
                          snow: value?.snowfallCm24h,
                          wind: value?.windKph,
                          stale: value?.stale ?? false,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SurfaceCard(
                        radius: 14,
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                        child: Column(
                          children: <Widget>[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: <Widget>[
                                MonoLabel('Base ${base ?? '--'} m', size: 8, tone: MonoTone.muted),
                                MonoLabel('Top ${top ?? '--'} m', size: 8, tone: MonoTone.muted),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Container(
                              height: 6,
                              decoration: BoxDecoration(color: t.raised, borderRadius: BorderRadius.circular(3)),
                              child: FractionallySizedBox(
                                alignment: Alignment.center,
                                widthFactor: 0.7,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(3),
                                    gradient: LinearGradient(colors: <Color>[t.iceBar, t.volt]),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: MonoLabel('${skiable ?? '--'} m skiable vert', size: 8),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      VoltButton(
                        label: 'Start recording here',
                        onPressed: () => context.go('${RoutePaths.record}?resortId=${Uri.encodeComponent(resort.id)}'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.tooltip, required this.icon, required this.onPressed, this.iconColor, this.volt = false});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? iconColor;
  final bool volt;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: t.bg.withValues(alpha: 0.8),
        shape: BoxShape.circle,
        border: Border.all(color: volt ? t.voltText.withValues(alpha: 0.5) : t.text.withValues(alpha: 0.1)),
      ),
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        iconSize: 16,
        onPressed: onPressed,
        icon: Icon(icon, color: iconColor ?? t.text),
      ),
    );
  }
}

class _WeatherTiles extends StatelessWidget {
  const _WeatherTiles({required this.temp, required this.conditions, required this.snow, required this.wind, this.stale = false});

  final String temp;
  final String conditions;
  final double? snow;
  final double? wind;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget tile(String value, String label, {bool volt = false}) => Expanded(
          child: SurfaceCard(
            radius: 14,
            voltBorder: volt,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: StatBlock(value: value, label: label, valueColor: volt ? t.voltText : null),
          ),
        );
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            tile(temp, conditions),
            const SizedBox(width: 10),
            tile(snow == null ? '--' : '${snow!.toStringAsFixed(0)} cm', 'Snow 24h', volt: (snow ?? 0) > 0),
            const SizedBox(width: 10),
            tile(wind == null ? '--' : wind!.toStringAsFixed(0), 'Wind kph'),
          ],
        ),
        if (stale)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: MonoLabel('Showing stale cached data.', size: 8, tone: MonoTone.muted, uppercase: false),
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 5: Run tests and commit**

Run: `flutter test test/widget/resorts_list_screen_test.dart test/widget/resort_detail_screen_test.dart && flutter analyze`
Expected: pass, clean.

```bash
cd goofyrider && git add mobile/lib/features/resorts/presentation mobile/test/widget/resorts_list_screen_test.dart mobile/test/widget/resort_detail_screen_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): restyle resorts list and detail to Fall Line

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 9: Seasons (history) screen (canvas 1e)

**Files:**
- Modify: `lib/features/session/presentation/history_screen.dart` (rewrite)
- Modify: `test/widget/history_screen_test.dart`

**Interfaces:**
- Consumes: `MonoLabel`, `SurfaceCard`, `shortSeasonLabel`, `AppTabBar.height`, `context.tokens`, providers `historySectionsProvider`, `historyProvider`, `unsyncedSessionCountProvider`, `recordingControllerProvider`, `sessionRepositoryProvider`, `speedUnitPreferenceProvider`, `distanceUnitPreferenceProvider`.

- [ ] **Step 1: Update the history test**

In `history_screen_test.dart` test 1: change `expect(find.text('2025/2026'), findsOneWidget);` to `expect(find.text('25/26'), findsOneWidget);` and `expect(find.textContaining('Pending'), findsOneWidget);` to `expect(find.textContaining('LOCAL ONLY'), findsOneWidget);`. In test 2 change the `Pending` line the same way and leave the `Sync now` tooltip assertion as is (known pre-existing failure; the trailing sync button is still commented out and that is outside this redesign).

- [ ] **Step 2: Rewrite `history_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/shell/app_tab_bar.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/duration_formatting.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/widgets/app_empty_view.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../../../core/widgets/design_widgets.dart';
import '../domain/session_models.dart';
import 'history_view_models.dart';
import 'season_summary.dart';
import 'session_providers.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  Future<void> _runSyncPass(WidgetRef ref) async {
    await ref.read(recordingControllerProvider.notifier).retryPendingSyncs();
    ref.invalidate(historyProvider);
    ref.invalidate(historySectionsProvider);
    ref.invalidate(unsyncedSessionCountProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historySectionsProvider);
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final unsyncedCount = ref.watch(unsyncedSessionCountProvider);
    final t = context.tokens;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text('SEASONS', style: Theme.of(context).textTheme.headlineSmall),
                  unsyncedCount.maybeWhen(
                    data: (int count) => count > 0
                        ? IconButton(
                            tooltip: 'Sync unsynced sessions',
                            onPressed: () async => _runSyncPass(ref),
                            icon: Icon(Icons.sync, color: t.ice),
                          )
                        : const SizedBox.shrink(),
                    orElse: () => const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: history.when(
                loading: () => const AppLoadingView(label: 'Loading sessions...'),
                error: (Object error, StackTrace _) => AppErrorView(
                  message: error.toString(),
                  onRetry: () {
                    ref.invalidate(historyProvider);
                    ref.invalidate(historySectionsProvider);
                  },
                ),
                data: (List<SessionHistorySeasonSection> sections) {
                  final totalSessions = sections.fold<int>(0, (int c, SessionHistorySeasonSection s) => c + s.items.length);
                  if (totalSessions == 0) {
                    return const AppEmptyView(title: 'No sessions yet', subtitle: 'Record your first run to start your logbook.');
                  }
                  return RefreshIndicator(
                    onRefresh: () async => _runSyncPass(ref),
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(24, 8, 24, AppTabBar.height + 24),
                      children: <Widget>[
                        for (final SessionHistorySeasonSection section in sections) ...<Widget>[
                          _SeasonHeader(section: section, distanceUnit: distanceUnit, speedUnit: speedUnit),
                          for (final SessionHistoryEntryViewModel item in section.items)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: _HistorySessionCard(item: item, speedUnit: speedUnit, distanceUnit: distanceUnit),
                            ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader({required this.section, required this.distanceUnit, required this.speedUnit});

  final SessionHistorySeasonSection section;
  final DistanceUnit distanceUnit;
  final SpeedUnit speedUnit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final sessions = section.items.map((SessionHistoryEntryViewModel i) => i.session).toList(growable: false);
    final days = sessions.map((LocalRideSession s) {
      final d = s.startedAt.toLocal();
      return '${d.year}-${d.month}-${d.day}';
    }).toSet().length;
    final vert = sessions.fold<int>(0, (int a, LocalRideSession s) => a + (s.elevationLossM ?? 0));
    final top = sessions.fold<double>(0, (double a, LocalRideSession s) => s.maxSpeedMps > a ? s.maxSpeedMps : a);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(
            shortSeasonLabel(section.label),
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 1.2
                    ..color = t.voltText,
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: MonoLabel(
              '$days days · ${distanceUnit.formatFromMeters(vert.toDouble())} vert · ${speedUnit.formatFromMetersPerSecond(top)} top',
              size: 8,
              tone: MonoTone.muted,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistorySessionCard extends StatelessWidget {
  const _HistorySessionCard({required this.item, required this.speedUnit, required this.distanceUnit});

  final SessionHistoryEntryViewModel item;
  final SpeedUnit speedUnit;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final session = item.session;
    final local = session.startedAt.toLocal();
    final (String syncLabel, Color syncColor) = switch (session.state) {
      LocalSessionState.synced => ('● Synced', t.ice),
      LocalSessionState.syncing => ('◌ Syncing', t.textSecondary),
      LocalSessionState.syncFailed => ('! Failed', t.rec),
      _ => ('○ Local only', t.textSecondary),
    };

    return SurfaceCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      onTap: session.localId > 0
          ? () => context.go(RoutePaths.sessionDetail.replaceAll(':sessionId', session.localId.toString()))
          : null,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Column(
              children: <Widget>[
                Text('${local.day}', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 14)),
                MonoLabel(DateFormat('MMM').format(local), size: 8, tone: MonoTone.muted, letterSpacing: 1),
              ],
            ),
          ),
          Container(width: 1, height: 36, color: t.line),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.resortLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                MonoLabel(
                  '${formatSecondsAsDuration(session.activeDurationS)} · ${distanceUnit.formatFromMeters(session.distanceM)} · ${speedUnit.formatFromMetersPerSecond(session.maxSpeedMps)} max',
                  size: 8,
                  letterSpacing: 0.8,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          MonoLabel(syncLabel, size: 7, weight: FontWeight.w700, letterSpacing: 1.1, color: syncColor),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Run tests and commit**

Run: `flutter test test/widget/history_screen_test.dart && flutter analyze`
Expected: test 1 passes; test 2 fails only on `find.byTooltip('Sync now')` (pre-existing). Analyzer clean.

```bash
cd goofyrider && git add mobile/lib/features/session/presentation/history_screen.dart mobile/test/widget/history_screen_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): restyle history into Fall Line seasons list

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 10: Session detail screen (canvas 1d)

**Files:**
- Modify: `lib/features/session/presentation/session_detail_screen.dart` (rewrite `build` and helpers; keep `_confirmDelete`, `_diagnosticLine`, `_SessionDetailAction`)
- Modify: `test/widget/session_detail_screen_test.dart`

**Interfaces:**
- Consumes: `MonoLabel`, `StatBlock`, `SurfaceCard`, `StatusPill`, `SegmentSwatch`, `segmentColor`, `VoltButton`, `AppTabBar.height`, `context.tokens`, providers `sessionDetailProvider`, `sessionRepositoryProvider`, `historyProvider`, `historySectionsProvider`, `unsyncedSessionCountProvider`, `speedUnitPreferenceProvider`, `distanceUnitPreferenceProvider`, `activeMapTileProviderConfigProvider`.

- [ ] **Step 1: Update the session detail test**

In `session_detail_screen_test.dart` test 1 (`renders segmented ride breakdown`): replace the expectations block with

```dart
    expect(find.text('RIDE'), findsWidgets);
    expect(find.text('LIFT'), findsWidgets);
    expect(find.text('IDLE'), findsWidgets);
    expect(find.textContaining('TIME SPLIT'), findsOneWidget);
    expect(find.text('RUNS'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('TIMELINE'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('TIMELINE'), findsOneWidget);
    expect(find.textContaining('00:02:00'), findsWidgets);
```

Test 2: keep the fallback copy assertion, replace `find.text('Ride time')` with `find.text('RIDE TIME')`.
Test 3: replace `'Retry sync'` with `'RETRY SYNC'` (two places). Tests 4–6 unchanged (tooltip and dialog copy kept).

- [ ] **Step 2: Rewrite `build` and the helper widgets**

Keep the imports; add `../../../app/shell/app_tab_bar.dart`, `../../../app/theme/app_theme.dart`, `../../../core/widgets/design_widgets.dart`. Replace `build`, `_summaryCards`, `_summaryCard`, `_mapReplay`, `_timelineCard`, `_segmentColor` with:

```dart
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sessionDetailProvider(localSessionId));
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final activeMapTileProviderConfig = ref.watch(activeMapTileProviderConfigProvider);
    final showDebugDiagnostics = kDebugMode && AppConstants.isDebugDiagnostics;
    final t = context.tokens;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: detail.when(
          loading: () => const AppLoadingView(label: 'Loading details...'),
          error: (Object error, StackTrace _) => AppErrorView(
            message: error.toString(),
            onRetry: () => ref.invalidate(sessionDetailProvider(localSessionId)),
          ),
          data: (SessionDetail data) {
            final session = data.session;
            final synced = session.state == LocalSessionState.synced;
            final runs = data.timeline.where((SessionTimelineSegment s) => s.type == SessionActivityType.descent).length;
            final vert = session.elevationLossM;
            return ListView(
              padding: EdgeInsets.fromLTRB(24, 16, 24, AppTabBar.height + 24),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: 'Back',
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        final router = GoRouter.maybeOf(context);
                        if (router != null) {
                          router.go(RoutePaths.history);
                        } else {
                          Navigator.of(context).maybePop();
                        }
                      },
                      icon: Icon(Icons.arrow_back, color: t.textSecondary),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(session.resortId ?? 'Session', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 2),
                          MonoLabel('${session.startedAt.toDayLabel()} · ${session.startedAt.toTimeLabel()}', size: 8, tone: MonoTone.muted, letterSpacing: 1.6),
                        ],
                      ),
                    ),
                    StatusPill(synced ? '● Synced' : '○ Local only', variant: synced ? PillVariant.ice : PillVariant.muted),
                    PopupMenuButton<_SessionDetailAction>(
                      tooltip: 'Session actions',
                      icon: Icon(Icons.more_vert, color: t.textSecondary),
                      itemBuilder: (BuildContext context) => <PopupMenuEntry<_SessionDetailAction>>[
                        PopupMenuItem<_SessionDetailAction>(
                          value: _SessionDetailAction.delete,
                          child: Text('Delete session', style: TextStyle(color: t.rec)),
                        ),
                      ],
                      onSelected: (_SessionDetailAction action) => _onAction(context, ref, action, data),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Text(vert == null ? '--' : distanceUnit.convertFromMeters(vert.toDouble()).round().toString(), style: Theme.of(context).textTheme.displayMedium),
                        const SizedBox(width: 8),
                        MonoLabel('${distanceUnit.shortLabel} vert', size: 10, tone: MonoTone.volt, letterSpacing: 1.6),
                      ],
                    ),
                    const SizedBox(width: 22),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 18,
                          children: <Widget>[
                            StatBlock(value: speedUnit.convertFromMetersPerSecond(data.stats.maxSpeedMps).toStringAsFixed(1), label: 'Max', size: StatSize.small),
                            StatBlock(value: distanceUnit.formatFromMeters(data.stats.distanceM), label: 'Dist', size: StatSize.small),
                            StatBlock(value: '$runs', label: 'Runs', size: StatSize.small),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _timeSplit(context, data),
                const SizedBox(height: 18),
                _mapReplay(context, data, activeMapTileProviderConfig),
                const SizedBox(height: 20),
                _timeline(context, data, distanceUnit, speedUnit),
                if (session.localId > 0 && session.isUnsynced && !session.isInProgress) ...<Widget>[
                  const SizedBox(height: 18),
                  VoltButton(
                    label: session.state == LocalSessionState.syncFailed ? 'Retry sync' : 'Sync now',
                    onPressed: () async {
                      await ref.read(sessionRepositoryProvider).syncSession(localSessionId);
                      ref.invalidate(sessionDetailProvider(localSessionId));
                      ref.invalidate(historyProvider);
                      ref.invalidate(unsyncedSessionCountProvider);
                    },
                  ),
                ],
                if (showDebugDiagnostics) ...<Widget>[
                  const SizedBox(height: 18),
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const MonoLabel('Diagnostics', size: 8, tone: MonoTone.muted, letterSpacing: 1.8),
                        const SizedBox(height: 8),
                        Text(
                          'Raw points: ${data.points.length}\n'
                          'Filtered points: ${data.acceptedPoints.length}\n'
                          'Upload state: ${session.state.wireValue}\n'
                          'Last sync error: ${session.lastSyncError ?? 'None'}\n'
                          'Origin: ${session.remoteId != null ? 'Local+Server' : 'Local only'}\n'
                          'Tracking events: ${data.trackingDiagnostics.length}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (data.trackingDiagnostics.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(data.trackingDiagnostics.take(16).map(_diagnosticLine).join('\n'), style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _onAction(BuildContext context, WidgetRef ref, _SessionDetailAction action, SessionDetail data) async {
    if (action != _SessionDetailAction.delete) {
      return;
    }
    final confirmed = await _confirmDelete(context);
    if (!confirmed) {
      return;
    }
    try {
      final result = await ref.read(sessionRepositoryProvider).deleteSession(data.session);
      ref.invalidate(historyProvider);
      ref.invalidate(historySectionsProvider);
      ref.invalidate(unsyncedSessionCountProvider);
      ref.invalidate(sessionDetailProvider(localSessionId));
      if (context.mounted) {
        if (result.queuedRemoteDelete) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Session removed locally. Server deletion will retry when the backend is reachable.'),
            ),
          );
        }
        final router = GoRouter.maybeOf(context);
        if (router != null) {
          router.go(RoutePaths.history);
        } else {
          Navigator.of(context).pop();
        }
      }
    } catch (error) {
      final message = switch (error) {
        final AppFailure failure => failure.message,
        _ => error.toString(),
      };
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete session: $message')));
      }
    }
  }

  Widget _timeSplit(BuildContext context, SessionDetail data) {
    final t = context.tokens;
    final stats = data.stats;
    final hasSplit = data.timeline.isNotEmpty || stats.descentDurationS > 0 || stats.liftDurationS > 0 || stats.idleDurationS > 0;
    final total = hasSplit ? (stats.descentDurationS + stats.liftDurationS + stats.idleDurationS) : stats.durationS;
    int flex(int s) => total == 0 ? 1 : (s * 1000 ~/ total).clamp(1, 1000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            MonoLabel('Time split · ${formatSecondsAsDuration(stats.durationS)}', size: 8, tone: MonoTone.muted),
            Row(
              children: <Widget>[
                MonoLabel('■ Ride', size: 8, color: t.voltText),
                const SizedBox(width: 8),
                MonoLabel('■ Lift', size: 8, color: t.ice),
                const SizedBox(width: 8),
                const MonoLabel('■ Idle', size: 8, tone: MonoTone.muted),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: SizedBox(
            height: 10,
            child: hasSplit
                ? Row(
                    children: <Widget>[
                      Expanded(flex: flex(stats.descentDurationS), child: ColoredBox(color: t.descent)),
                      const SizedBox(width: 2),
                      Expanded(flex: flex(stats.liftDurationS), child: ColoredBox(color: t.lift)),
                      const SizedBox(width: 2),
                      Expanded(flex: flex(stats.idleDurationS), child: ColoredBox(color: t.idle)),
                    ],
                  )
                : ColoredBox(color: t.descent),
          ),
        ),
        if (!hasSplit) ...<Widget>[
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            children: <Widget>[
              StatBlock(value: formatSecondsAsDuration(stats.durationS), label: 'Ride time', size: StatSize.small),
            ],
          ),
        ],
      ],
    );
  }

  Widget _mapReplay(BuildContext context, SessionDetail detail, MapTileProviderConfig activeMapTileProviderConfig) {
    final t = context.tokens;
    final routePoints = detail.acceptedPoints.isNotEmpty ? detail.acceptedPoints : detail.points;
    if (routePoints.isEmpty) {
      return const SurfaceCard(child: MonoLabel('No route points available.', size: 9, uppercase: false, tone: MonoTone.muted));
    }
    LatLng toLatLng(LocalSessionPoint p) => LatLng(p.filteredLatitude ?? p.latitude, p.filteredLongitude ?? p.longitude);
    final route = routePoints.map(toLatLng).toList(growable: false);
    final polylines = detail.timeline.isEmpty
        ? <Polyline>[Polyline(points: route, strokeWidth: 3, color: t.descent)]
        : detail.timeline
            .where((SessionTimelineSegment s) => s.points.length >= 2)
            .map(
              (SessionTimelineSegment s) => Polyline(
                points: s.points.map(toLatLng).toList(growable: false),
                strokeWidth: s.type == SessionActivityType.descent ? 3 : 2,
                color: segmentColor(t, s.type),
                pattern: s.type == SessionActivityType.lift ? const StrokePattern.dotted(spacingFactor: 3) : const StrokePattern.solid(),
              ),
            )
            .toList(growable: false);

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 210,
        decoration: BoxDecoration(border: Border.all(color: t.line), borderRadius: BorderRadius.circular(18)),
        child: Stack(
          children: <Widget>[
            FlutterMap(
              options: MapOptions(initialCenter: route.first, initialZoom: 14),
              children: <Widget>[
                TileLayer(
                  urlTemplate: activeMapTileProviderConfig.urlTemplate,
                  subdomains: activeMapTileProviderConfig.subdomains,
                  retinaMode: activeMapTileProviderConfig.retinaMode,
                  userAgentPackageName: 'com.goofyrider.mobile',
                ),
                PolylineLayer(polylines: polylines),
                MarkerLayer(
                  markers: <Marker>[
                    Marker(point: route.first, width: 8, height: 8, child: DecoratedBox(decoration: BoxDecoration(color: t.text, shape: BoxShape.circle))),
                    Marker(point: route.last, width: 10, height: 10, child: DecoratedBox(decoration: BoxDecoration(color: t.volt, shape: BoxShape.circle))),
                  ],
                ),
                MapAttribution(config: activeMapTileProviderConfig),
              ],
            ),
            const Positioned(left: 12, bottom: 10, child: MonoLabel('Full route', size: 8)),
          ],
        ),
      ),
    );
  }

  Widget _timeline(BuildContext context, SessionDetail detail, DistanceUnit distanceUnit, SpeedUnit speedUnit) {
    final t = context.tokens;
    if (detail.timeline.isEmpty) {
      return SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const MonoLabel('Timeline', size: 9, letterSpacing: 1.8),
            const SizedBox(height: 8),
            Text('Motion segments are not available for this session yet.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textSecondary)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const MonoLabel('Timeline', size: 9, letterSpacing: 1.8),
        const SizedBox(height: 6),
        for (final SessionTimelineSegment segment in detail.timeline)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
            child: Row(
              children: <Widget>[
                SegmentSwatch(type: segment.type),
                const SizedBox(width: 12),
                SizedBox(width: 64, child: MonoLabel(segment.type == SessionActivityType.descent ? 'Ride' : segment.type.label, size: 10, weight: FontWeight.w700, tone: MonoTone.primary)),
                MonoLabel('${segment.startedAt.toTimeLabel()}–${segment.endedAt.toTimeLabel()}', size: 9, tone: MonoTone.muted, letterSpacing: 0.4, uppercase: false),
                const Spacer(),
                MonoLabel('${formatSecondsAsDuration(segment.durationS)} · ${distanceUnit.formatFromMeters(segment.distanceM)}', size: 9, letterSpacing: 0.4),
              ],
            ),
          ),
      ],
    );
  }
```

Keep `_diagnosticLine`, `_confirmDelete`, `enum _SessionDetailAction` unchanged. `StrokePattern` is from flutter_map 7 (`package:flutter_map/flutter_map.dart`); if the analyzer reports it missing, drop the `pattern:` argument.

- [ ] **Step 3: Run tests and commit**

Run: `flutter test test/widget/session_detail_screen_test.dart && flutter analyze`
Expected: 6 pass, clean.

```bash
cd goofyrider && git add mobile/lib/features/session/presentation/session_detail_screen.dart mobile/test/widget/session_detail_screen_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): restyle session detail to Fall Line

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 11: Record screen, map-first and HUD-first (canvas 1b, 1c)

**Files:**
- Modify: `lib/features/session/presentation/record_screen.dart` (rewrite `build`, `_statsPanel`, `_gpsSignalBadge`, `_statCard`, `_autoPauseBanner`, `_controlBar`; keep everything from `_maybeFollowRider` down, the `_statusBanner` permission cards and `_GpsSignalBars`)
- Modify: `test/widget/record_screen_test.dart`

**Interfaces:**
- Consumes: `MonoLabel`, `StatBlock`, `SurfaceCard`, `StatusPill`, `PillToggle`, `AppTabBar.height`, `context.tokens`, `recordingControllerProvider`, `gpsWarmupSampleStreamProvider`, `activeMapTileProviderConfigProvider`, unit providers.
- Produces: `enum RecordLayout { map, hud }` (private state `_layout`), test keys `ValueKey('record-layout-toggle')`, text `TAP FOR MAP ↗`.

- [ ] **Step 1: Update the record tests**

In `record_screen_test.dart`:
- Replace `'Start Recording'` with `'START RECORDING'` (three places), `'Finish'` with `'FINISH'` (two places). Keep `find.text('GPS')`.
- Tests 2 and 3: replace `'Vertical'` with `'VERT'` and `'Altitude'` with `'ALT'`; keep the `'320 m'`, `'1550 m'`, `'1050 ft'`, `'5085 ft'` assertions.
- Add a new test after test 1:

```dart
  testWidgets('record screen toggles between map and HUD layouts',
      (WidgetTester tester) async {
    final fakeRepository = FakeSessionRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionRepositoryProvider.overrideWithValue(fakeRepository),
          locationTrackingRepositoryProvider.overrideWithValue(FakeLocationRepository()),
          activeMapTileProviderConfigProvider.overrideWithValue(MapTileProviderConfig.devFallback),
        ],
        child: const MaterialApp(home: RecordScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('TAP FOR MAP ↗'), findsNothing);
    await tester.tap(find.text('HUD'));
    await tester.pumpAndSettle();
    expect(find.text('TAP FOR MAP ↗'), findsOneWidget);
    expect(find.text('SESSION MAX'), findsOneWidget);

    await tester.tap(find.text('TAP FOR MAP ↗'));
    await tester.pumpAndSettle();
    expect(find.text('TAP FOR MAP ↗'), findsNothing);
  });
```

- [ ] **Step 2: Run to verify failures**

Run: `flutter test test/widget/record_screen_test.dart`
Expected: FAIL on `START RECORDING`, `HUD`.

- [ ] **Step 3: Rewrite the record screen widgets**

Add imports `../../../app/shell/app_tab_bar.dart`, `../../../app/theme/app_theme.dart`, `../../../core/widgets/design_widgets.dart`, `recording_view_state.dart`. Add `enum RecordLayout { map, hud }` at top level and the field `RecordLayout _layout = RecordLayout.map;` to `_RecordScreenState`. Replace `build` through `_controlBar` with:

```dart
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final activeMapTileProviderConfig = ref.watch(activeMapTileProviderConfigProvider);
    final t = context.tokens;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleRecoveryPrompt(state);
      _handleErrorAlert(state);
    });

    final route = state.tracking.route;
    _maybeFollowRider(state, route);

    final warmupSample = ref.watch(gpsWarmupSampleStreamProvider).maybeWhen(
          data: (LocationSample sample) => sample,
          orElse: () => null,
        );
    final warmupLatLng = (route.isEmpty && warmupSample != null) ? LatLng(warmupSample.latitude, warmupSample.longitude) : null;
    _maybeFollowWarmup(warmupLatLng);
    final center = route.isNotEmpty ? route.last : (warmupLatLng ?? const LatLng(50.1, -119.4));

    final topRow = SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                _recPill(state),
                const SizedBox(width: 8),
                _phasePill(state),
                const Spacer(),
                _gpsSignalBadge(state),
                const SizedBox(width: 8),
                PillToggle<RecordLayout>(
                  key: const ValueKey<String>('record-layout-toggle'),
                  options: const <(RecordLayout, String)>[(RecordLayout.map, 'MAP'), (RecordLayout.hud, 'HUD')],
                  selected: _layout,
                  onChanged: (RecordLayout v) => setState(() => _layout = v),
                ),
              ],
            ),
            _permissionBanners(state),
          ],
        ),
      ),
    );

    final map = FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: _mapZoom,
        backgroundColor: t.mapBg,
        interactionOptions: _layout == RecordLayout.hud
            ? const InteractionOptions(flags: InteractiveFlag.none)
            : const InteractionOptions(),
        onPositionChanged: (MapCamera camera, bool hasGesture) {
          _mapZoom = camera.zoom;
          if (hasGesture && _isMapFollowing) {
            setState(() => _isMapFollowing = false);
          }
        },
      ),
      children: <Widget>[
        TileLayer(
          urlTemplate: activeMapTileProviderConfig.urlTemplate,
          subdomains: activeMapTileProviderConfig.subdomains,
          retinaMode: activeMapTileProviderConfig.retinaMode,
          userAgentPackageName: 'com.goofyrider.mobile',
          errorTileCallback: (_, __, ___) {
            if (mounted && !_mapTileError) {
              setState(() => _mapTileError = true);
            }
          },
        ),
        if (route.isNotEmpty)
          PolylineLayer(polylines: <Polyline>[Polyline(points: route, strokeWidth: 3.5, color: t.volt, strokeJoin: StrokeJoin.round)]),
        if (route.isNotEmpty)
          MarkerLayer(
            markers: <Marker>[
              Marker(
                point: route.last,
                width: 28,
                height: 28,
                child: DecoratedBox(
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: t.volt.withValues(alpha: 0.4))),
                  child: Center(child: Container(width: 14, height: 14, decoration: BoxDecoration(color: t.volt, shape: BoxShape.circle))),
                ),
              ),
            ],
          ),
        if (warmupLatLng != null)
          MarkerLayer(
            markers: <Marker>[
              Marker(point: warmupLatLng, width: 24, height: 24, child: Icon(Icons.my_location, size: 22, color: t.ice)),
            ],
          ),
        MapAttribution(config: activeMapTileProviderConfig),
      ],
    );

    final Widget body;
    if (_layout == RecordLayout.map) {
      body = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          map,
          Positioned(top: 0, left: 0, right: 0, child: topRow),
          Positioned(
            right: 12,
            bottom: AppTabBar.height + 222,
            child: FloatingActionButton.small(
              heroTag: 'recenter-record-map',
              onPressed: () => _recenterOnRider(route, warmupLatLng: warmupLatLng),
              child: const Icon(Icons.my_location),
            ),
          ),
          Positioned(
            left: 24,
            bottom: AppTabBar.height + 222,
            child: _speedHero(state, speedUnit, size: 84, shadow: true),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: AppTabBar.height + 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (state.autoPaused) _autoPauseBanner(),
                _statsSheet(state, speedUnit, distanceUnit),
              ],
            ),
          ),
        ],
      );
    } else {
      body = Column(
        children: <Widget>[
          topRow,
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(24, 30, 24, AppTabBar.height + 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Center(
                    child: MonoLabel(
                      '${_phaseLabel(state)} · ${state.preselectedResortId ?? 'Session'}',
                      size: 10,
                      tone: MonoTone.muted,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(child: _speedHero(state, speedUnit, size: 148, shadow: false, centered: true)),
                  const SizedBox(height: 14),
                  Center(child: _sessionMax(state, speedUnit)),
                  const SizedBox(height: 30),
                  _hudTiles(state, distanceUnit),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => setState(() => _layout = RecordLayout.map),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        height: 96,
                        decoration: BoxDecoration(border: Border.all(color: t.line), borderRadius: BorderRadius.circular(16)),
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            IgnorePointer(child: map),
                            const Positioned(right: 10, bottom: 8, child: MonoLabel('Tap for map ↗', size: 8)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (state.autoPaused) ...<Widget>[const SizedBox(height: 12), _autoPauseBanner()],
                  const SizedBox(height: 18),
                  _controlRow(state),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Scaffold(body: body);
  }

  String _phaseLabel(RecordingViewState state) {
    if (state.autoPaused) {
      return 'Auto-paused';
    }
    return switch (state.phase) {
      RecordScreenPhase.recording => 'Recording',
      RecordScreenPhase.paused => 'Paused',
      RecordScreenPhase.finishing => 'Finishing',
      RecordScreenPhase.syncPending => 'Sync pending',
      RecordScreenPhase.requestingPermissions => 'Permissions',
      _ => 'Ready',
    };
  }

  Widget _recPill(RecordingViewState state) {
    final active = state.phase == RecordScreenPhase.recording || state.phase == RecordScreenPhase.paused;
    if (!active) {
      return const StatusPill('Ready', variant: PillVariant.ghost);
    }
    return StatusPill('● Rec ${state.tracking.elapsed.toHoursMinutesSeconds()}', variant: PillVariant.rec);
  }

  Widget _phasePill(RecordingViewState state) {
    final recording = state.phase == RecordScreenPhase.recording && !state.autoPaused;
    return StatusPill(_phaseLabel(state), variant: recording ? PillVariant.volt : PillVariant.muted);
  }

  Widget _speedHero(RecordingViewState state, SpeedUnit speedUnit, {required double size, required bool shadow, bool centered = false}) {
    final t = context.tokens;
    final value = speedUnit.convertFromMetersPerSecond(state.tracking.currentSpeedMps);
    final whole = value.floor().toString();
    final frac = '.${((value - value.floor()) * 10).floor()}';
    final style = TextStyle(
      fontFamily: AppFonts.archivo,
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: -size * 0.04,
      height: 0.9,
      color: t.text,
      shadows: shadow ? <Shadow>[Shadow(color: t.bg.withValues(alpha: 0.9), blurRadius: 18, offset: const Offset(0, 2))] : null,
    );
    final number = Text.rich(
      TextSpan(text: whole, style: style, children: <InlineSpan>[
        TextSpan(text: frac, style: style.copyWith(fontSize: size * 0.5, color: t.textSecondary)),
      ]),
    );
    if (centered) {
      return Column(
        children: <Widget>[
          number,
          const SizedBox(height: 8),
          MonoLabel(speedUnit.shortLabel, size: 11, tone: MonoTone.volt, letterSpacing: 2.6),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        number,
        const SizedBox(width: 8),
        MonoLabel(speedUnit.shortLabel, size: 11, tone: MonoTone.volt, letterSpacing: 1.6),
      ],
    );
  }

  Widget _sessionMax(RecordingViewState state, SpeedUnit speedUnit) {
    final t = context.tokens;
    final max = state.tracking.liveStats.maxSpeedMps;
    final current = state.tracking.currentSpeedMps;
    final ratio = max <= 0 ? 0.0 : (current / max).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const MonoLabel('Session max', size: 9),
        const SizedBox(width: 8),
        Text(speedUnit.convertFromMetersPerSecond(max).toStringAsFixed(1), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 14)),
        const SizedBox(width: 8),
        Container(
          width: 44,
          height: 4,
          decoration: BoxDecoration(color: t.raised, borderRadius: BorderRadius.circular(2)),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: ratio,
            child: DecoratedBox(decoration: BoxDecoration(color: t.volt, borderRadius: BorderRadius.circular(2))),
          ),
        ),
      ],
    );
  }

  String _verticalLabel(RecordingViewState state, DistanceUnit distanceUnit) {
    final loss = state.tracking.liveStats.elevationLossM;
    return loss == null ? '--' : distanceUnit.formatFromMeters(loss.toDouble());
  }

  String _altitudeLabel(RecordingViewState state, DistanceUnit distanceUnit) {
    final alt = state.tracking.currentAltitudeM;
    return alt == null ? '--' : distanceUnit.formatFromMeters(alt);
  }

  Widget _hudTiles(RecordingViewState state, DistanceUnit distanceUnit) {
    final stats = state.tracking.liveStats;
    Widget tile(String value, String label) => SurfaceCard(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: StatBlock(value: value, label: label, size: StatSize.large),
        );
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 2.2,
      children: <Widget>[
        tile(_verticalLabel(state, distanceUnit), 'Vert'),
        tile(distanceUnit.formatFromMeters(stats.distanceM), 'Dist'),
        tile(state.tracking.elapsed.toHoursMinutesSeconds(), 'Ride time'),
        tile(_altitudeLabel(state, distanceUnit), 'Alt'),
      ],
    );
  }

  Widget _statsSheet(RecordingViewState state, SpeedUnit speedUnit, DistanceUnit distanceUnit) {
    final t = context.tokens;
    final stats = state.tracking.liveStats;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: t.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 14,
            crossAxisSpacing: 10,
            childAspectRatio: 2.6,
            children: <Widget>[
              StatBlock(value: speedUnit.convertFromMetersPerSecond(stats.maxSpeedMps).toStringAsFixed(1), label: 'Max ${speedUnit.shortLabel}'),
              StatBlock(value: _verticalLabel(state, distanceUnit), label: 'Vert'),
              StatBlock(value: distanceUnit.formatFromMeters(stats.distanceM), label: 'Dist'),
              StatBlock(value: _altitudeLabel(state, distanceUnit), label: 'Alt'),
              StatBlock(value: speedUnit.convertFromMetersPerSecond(stats.rideAvgSpeedMps).toStringAsFixed(1), label: 'Ride avg'),
              StatBlock(value: state.tracking.elapsed.toHoursMinutesSeconds(), label: 'Ride time'),
            ],
          ),
          const SizedBox(height: 16),
          _controlRow(state),
        ],
      ),
    );
  }

  Widget _gpsSignalBadge(RecordingViewState state) {
    final t = context.tokens;
    final signalColor = switch (state.tracking.gpsSignal.bars) {
      4 || 3 => t.ice,
      2 || 1 => t.volt,
      _ => t.textMuted,
    };
    return Semantics(
      label: 'GPS signal ${state.tracking.gpsSignal.description}',
      child: StatusPill(
        'GPS',
        variant: PillVariant.ghost,
        leading: _GpsSignalBars(bars: state.tracking.gpsSignal.bars, color: signalColor),
      ),
    );
  }

  Widget _permissionBanners(RecordingViewState state) {
    final controller = ref.read(recordingControllerProvider.notifier);
    final children = <Widget>[
      if (state.permission.needsAlwaysOnPermission)
        SurfaceCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Enable "Allow all the time" to keep tracking when your phone is locked.', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(child: TextButton(onPressed: controller.requestRequiredLocationPermissions, child: const Text('RETRY PERMISSION'))),
                  Expanded(child: TextButton(onPressed: controller.openLocationPermissionSettings, child: const Text('OPEN SETTINGS'))),
                ],
              ),
            ],
          ),
        ),
      if (state.permission.permissionState == LocationPermissionState.serviceDisabled)
        SurfaceCard(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Expanded(child: Text('Turn GPS on to keep recording accurately.', style: Theme.of(context).textTheme.bodySmall)),
              TextButton(onPressed: controller.openLocationServiceSettings, child: const Text('GPS SETTINGS')),
            ],
          ),
        ),
      if (_mapTileError)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: MonoLabel('Map tiles failing, check network signal.', size: 8, tone: MonoTone.muted, uppercase: false),
        ),
    ];
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Widget _autoPauseBanner() {
    final t = context.tokens;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: t.raised, borderRadius: BorderRadius.circular(14), border: Border.all(color: t.line)),
      child: Row(
        children: <Widget>[
          Icon(Icons.pause_circle_outline, color: t.textSecondary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Paused while stopped. Tap resume when you start moving again.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.text)),
          ),
        ],
      ),
    );
  }

  Widget _controlRow(RecordingViewState state) {
    final controller = ref.read(recordingControllerProvider.notifier);
    final inSession = state.phase == RecordScreenPhase.recording || state.phase == RecordScreenPhase.paused;
    return Row(
      children: <Widget>[
        Expanded(
          child: GhostButton(
            label: state.phase == RecordScreenPhase.paused ? 'Resume' : 'Pause',
            onPressed: state.phase == RecordScreenPhase.recording
                ? controller.pause
                : state.phase == RecordScreenPhase.paused
                    ? controller.resume
                    : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 14,
          child: VoltButton(
            label: inSession ? 'Finish' : 'Start recording',
            onPressed: state.canStart ? controller.startRecording : (inSession ? controller.finish : null),
          ),
        ),
      ],
    );
  }
```

Set the ghost button's `Expanded` to `flex: 10` so the ratio is 10:14 (canvas 1 : 1.4). Delete the old `_statusBanner`, `_statsPanel`, `_statCard`, `_mapSectionHeight`, `_controlBar` methods. Keep `_maybeFollowRider`, `_maybeFollowWarmup`, `_recenterOnRider`, `_handleErrorAlert`, `_handleRecoveryPrompt`, `_startGpsSignalRefreshLoop`, `_GpsSignalBars` unchanged, but change `_GpsSignalBars` heights to `<double>[5, 8, 11, 14]` and the inactive colour to `context.tokens.line`.

- [ ] **Step 4: Run tests and commit**

Run: `flutter test test/widget/record_screen_test.dart test/unit/recording_controller_resilience_test.dart && flutter analyze`
Expected: pass, clean.

```bash
cd goofyrider && git add mobile/lib/features/session/presentation/record_screen.dart mobile/test/widget/record_screen_test.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): restyle record screen with map-first and HUD-first layouts

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 12: Profile screen (canvas 1h)

**Files:**
- Modify: `lib/features/profile/presentation/profile_screen.dart` (rewrite `ProfileScreen.build`; keep `debugExportActionProvider` and the commented export block)

**Interfaces:**
- Consumes: `InitialsAvatar`, `MonoLabel`, `SurfaceCard`, `StatBlock`, `PillToggle`, `GhostButton`, `buildSeasonSummary`, `shortSeasonLabel`, `AppTabBar.height`, providers `authControllerProvider`, `speedUnitPreferenceProvider`, `distanceUnitPreferenceProvider`, `historyProvider`.

- [ ] **Step 1: Rewrite `ProfileScreen.build`**

```dart
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final history = ref.watch(historyProvider);
    final t = context.tokens;
    final name = authState.session?.user.displayName ?? 'Guest';
    final email = authState.session?.user.email ?? 'Not signed in';

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 24, 24, AppTabBar.height + 24),
        children: <Widget>[
          Row(
            children: <Widget>[
              InitialsAvatar(name: name, size: 56, ring: true),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(name, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 3),
                    MonoLabel(email, size: 9, tone: MonoTone.muted, letterSpacing: 0.8, uppercase: false, maxLines: 1),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          history.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (List<LocalRideSession> sessions) {
              final s = buildSeasonSummary(sessions, now: DateTime.now());
              return SurfaceCard(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    MonoLabel('Season ${shortSeasonLabel(s.label)}', size: 8, tone: MonoTone.muted, letterSpacing: 1.8),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 26,
                      runSpacing: 12,
                      children: <Widget>[
                        StatBlock(value: '${s.daysRidden}', label: 'Days', size: StatSize.large),
                        StatBlock(value: distanceUnit.formatFromMeters(s.totalVertM), label: 'Vert', size: StatSize.large),
                        StatBlock(value: speedUnit.convertFromMetersPerSecond(s.topSpeedMps).toStringAsFixed(1), label: 'Top ${speedUnit.shortLabel}', size: StatSize.large),
                        StatBlock(value: '${s.sessionCount}', label: 'Sessions', size: StatSize.large),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 22),
          SurfaceCard(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const MonoLabel('Units', size: 8, tone: MonoTone.muted, letterSpacing: 1.8),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text('Speed', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w600)),
                    PillToggle<SpeedUnit>(
                      options: const <(SpeedUnit, String)>[
                        (SpeedUnit.kilometersPerHour, 'KM/H'),
                        (SpeedUnit.milesPerHour, 'MPH'),
                        (SpeedUnit.metersPerSecond, 'M/S'),
                      ],
                      selected: speedUnit,
                      onChanged: (SpeedUnit v) => ref.read(speedUnitPreferenceProvider.notifier).setSpeedUnit(v),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text('Distance', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w600)),
                    PillToggle<DistanceUnit>(
                      options: const <(DistanceUnit, String)>[(DistanceUnit.meters, 'M'), (DistanceUnit.feet, 'FT')],
                      selected: distanceUnit,
                      onChanged: (DistanceUnit v) => ref.read(distanceUnitPreferenceProvider.notifier).setDistanceUnit(v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              SizedBox(
                width: 140,
                child: GhostButton(
                  label: 'Log out',
                  onPressed: () async {
                    await ref.read(authControllerProvider.notifier).logout();
                    if (context.mounted) {
                      context.go(RoutePaths.login);
                    }
                  },
                ),
              ),
              const MonoLabel('v0.1.0 · Sync ok', size: 8, tone: MonoTone.faint),
            ],
          ),
        ],
      ),
    );
  }
```

Add imports for `app_tab_bar.dart`, `app_theme.dart`, `design_widgets.dart`, `session_models.dart`, `season_summary.dart`, `session_providers.dart`; remove the now-unused `activeMapTileProviderConfig` watch and `core/providers.dart` import only if `debugExportActionProvider` no longer needs it (it does: keep `core/providers.dart`).

- [ ] **Step 2: Run the profile tests, analyzer, commit**

Run: `flutter test test/widget/profile_screen_test.dart; flutter analyze`
Expected: the three export tests still fail with `Export debug info` not found (pre-existing, unchanged); analyzer clean.

```bash
cd goofyrider && git add mobile/lib/features/profile/presentation/profile_screen.dart
git -c core.autocrlf=false commit -F - <<'MSG'
feat(mobile): restyle profile to Fall Line

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

---

### Task 13: Final sweep

**Files:** none new.

- [ ] **Step 1: Hardcoded colour sweep**

Run: `grep -rn "Color(0x\|Colors\.\(amber\|red\|orange\|green\|lightBlue\|black\|white\)" lib --include=*.dart | grep -v app_tokens.dart`
Expected: no matches in `lib/app/shell`, `lib/features/**/presentation`. `Colors.transparent` is allowed. Fix anything else by reading from `context.tokens`.

- [ ] **Step 2: Full analyzer and test run**

Run: `flutter analyze && flutter test`
Expected: analyzer clean. All tests pass except the four pre-existing failures (three profile export tests, one `Sync now` tooltip assertion). Record the exact failing test names in the final report.

- [ ] **Step 3: Update `FINDINGS.md` pointer**

Append to the repo-root `FINDINGS.md` (path `goofy-rider/FINDINGS.md`, outside the git repo, so no commit) a short note under a `## Mobile design system` heading: tokens live in `mobile/lib/app/theme/app_tokens.dart`, shared widgets in `mobile/lib/core/widgets/design_widgets.dart`, brand via `BRAND_WORDMARK` dart-define, spec and plan paths.

- [ ] **Step 4: Commit any sweep fixes**

```bash
cd goofyrider && git add -A mobile/lib mobile/test
git -c core.autocrlf=false commit -F - <<'MSG'
chore(mobile): Fall Line redesign sweep

Claude-Session: https://claude.ai/code/session_012gyDe9GE3CvYDwD6QDduZC
MSG
```

