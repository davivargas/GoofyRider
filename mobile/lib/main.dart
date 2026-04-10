import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router/app_router.dart';
import 'app/theme/app_theme.dart';
import 'core/providers.dart';
import 'core/storage/drift_local_database.dart';
import 'core/widgets/app_error_view.dart';
import 'features/auth/domain/auth_models.dart';
import 'features/auth/presentation/auth_providers.dart';
import 'features/session/presentation/session_providers.dart';

typedef LocalDatabaseLoader = Future<DriftLocalDatabase> Function();
typedef AppBuilder = Widget Function(DriftLocalDatabase database);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GoofyRiderBootstrapApp());
}

class GoofyRiderBootstrapApp extends StatefulWidget {
  const GoofyRiderBootstrapApp({
    super.key,
    this.databaseLoader = DriftLocalDatabase.open,
    this.appBuilder,
  });

  final LocalDatabaseLoader databaseLoader;
  final AppBuilder? appBuilder;

  @override
  State<GoofyRiderBootstrapApp> createState() => _GoofyRiderBootstrapAppState();
}

class _GoofyRiderBootstrapAppState extends State<GoofyRiderBootstrapApp> {
  Future<DriftLocalDatabase>? _databaseFuture;
  DriftLocalDatabase? _database;

  @override
  void initState() {
    super.initState();
    _databaseFuture = _openDatabase();
  }

  Future<DriftLocalDatabase> _openDatabase() async {
    try {
      final DriftLocalDatabase database = await widget.databaseLoader();
      _database = database;
      return database;
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'bootstrap',
          context: ErrorDescription('while opening local storage'),
        ),
      );
      rethrow;
    }
  }

  void _retry() {
    setState(() {
      _databaseFuture = _openDatabase();
    });
  }

  @override
  void dispose() {
    final DriftLocalDatabase? database = _database;
    _database = null;
    if (database != null) {
      unawaited(database.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DriftLocalDatabase>(
      future: _databaseFuture,
      builder:
          (BuildContext context, AsyncSnapshot<DriftLocalDatabase> snapshot) {
        if (snapshot.hasError) {
          return _BootstrapScaffold(
            child: AppErrorView(
              message:
                  'Local storage could not be opened. Retry after fixing device storage permissions or disk availability.',
              onRetry: _retry,
            ),
          );
        }

        if (!snapshot.hasData) {
          return const _BootstrapScaffold(
            child: _StartupSplashView(label: 'Opening local storage...'),
          );
        }

        final DriftLocalDatabase database = snapshot.data!;
        return ProviderScope(
          overrides: <Override>[
            driftLocalDatabaseProvider.overrideWithValue(database),
          ],
          child: widget.appBuilder?.call(database) ?? const GoofyRiderApp(),
        );
      },
    );
  }
}

class _BootstrapScaffold extends StatelessWidget {
  const _BootstrapScaffold({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoofyRider',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: child,
      ),
    );
  }
}

class _StartupSplashView extends StatelessWidget {
  const _StartupSplashView({this.label});

  static const Color _backgroundColor = Color(0xFF0A1624);

  final String? label;

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.of(context).padding.bottom;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ColoredBox(
          color: _backgroundColor,
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 260,
              maxHeight: 260,
            ),
            child: Image.asset(
              'assets/branding/splash_center_icon.png',
              fit: BoxFit.contain,
            ),
          ),
        ),
        if (label != null)
          Positioned(
            left: 24,
            right: 24,
            bottom: bottomInset + 24,
            child: Text(
              label!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

class GoofyRiderApp extends ConsumerStatefulWidget {
  const GoofyRiderApp({super.key});

  @override
  ConsumerState<GoofyRiderApp> createState() => _GoofyRiderAppState();
}

class _GoofyRiderAppState extends ConsumerState<GoofyRiderApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future<void>.microtask(_bootstrapApp);
  }

  Future<void> _bootstrapApp() async {
    await ref.read(authControllerProvider.notifier).bootstrap();
    await ref
        .read(recordingControllerProvider.notifier)
        .onAuthenticatedSessionAvailable();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(recordingControllerProvider.notifier).onAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      final String? previousUserId = previous?.session?.user.id;
      final String? nextUserId = next.session?.user.id;
      if (next.status == AuthStatus.authenticated &&
          nextUserId != null &&
          nextUserId != previousUserId) {
        ref
            .read(recordingControllerProvider.notifier)
            .onAuthenticatedSessionAvailable();
      }
    });

    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'GoofyRider',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
