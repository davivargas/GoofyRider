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
