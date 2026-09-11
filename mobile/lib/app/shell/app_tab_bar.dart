import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/widgets/design_widgets.dart';
import '../theme/app_theme.dart';

/// Canvas TabBar: translucent bar, hairline top, volt record puck, volt dot
/// under the active tab.
///
/// The widget's own box is [puckOverhang] taller than the visible bar so the
/// part of the record puck that protrudes above the bar stays hit-testable —
/// a [RenderBox] rejects pointer events outside its own size. The extra strip
/// is fully transparent and contains no opaque child, so taps that miss the
/// puck fall through to the screen behind it.
class AppTabBar extends StatelessWidget {
  const AppTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  /// Height of the visible (blurred) bar, excluding the system bottom inset.
  static const double height = 82;

  /// How far the record puck protrudes above the visible bar.
  static const double puckOverhang = 22;

  static const List<String> labels = <String>['HOME', 'RESORTS', 'RECORD', 'SEASONS', 'PROFILE'];

  /// Distance from the bottom of a shell screen's body to the top edge of the
  /// visible bar.
  ///
  /// With `Scaffold.extendBody`, the body's `MediaQuery.padding.bottom` equals
  /// this widget's full box (`height + puckOverhang + system inset`). Screens
  /// that anchor content above the bar want the visible bar's edge, so the
  /// transparent puck strip is subtracted. Outside the shell (no bar) this is 0.
  static double bottomClearance(BuildContext context) {
    final double padding = MediaQuery.paddingOf(context).bottom;
    return padding <= 0 ? 0 : (padding - puckOverhang).clamp(0, double.infinity);
  }
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
    return SizedBox(
      height: height + puckOverhang + bottomInset,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            top: puckOverhang,
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  decoration: BoxDecoration(
                    color: t.barBg,
                    border: Border(top: BorderSide(color: t.line)),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: EdgeInsets.fromLTRB(6, puckOverhang + 10, 6, 12 + bottomInset),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List<Widget>.generate(labels.length, (int index) {
                  return Expanded(child: _item(context, index));
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, int index) {
    final t = context.tokens;
    final active = index == selectedIndex;
    final color = active ? t.text : t.textMuted;
    final Widget glyphArea;
    if (index == 2) {
      glyphArea = SizedBox(
        height: 30,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: <Widget>[
            Positioned(
              top: -puckOverhang,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelected(index),
                child: Container(
                  key: const ValueKey<String>('tab-record-puck'),
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
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
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      glyphArea = SizedBox(height: 22, child: Icon(_icons[index], size: 22, color: color));
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
            glyphArea,
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
