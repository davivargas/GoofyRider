import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/domain/auth_models.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/resorts/presentation/resort_detail_screen.dart';
import '../../features/resorts/presentation/resorts_list_screen.dart';
import '../../features/session/presentation/history_screen.dart';
import '../../features/session/presentation/record_screen.dart';
import '../../features/session/presentation/session_detail_screen.dart';
import '../shell/app_shell.dart';
import '../shell/home_screen.dart';
import 'route_paths.dart';

final appRouterProvider = Provider<GoRouter>((Ref ref) {
  final ValueNotifier<int> refresh = ValueNotifier<int>(0);
  ref.listen<AuthState>(
    authControllerProvider,
    (_, __) => refresh.value++,
  );
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: RoutePaths.home,
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) {
      final AuthState authState = ref.read(authControllerProvider);
      final bool isAuthRoute =
          state.matchedLocation == RoutePaths.login || state.matchedLocation == RoutePaths.register;

      if (authState.status == AuthStatus.unknown) {
        return isAuthRoute ? null : RoutePaths.login;
      }

      if (authState.status == AuthStatus.unauthenticated && !isAuthRoute) {
        return RoutePaths.login;
      }

      if (authState.status == AuthStatus.authenticated && isAuthRoute) {
        return RoutePaths.home;
      }

      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: RoutePaths.login,
        builder: (BuildContext context, GoRouterState state) => const LoginScreen(),
      ),
      GoRoute(
        path: RoutePaths.register,
        builder: (BuildContext context, GoRouterState state) => const RegisterScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (
          BuildContext context,
          GoRouterState state,
          StatefulNavigationShell navigationShell,
        ) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: RoutePaths.home,
                builder: (BuildContext context, GoRouterState state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: RoutePaths.resorts,
                builder: (BuildContext context, GoRouterState state) => const ResortsListScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'detail/:resortId',
                    builder: (BuildContext context, GoRouterState state) {
                      final String resortId = state.pathParameters['resortId']!;
                      return ResortDetailScreen(resortId: resortId);
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: RoutePaths.record,
                builder: (BuildContext context, GoRouterState state) {
                  final String? resortId = state.uri.queryParameters['resortId'];
                  return RecordScreen(preselectedResortId: resortId);
                },
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: RoutePaths.history,
                builder: (BuildContext context, GoRouterState state) => const HistoryScreen(),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'detail/:sessionId',
                    builder: (BuildContext context, GoRouterState state) {
                      final int localSessionId =
                          int.parse(state.pathParameters['sessionId']!);
                      return SessionDetailScreen(localSessionId: localSessionId);
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: RoutePaths.profile,
                builder: (BuildContext context, GoRouterState state) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
