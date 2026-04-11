import 'package:flutter/material.dart';

class AppPalette {
  AppPalette._();

  static const Color night = Color(0xFF0A1624);
  static const Color deepBlue = Color(0xFF12273B);
  static const Color ice = Color(0xFFE6F4FF);
  static const Color snow = Color(0xFFF8FBFF);
  static const Color alpine = Color(0xFF1FA1FF);
  static const Color powder = Color(0xFF7FD3FF);
  static const Color ember = Color(0xFFFFB13D);
  static const Color danger = Color(0xFFFC6A6A);
}

class AppTheme {
  AppTheme._();

  static ThemeData dark() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppPalette.alpine,
      brightness: Brightness.dark,
      surface: AppPalette.deepBlue,
      primary: AppPalette.alpine,
      secondary: AppPalette.ember,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppPalette.night,
      cardTheme: CardThemeData(
        color: const Color(0xFF152C42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF17344D),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: Color(0xFF17344D),
        selectedColor: AppPalette.alpine,
        disabledColor: Color(0xFF2E4358),
      ),
    );
  }

  static ThemeData light() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppPalette.alpine,
      brightness: Brightness.light,
      surface: AppPalette.snow,
      primary: AppPalette.alpine,
      secondary: AppPalette.ember,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppPalette.snow,
      cardTheme: CardThemeData(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.ice,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }
}
