class TokenPairResponse {
  const TokenPairResponse({
    required this.accessToken,
    required this.refreshToken,
    this.tokenType = 'bearer',
  });

  factory TokenPairResponse.fromJson(Map<String, dynamic> json) {
    return TokenPairResponse(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      tokenType: json['token_type'] as String? ?? 'bearer',
    );
  }

  final String accessToken;
  final String refreshToken;
  final String tokenType;
}

class UserProfileResponse {
  const UserProfileResponse({
    required this.id,
    required this.email,
    required this.displayName,
  });

  factory UserProfileResponse.fromJson(Map<String, dynamic> json) {
    return UserProfileResponse(
      id: json['id'] as String,
      email: json['email'] as String,
      displayName: json['display_name'] as String,
    );
  }

  final String id;
  final String email;
  final String displayName;
}
