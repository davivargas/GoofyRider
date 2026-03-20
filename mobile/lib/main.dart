import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router/app_router.dart';
import 'app/theme/app_theme.dart';
import 'core/providers.dart';
import 'core/storage/drift_local_database.dart';
import 'features/auth/domain/auth_models.dart';
import 'features/auth/presentation/auth_providers.dart';
import 'features/session/presentation/session_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final DriftLocalDatabase localDatabase = await DriftLocalDatabase.open();

  runApp(
    ProviderScope(
      overrides: <Override>[
        driftLocalDatabaseProvider.overrideWithValue(localDatabase),
      ],
      child: const GoofyRiderApp(),
    ),
  );
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
