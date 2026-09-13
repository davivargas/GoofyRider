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
          fontSize: 68,
          fontWeight: FontWeight.w800,
          letterSpacing: -2,
          height: 0.95),
      displayMedium: archivo.copyWith(
          fontSize: 58,
          fontWeight: FontWeight.w800,
          letterSpacing: -1.7,
          height: 0.95),
      displaySmall: archivo.copyWith(
          fontSize: 40,
          fontWeight: FontWeight.w800,
          fontStyle: FontStyle.italic,
          letterSpacing: -0.4),
      headlineLarge: archivo.copyWith(
          fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.7),
      headlineMedium:
          archivo.copyWith(fontSize: 24, fontWeight: FontWeight.w700),
      headlineSmall: archivo.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          fontStyle: FontStyle.italic),
      titleLarge: archivo.copyWith(fontSize: 20, fontWeight: FontWeight.w800),
      titleMedium: archivo.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
      titleSmall: archivo.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
      bodyLarge: archivo.copyWith(
          fontSize: 15, fontWeight: FontWeight.w400, height: 1.5),
      bodyMedium: archivo.copyWith(
          fontSize: 13, fontWeight: FontWeight.w400, height: 1.5),
      bodySmall: archivo.copyWith(
          fontSize: 11, fontWeight: FontWeight.w400, color: t.textMuted),
      labelLarge: mono.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
          color: t.text),
      labelMedium: mono.copyWith(
          fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1.4),
      labelSmall: mono.copyWith(
          fontSize: 8,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
          color: t.textMuted),
    );

    final shape14 =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    OutlineInputBorder inputBorder(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color),
        );
    final fieldLabel = mono.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.7,
        color: t.textMuted);

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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
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
      listTileTheme:
          ListTileThemeData(textColor: t.text, iconColor: t.textSecondary),
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
