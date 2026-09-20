import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/design_widgets.dart';
import 'auth_providers.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final t = context.tokens;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const AuthBackdrop(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 40, 28, 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Wordmark(size: 44),
                        const SizedBox(height: 12),
                        const MonoLabel('Track every line.',
                            size: 10, letterSpacing: 2.4),
                        const SizedBox(height: 44),
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'EMAIL'),
                          validator: (String? value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Email is required.';
                            }
                            if (!value.contains('@')) {
                              return 'Enter a valid email.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration:
                              const InputDecoration(labelText: 'PASSWORD'),
                          validator: (String? value) {
                            if (value == null || value.isEmpty) {
                              return 'Password is required.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 18),
                        if (authState.errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              authState.errorMessage!,
                              style: TextStyle(color: t.rec),
                            ),
                          ),
                        VoltButton(
                          label: 'Log in',
                          busy: authState.isBusy,
                          onPressed: _onLogin,
                        ),
                        const SizedBox(height: 12),
                        GhostButton(
                          label: 'Create account',
                          onPressed: () => context.go(RoutePaths.register),
                        ),
                        const SizedBox(height: 26),
                        Text(
                          'Rides record offline — sign in to sync them.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onLogin() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    await ref.read(authControllerProvider.notifier).login(
          _emailController.text,
          _passwordController.text,
        );
  }
}

/// Shared backdrop for auth screens: radial glow plus a dashed volt line.
class AuthBackdrop extends StatelessWidget {
  const AuthBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -1),
          radius: 1,
          colors: <Color>[t.mapGlow, t.bg],
        ),
      ),
      child: CustomPaint(painter: _DashedLinePainter(t.volt)),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  _DashedLinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / 390;
    final points = <Offset>[
      Offset(60 * w, 40),
      Offset(180 * w, 180),
      Offset(140 * w, 250),
      Offset(250 * w, 330),
    ];
    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < points.length - 1; i++) {
      _dashed(canvas, points[i], points[i + 1], paint);
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 8.0;
    final total = (b - a).distance;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final end = (d + dash).clamp(0, total).toDouble();
      canvas.drawLine(a + dir * d, a + dir * end, paint);
      d += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}
