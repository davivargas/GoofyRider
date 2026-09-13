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
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
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
