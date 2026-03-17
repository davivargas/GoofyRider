import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/auth_token_interceptor.dart';
import '../../../core/network/dio_client.dart';
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
  final Dio dio = buildBaseDio();
  final AuthController controller = ref.read(authControllerProvider.notifier);

  dio.interceptors.add(
    AuthTokenInterceptor(
      dio: dio,
      accessTokenGetter: controller.currentAccessToken,
      refreshTokenGetter: controller.currentRefreshToken,
      refreshCallback: controller.refreshAccessToken,
      onAuthReset: controller.forceUnauthenticated,
    ),
  );

  return dio;
});
