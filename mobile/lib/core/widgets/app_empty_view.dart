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
            Text(title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            MonoLabel(subtitle,
                size: 11,
                uppercase: false,
                letterSpacing: 0.4,
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
