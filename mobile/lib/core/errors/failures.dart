sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.details});

  final String message;
  final Object? details;
}

class NetworkFailure extends AppFailure {
  const NetworkFailure(super.message, {super.details});
}

class AuthFailure extends AppFailure {
  const AuthFailure(super.message, {super.details});
}

class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.details});
}

class StorageFailure extends AppFailure {
  const StorageFailure(super.message, {super.details});
}

class SyncFailure extends AppFailure {
  const SyncFailure(super.message, {super.details});
}
