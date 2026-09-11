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
    final Widget glyphArea;
    if (index == 2) {
      glyphArea = SizedBox(
        height: 30,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: <Widget>[
            Positioned(
              top: -22,
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
