class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.displayName,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String,
      email: json['email'] as String,
      displayName: json['display_name'] as String,
    );
  }

  final String id;
  final String email;
  final String displayName;
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });

  final String accessToken;
  final String refreshToken;
  final UserProfile user;

  bool get isValid => accessToken.isNotEmpty && refreshToken.isNotEmpty;
}

enum AuthStatus {
  unknown,
  authenticated,
  unauthenticated,
}

class AuthState {
  const AuthState({
    required this.status,
    this.session,
    this.errorMessage,
    this.isBusy = false,
  });

  factory AuthState.initial() => const AuthState(status: AuthStatus.unknown);

  final AuthStatus status;
  final AuthSession? session;
  final String? errorMessage;
  final bool isBusy;

  AuthState copyWith({
    AuthStatus? status,
    AuthSession? session,
    String? errorMessage,
    bool clearError = false,
    bool? isBusy,
  }) {
    return AuthState(
      status: status ?? this.status,
      session: session ?? this.session,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isBusy: isBusy ?? this.isBusy,
    );
  }
}
