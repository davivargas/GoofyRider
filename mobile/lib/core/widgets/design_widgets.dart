import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme/app_theme.dart';
import '../../features/session/domain/session_models.dart';
import '../constants/app_constants.dart';
import '../utils/duration_formatting.dart';
import '../utils/speed_unit.dart';

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
    this.size = 11,
    this.tone = MonoTone.secondary,
    this.letterSpacing = 1.4,
    this.weight = FontWeight.w600,
    this.uppercase = true,
    this.textAlign,
    this.maxLines,
    this.softWrap,
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

  /// `false` keeps the label on one line (CSS `white-space: nowrap`).
  final bool? softWrap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      uppercase ? text.toUpperCase() : text,
      textAlign: textAlign,
      maxLines: maxLines,
      softWrap: softWrap,
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
    this.valueSize,
    this.labelSize = 10,
    this.labelLetterSpacing = 1.4,
    this.labelGap,
  });

  final String value;
  final String label;
  final StatSize size;
  final MonoTone labelTone;
  final Color? valueColor;
  final CrossAxisAlignment alignment;

  /// Overrides the [size] preset's value font size.
  final double? valueSize;
  final double labelSize;
  final double labelLetterSpacing;

  /// Overrides the [size] preset's gap between value and label.
  final double? labelGap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (double fontSize, FontWeight weight, double spacing, double gap) =
        switch (size) {
      StatSize.hero => (68, FontWeight.w800, -2.0, 8),
      StatSize.large => (26, FontWeight.w700, -0.3, 3),
      StatSize.medium => (20, FontWeight.w700, 0, 2),
      StatSize.small => (17, FontWeight.w700, 0, 2),
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
            fontSize: valueSize ?? fontSize,
            fontWeight: weight,
            letterSpacing: spacing,
            height: 1,
            color: valueColor ?? t.text,
          ),
        ),
        SizedBox(height: labelGap ?? gap),
        MonoLabel(
          label,
          size: labelSize,
          tone: labelTone,
          letterSpacing: labelLetterSpacing,
          maxLines: 1,
        ),
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

/// `14 runs · 04:12 · MAX 58.1 km/h`: run count, ride time, top speed.
///
/// [runs] is left out of the line when null. Sessions do not carry a run count
/// yet, so callers only pass it where one is known.
String sessionDataLine(
  LocalRideSession session,
  SpeedUnit speedUnit, {
  int? runs,
}) {
  final max = speedUnit
      .convertFromMetersPerSecond(session.maxSpeedMps)
      .toStringAsFixed(1);
  return <String>[
    if (runs != null) '$runs runs',
    formatSecondsAsHoursMinutes(session.activeDurationS),
    'MAX $max ${speedUnit.shortLabel}',
  ].join(' · ');
}

/// One ride day: date column, hairline divider, resort name over a data line.
/// Shared by the Seasons list and the Home "Last session" card.
class SessionDayCard extends StatelessWidget {
  const SessionDayCard({
    super.key,
    required this.date,
    required this.title,
    required this.dataLine,
    this.onTap,
  });

  final DateTime date;
  final String title;
  final String dataLine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final local = date.toLocal();
    return SurfaceCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      onTap: onTap,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Column(
              children: <Widget>[
                Text(
                  '${local.day}',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontSize: 16),
                ),
                MonoLabel(
                  DateFormat('MMM').format(local),
                  size: 10,
                  tone: MonoTone.muted,
                  letterSpacing: 1,
                ),
              ],
            ),
          ),
          Container(width: 1, height: 36, color: t.line),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                MonoLabel(
                  dataLine,
                  size: 12,
                  letterSpacing: 0.24,
                  maxLines: 1,
                  softWrap: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum PillVariant { rec, volt, ice, ghost, muted }

/// Small rounded status chip (REC, DESCENT, GPS...).
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
      PillVariant.rec => (
          t.rec,
          t.bg.withValues(alpha: 0.85),
          t.rec.withValues(alpha: 0.5)
        ),
      PillVariant.volt => (t.voltInk, t.volt, t.volt),
      PillVariant.ice => (
          t.ice,
          Colors.transparent,
          t.ice.withValues(alpha: 0.35)
        ),
      PillVariant.ghost => (
          t.text,
          t.bg.withValues(alpha: 0.85),
          t.text.withValues(alpha: 0.12)
        ),
      PillVariant.muted => (t.textSecondary, Colors.transparent, t.line),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: 6)],
          MonoLabel(
            text,
            size: 11,
            weight: FontWeight.w700,
            letterSpacing: 0.88,
            softWrap: false,
            color: fg,
          ),
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
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: t.voltInk),
            )
          : _ButtonLabel(label),
    );
  }
}

/// Button label that stays on one line, scaling down only when the button is
/// too narrow for it.
class _ButtonLabel extends StatelessWidget {
  const _ButtonLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label.toUpperCase(), maxLines: 1, softWrap: false),
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
      child: _ButtonLabel(label),
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
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((String p) => p.isNotEmpty)
      .toList();
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
        border:
            Border.all(color: ring ? t.voltText : t.line, width: ring ? 2 : 1),
      ),
      child: Text(
        initialsFor(name),
        style: TextStyle(
          fontFamily: ring ? AppFonts.archivo : AppFonts.mono,
          fontSize: size * (ring ? 0.36 : 0.4),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: value == selected ? t.volt : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: value == selected
                        ? t.volt
                        : t.text.withValues(alpha: 0.12),
                  ),
                ),
                child: MonoLabel(
                  label,
                  size: 11,
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
