import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failures.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._repository) : super(AuthState.initial());

  final AuthRepository _repository;

  Future<void> bootstrap() async {
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      final AuthSession? session = await _repository.restoreSession();
      if (session == null) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      } else {
        state = AuthState(status: AuthStatus.authenticated, session: session);
      }
    } catch (error) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      final AuthSession session = await _repository.login(email: email, password: password);
      state = AuthState(status: AuthStatus.authenticated, session: session);
    } on AppFailure catch (failure) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        errorMessage: failure.message,
      );
    } catch (error) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        errorMessage: 'An unexpected error occurred. Please try again.',
      );
    }
  }

  Future<void> register(String email, String password, String displayName) async {
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      final AuthSession session = await _repository.register(
        email: email,
        password: password,
        displayName: displayName,
      );
      state = AuthState(status: AuthStatus.authenticated, session: session);
    } on AppFailure catch (failure) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        errorMessage: failure.message,
      );
    } catch (error) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        errorMessage: 'An unexpected error occurred. Please try again.',
      );
    }
  }

  Future<void> logout() async {
    await _repository.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  Future<String?> currentAccessToken() {
    return _repository.currentAccessToken();
  }

  Future<String?> currentRefreshToken() {
    return _repository.currentRefreshToken();
  }

  Future<String?> refreshAccessToken(String refreshToken) async {
    final String? refreshed = await _repository.refreshAccessToken(refreshToken);
    if (refreshed == null) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return null;
    }

    final AuthSession? existing = state.session;
    if (existing != null) {
      state = AuthState(
        status: AuthStatus.authenticated,
        session: AuthSession(
          accessToken: refreshed,
          refreshToken: existing.refreshToken,
          user: existing.user,
        ),
      );
    }
    return refreshed;
  }

  Future<void> forceUnauthenticated() async {
    await _repository.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}
