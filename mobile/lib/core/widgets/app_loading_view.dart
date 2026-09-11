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
