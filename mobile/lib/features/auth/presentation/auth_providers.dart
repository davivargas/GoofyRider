import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/auth_token_interceptor.dart';
import '../../../core/providers.dart';
import '../data/auth_api.dart';
import '../data/auth_repository_impl.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';
import 'auth_controller.dart';

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(baseDioProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepositoryImpl(
    authApi: ref.watch(authApiProvider),
    tokenStorage: ref.watch(tokenStorageProvider),
  ),
);

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) => AuthController(ref.watch(authRepositoryProvider)),
);

final authorizedDioProvider = Provider<Dio>((ref) {
  final baseDio = ref.watch(baseDioProvider);
  final authorizedDio = Dio(baseDio.options.copyWith());
  final controller = ref.read(authControllerProvider.notifier);

  authorizedDio.interceptors.add(
    AuthTokenInterceptor(
      dio: authorizedDio,
      accessTokenGetter: controller.currentAccessToken,
      refreshTokenGetter: controller.currentRefreshToken,
      refreshCallback: controller.refreshAccessToken,
      onAuthReset: controller.forceUnauthenticated,
    ),
  );

  return authorizedDio;
});
