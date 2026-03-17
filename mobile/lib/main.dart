import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router/app_router.dart';
import 'app/theme/app_theme.dart';
import 'core/providers.dart';
import 'core/storage/drift_local_database.dart';
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

class _GoofyRiderAppState extends ConsumerState<GoofyRiderApp> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      ref.read(authControllerProvider.notifier).bootstrap();
      ref.read(recordingControllerProvider.notifier).retryPendingSyncs();
    });
  }

  @override
  Widget build(BuildContext context) {
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
