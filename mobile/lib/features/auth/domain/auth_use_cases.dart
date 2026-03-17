import 'auth_models.dart';
import 'auth_repository.dart';

class ObserveAuthState {
  const ObserveAuthState(this.repository);

  final AuthRepository repository;

  Future<AuthSession?> call() {
    return repository.restoreSession();
  }
}

class Login {
  const Login(this.repository);

  final AuthRepository repository;

  Future<AuthSession> call({required String email, required String password}) {
    return repository.login(email: email, password: password);
  }
}

class Logout {
  const Logout(this.repository);

  final AuthRepository repository;

  Future<void> call() {
    return repository.logout();
  }
}

class RestoreSession {
  const RestoreSession(this.repository);

  final AuthRepository repository;

  Future<AuthSession?> call() {
    return repository.restoreSession();
  }
}
