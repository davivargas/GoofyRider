import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router/app_router.dart';
import 'app/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/logging/app_logger.dart';
import 'core/providers.dart';
import 'core/storage/drift_local_database.dart';
import 'core/widgets/app_error_view.dart';
import 'features/auth/domain/auth_models.dart';
import 'features/auth/presentation/auth_providers.dart';
import 'features/session/presentation/session_providers.dart';

typedef DatabaseLoader = Future<DriftLocalDatabase> Function();

Future<void> main() async => runAppWith();

Future<void> runAppWith({
  DatabaseLoader loader = DriftLocalDatabase.open,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final database = await loader();
    final activeMapTileProviderConfig = AppConstants.activeMapTileProviderConfig;
    runApp(
      ProviderScope(
        overrides: <Override>[
          driftLocalDatabaseProvider.overrideWithValue(database),
          activeMapTileProviderConfigProvider.overrideWithValue(activeMapTileProviderConfig),
        ],
        child: const GoofyRiderApp(),
      ),
    );
  } on Object catch (error, stackTrace) {
    const AppLogger().error(
      'Failed to initialize app dependencies during bootstrap',
      error: error,
      stackTrace: stackTrace,
    );
    runApp(
      BootstrapErrorApp(
        onRetry: () => runAppWith(loader: loader),
        errorDetails: error.toString(),
      ),
    );
  }
}

class BootstrapErrorApp extends StatelessWidget {
  const BootstrapErrorApp({
    super.key,
    required this.onRetry,
    required this.errorDetails,
  });

  final VoidCallback onRetry;
  final String errorDetails;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoofyRider',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: AppErrorView(
          message:
              'App bootstrap failed.\n\n$errorDetails\n\nRetry after fixing the issue above.',
          onRetry: onRetry,
        ),
      ),
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
    await _ensureGpsWarmupPermissionOnce();
    await ref.read(gpsWarmupServiceProvider).onAppForeground();
  }

  Future<void> _ensureGpsWarmupPermissionOnce() async {
    final prefs = ref.read(gpsWarmupPermissionPreferenceProvider);
    if (await prefs.hasBeenRequested()) {
      return;
    }
    // The warmup flow only needs foreground (whileInUse) permission. The
    // recording flow will later escalate to background if/when the user
    // actually starts a session.
    await ref
        .read(locationTrackingRepositoryProvider)
        .ensureForegroundPermission();
    await prefs.markRequested();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        ref.read(recordingControllerProvider.notifier).onAppResumed();
        unawaited(ref.read(gpsWarmupServiceProvider).onAppForeground());
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        ref.read(gpsWarmupServiceProvider).onAppBackground();
        break;
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
      final previousUserId = previous?.session?.user.id;
      final nextUserId = next.session?.user.id;
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
