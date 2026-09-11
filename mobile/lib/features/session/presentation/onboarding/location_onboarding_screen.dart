import 'dart:async';

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
    if (requestPermission) {
      // The warm-up service gave up on the first foreground pass because
      // permission was still missing; kick it again now that it was granted.
      unawaited(ref.read(gpsWarmupServiceProvider).onAppForeground());
    }
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
