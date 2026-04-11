import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredTokens {
  const StoredTokens({
    required this.accessToken,
    required this.refreshToken,
    this.userId,
    this.email,
    this.displayName,
  });

  final String accessToken;
  final String refreshToken;
  final String? userId;
  final String? email;
  final String? displayName;

  bool get isValid => accessToken.isNotEmpty && refreshToken.isNotEmpty;

  bool get hasCachedUserProfile =>
      userId != null &&
      userId!.isNotEmpty &&
      email != null &&
      email!.isNotEmpty &&
      displayName != null &&
      displayName!.isNotEmpty;
}

abstract class TokenStorage {
  Future<StoredTokens?> read();
  Future<void> write(StoredTokens tokens);
  Future<void> clear();
}

class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage(this._storage);

  static const String _accessKey = 'goofyrider_access_token';
  static const String _refreshKey = 'goofyrider_refresh_token';
  static const String _userIdKey = 'goofyrider_user_id';
  static const String _emailKey = 'goofyrider_user_email';
  static const String _displayNameKey = 'goofyrider_user_display_name';

  final FlutterSecureStorage _storage;

  StoredTokens? _cached;
  bool _cacheLoaded = false;

  @override
  Future<StoredTokens?> read() async {
    if (_cacheLoaded) {
      return _cached;
    }
    final String? access = await _storage.read(key: _accessKey);
    final String? refresh = await _storage.read(key: _refreshKey);
    if (access == null || refresh == null) {
      _cached = null;
      _cacheLoaded = true;
      return null;
    }
    final String? userId = await _storage.read(key: _userIdKey);
    final String? email = await _storage.read(key: _emailKey);
    final String? displayName = await _storage.read(key: _displayNameKey);
    _cached = StoredTokens(
      accessToken: access,
      refreshToken: refresh,
      userId: userId,
      email: email,
      displayName: displayName,
    );
    _cacheLoaded = true;
    return _cached;
  }

  @override
  Future<void> write(StoredTokens tokens) async {
    await _storage.write(key: _accessKey, value: tokens.accessToken);
    await _storage.write(key: _refreshKey, value: tokens.refreshToken);
    await _writeOptional(_userIdKey, tokens.userId);
    await _writeOptional(_emailKey, tokens.email);
    await _writeOptional(_displayNameKey, tokens.displayName);
    _cached = tokens;
    _cacheLoaded = true;
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _userIdKey);
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _displayNameKey);
    _cached = null;
    _cacheLoaded = true;
  }

  Future<void> _writeOptional(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
      return;
    }
    await _storage.write(key: key, value: value);
  }
}
