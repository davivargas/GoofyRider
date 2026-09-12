# Security Hardening (Mobile and Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Flutter app and its Android build match the hardened backend: rotated refresh tokens handled correctly, 429 surfaced, a device label sent on auth calls, ordinary preferences moved out of secure storage, HTTPS-only network policy in release, backups disabled, real release signing and shrinking.

**Architecture:** All changes stay inside the existing feature layering. Auth transport changes live in `features/auth/data`, the preference store is a new `core/storage/app_preferences.dart` injected through a Riverpod provider, and Android hardening is confined to `android/app` resources and Gradle config. Nothing under `presentation/` gains a new dependency on Dio or Drift.

**Tech Stack:** Flutter 3.38 (Dart 3.4+), Riverpod 2, Dio 5, `shared_preferences` (new), `flutter_secure_storage` (tokens only), mocktail, Kotlin, Gradle Kotlin DSL, R8.

**Spec:** `docs/superpowers/specs/2026-09-12-security-hardening-design.md` (sections 4 and 5). The backend plan `docs/superpowers/plans/2026-09-12-security-hardening-backend.md` must be finished first for the end-to-end behaviour, but every task here is testable on its own with fakes.

## Global Constraints

- Follow `CLAUDE.md`: `presentation -> domain -> data`; widgets never import Dio or Drift; `debugPrint`/`print` are not allowed in `lib/`; providers live in `core/providers.dart` or a feature-root providers file; ordinary preferences use `shared_preferences`, `flutter_secure_storage` is for credentials only.
- Quality gates before the branch is done: `dart format --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`. Run the smallest relevant test first, then broaden.
- Tests must not perform network I/O.
- Do not change `applicationId` (owned by the `rename/fall-line` branch).
- Commit after every task on `fable-review`. Commit messages end with the session attribution line configured for this repository.
- Run mobile commands from `goofyrider/mobile/`.

---

### Task 1: Map HTTP 429 to a readable failure

**Files:**
- Modify: `lib/core/network/api_error.dart`
- Test: `test/unit/api_error_test.dart` (new)

**Interfaces:**
- Consumes: `AppFailure`, `NetworkFailure` from `lib/core/errors/failures.dart`.
- Produces: `mapDioException` returns `NetworkFailure` whose `message` is the server `detail` for 429 responses, or `Too many requests. Try again in <N> seconds.` when the body has no detail but the `Retry-After` header is present.

- [ ] **Step 1: Write the failing test**

```dart
// test/unit/api_error_test.dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goofyrider_mobile/core/errors/failures.dart';
import 'package:goofyrider_mobile/core/network/api_error.dart';

DioException _exception({
  required int statusCode,
  Object? data,
  Map<String, List<String>> headers = const <String, List<String>>{},
}) {
  final options = RequestOptions(path: '/auth/login');
  return DioException(
    requestOptions: options,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: statusCode,
      data: data,
      headers: Headers.fromMap(headers),
    ),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  test('429 with detail maps to NetworkFailure carrying the server message', () {
    final failure = mapDioException(
      _exception(
        statusCode: 429,
        data: <String, dynamic>{'detail': 'Too many requests. Try again in 42 seconds.'},
        headers: <String, List<String>>{'retry-after': <String>['42']},
      ),
    );

    expect(failure, isA<NetworkFailure>());
    expect(failure.message, 'Too many requests. Try again in 42 seconds.');
  });

  test('429 without detail builds a message from Retry-After', () {
    final failure = mapDioException(
      _exception(
        statusCode: 429,
        headers: <String, List<String>>{'retry-after': <String>['7']},
      ),
    );

    expect(failure, isA<NetworkFailure>());
    expect(failure.message, 'Too many requests. Try again in 7 seconds.');
  });

  test('401 still maps to AuthFailure', () {
    final failure = mapDioException(
      _exception(statusCode: 401, data: <String, dynamic>{'detail': 'Invalid token.'}),
    );

    expect(failure, isA<AuthFailure>());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/unit/api_error_test.dart`
Expected: the two 429 tests fail (the message falls through to the generic fallback).

- [ ] **Step 3: Add the 429 branch**

In `lib/core/network/api_error.dart`, after the `statusCode == 401` block inside `mapDioException`, add:

```dart
  if (statusCode == 429) {
    final retryAfter = int.tryParse(
      exception.response?.headers.value('retry-after')?.trim() ?? '',
    );
    final fallback = retryAfter == null
        ? 'Too many requests. Try again later.'
        : 'Too many requests. Try again in $retryAfter seconds.';
    return NetworkFailure(machineMessage ?? fallback, details: payload);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/unit/api_error_test.dart`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/core/network/api_error.dart test/unit/api_error_test.dart
git commit -m "feat(mobile): surface 429 rate-limit responses as readable failures"
```

---

### Task 2: Treat a rejected refresh as a revoked session

**Files:**
- Modify: `lib/features/auth/data/auth_repository_impl.dart` (`refreshAccessToken`, `restoreSession`)
- Modify: `lib/features/auth/presentation/auth_controller.dart` (`refreshAccessToken`)
- Modify: `lib/core/network/auth_token_interceptor.dart` (`onError` catch block)
- Test: `test/unit/auth_repository_impl_test.dart`, `test/unit/auth_token_interceptor_test.dart`

**Interfaces:**
- Consumes: `AuthFailure` from `lib/core/errors/failures.dart`.
- Produces: `AuthRepository.refreshAccessToken` now throws `AuthFailure('Session expired. Please sign in again.')` when the backend answers 401 and returns `null` only for connectivity or other failures. `AuthController.refreshAccessToken` rethrows that `AuthFailure` after setting the state to unauthenticated. `AuthTokenInterceptor` calls `onAuthReset` whenever the refresh callback throws `AuthFailure`, regardless of `preserveAuthOnFailure`.

- [ ] **Step 1: Write the failing repository tests**

Append to `test/unit/auth_repository_impl_test.dart` inside `main()` (reuse the existing `MockAuthApi`, `MockTokenStorage`, and `tokenPair`):

```dart
  test('refreshAccessToken throws AuthFailure when the backend rejects the token', () async {
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
    );
    final options = RequestOptions(path: '/auth/refresh');
    when(() => authApi.refresh(refreshToken: 'stale')).thenThrow(
      DioException(
        requestOptions: options,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: 401,
          data: <String, dynamic>{'detail': 'Invalid or expired refresh token.'},
        ),
        type: DioExceptionType.badResponse,
      ),
    );

    expect(
      () => repository.refreshAccessToken('stale'),
      throwsA(isA<AuthFailure>()),
    );
  });

  test('refreshAccessToken returns null on connectivity failure', () async {
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
    );
    when(() => authApi.refresh(refreshToken: 'offline')).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/auth/refresh'),
        type: DioExceptionType.connectionError,
      ),
    );

    expect(await repository.refreshAccessToken('offline'), isNull);
  });

  test('restoreSession clears tokens when refresh is rejected', () async {
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
    );
    when(() => tokenStorage.read()).thenAnswer((_) async => tokenPair);
    final meOptions = RequestOptions(path: '/auth/me');
    when(() => authApi.me(accessToken: tokenPair.accessToken)).thenThrow(
      DioException(
        requestOptions: meOptions,
        response: Response<dynamic>(requestOptions: meOptions, statusCode: 401),
        type: DioExceptionType.badResponse,
      ),
    );
    final refreshOptions = RequestOptions(path: '/auth/refresh');
    when(() => authApi.refresh(refreshToken: tokenPair.refreshToken)).thenThrow(
      DioException(
        requestOptions: refreshOptions,
        response: Response<dynamic>(requestOptions: refreshOptions, statusCode: 401),
        type: DioExceptionType.badResponse,
      ),
    );
    when(() => tokenStorage.clear()).thenAnswer((_) async {});

    final session = await repository.restoreSession();

    expect(session, isNull);
    verify(() => tokenStorage.clear()).called(1);
  });
```

Add `import 'package:goofyrider_mobile/core/errors/failures.dart';` to the test imports.

- [ ] **Step 2: Write the failing interceptor test**

Append to `test/unit/auth_token_interceptor_test.dart` inside `main()`:

```dart
  test('resets auth when refresh reports a revoked token even for preserved requests', () async {
    var authResetCalled = false;
    final interceptor = AuthTokenInterceptor(
      dio: Dio(),
      accessTokenGetter: () async => 'access-token',
      refreshTokenGetter: () async => 'refresh-token',
      refreshCallback: (_) async =>
          throw const AuthFailure('Session expired. Please sign in again.'),
      onAuthReset: () async {
        authResetCalled = true;
      },
    );
    final handler = MockErrorInterceptorHandler();
    final requestOptions = RequestOptions(
      path: '/sessions/remote-1/points:batch',
      extra: <String, dynamic>{
        AuthTokenInterceptor.preserveAuthOnFailureExtraKey: true,
        AuthTokenInterceptor.retryPreservedAuthOnUnauthorizedExtraKey: true,
      },
    );
    final exception = DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 401,
        data: <String, dynamic>{'detail': 'Authentication required.'},
      ),
      type: DioExceptionType.badResponse,
    );

    await interceptor.onError(exception, handler);

    verify(() => handler.next(exception)).called(1);
    expect(authResetCalled, isTrue);
  });
```

Add `import 'package:goofyrider_mobile/core/errors/failures.dart';` to that file's imports.

- [ ] **Step 3: Run both test files to verify they fail**

Run: `flutter test test/unit/auth_repository_impl_test.dart test/unit/auth_token_interceptor_test.dart`
Expected: the first new repository test fails (expects a throw, gets `null`), the `restoreSession` test fails (tokens are cleared through the old path, but `refreshAccessToken` returns `null` rather than throwing, so the assertion on the thrown path is not exercised; treat any failure here as expected), and the interceptor test fails (`authResetCalled` is false).

- [ ] **Step 4: Implement the repository change**

In `lib/features/auth/data/auth_repository_impl.dart` add `import '../../../core/errors/failures.dart';` and replace `refreshAccessToken`:

```dart
  @override
  Future<String?> refreshAccessToken(String refreshToken) async {
    try {
      final payload = await _authApi.refresh(refreshToken: refreshToken);
      final accessToken = payload.accessToken;
      final existing = await _tokenStorage.read();
      if (existing != null) {
        await _tokenStorage.write(
          StoredTokens(
            accessToken: accessToken,
            refreshToken: payload.refreshToken,
            userId: existing.userId,
            email: existing.email,
            displayName: existing.displayName,
          ),
        );
      }
      return accessToken;
    } on DioException catch (exception) {
      if (exception.response?.statusCode == 401) {
        throw const AuthFailure('Session expired. Please sign in again.');
      }
      return null;
    }
  }
```

In `restoreSession`, replace the line
`final newAccessToken = await refreshAccessToken(storedTokens.refreshToken);` with:

```dart
      final String? newAccessToken;
      try {
        newAccessToken = await refreshAccessToken(storedTokens.refreshToken);
      } on AuthFailure {
        await _tokenStorage.clear();
        return null;
      }
```

- [ ] **Step 5: Implement the controller and interceptor changes**

In `lib/features/auth/presentation/auth_controller.dart` replace `refreshAccessToken`:

```dart
  Future<String?> refreshAccessToken(String refreshToken) async {
    final String? refreshed;
    try {
      refreshed = await _repository.refreshAccessToken(refreshToken);
    } on AuthFailure {
      state = const AuthState(status: AuthStatus.unauthenticated);
      rethrow;
    }
    if (refreshed == null) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return null;
    }

    final existing = state.session;
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
```

In `lib/core/network/auth_token_interceptor.dart` add `import '../errors/failures.dart';` and replace the final `catch (_)` block of `onError`:

```dart
    } on AuthFailure {
      _refreshInFlight = null;
      await _onAuthReset();
      handler.next(err);
    } catch (_) {
      _refreshInFlight = null;
      await _resetAuthIfNeeded(preserveAuthOnFailure);
      handler.next(err);
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `flutter test test/unit/auth_repository_impl_test.dart test/unit/auth_token_interceptor_test.dart`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/features/auth lib/core/network/auth_token_interceptor.dart test/unit/auth_repository_impl_test.dart test/unit/auth_token_interceptor_test.dart
git commit -m "feat(mobile): reset auth when the backend revokes a refresh token"
```

---

### Task 3: Send a device label on register, login, and refresh

**Files:**
- Create: `lib/features/auth/data/device_label_provider.dart`
- Modify: `lib/features/auth/data/auth_api.dart`
- Modify: `lib/features/auth/data/auth_repository_impl.dart`
- Modify: `android/app/src/main/kotlin/com/example/goofyrider_mobile/AndroidFusedLocationBridge.kt` (`onMethodCall`)
- Test: `test/unit/device_label_provider_test.dart` (new), `test/unit/auth_repository_impl_test.dart`

**Interfaces:**
- Produces: `class DeviceLabelProvider { Future<String> resolve(); }` returning at most 80 characters, e.g. `Google Pixel 8 / Android 15`, falling back to `Platform.operatingSystem`. `AuthApi.login/register/refresh` gain `String? deviceLabel` named parameters and send `device_label`. `AuthRepositoryImpl` constructor gains `DeviceLabelProvider? deviceLabelProvider`.
- Consumes: the existing `goofyrider/location_control` `MethodChannel`; new native method `getDeviceLabel`.

- [ ] **Step 1: Write the failing provider test**

```dart
// test/unit/device_label_provider_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goofyrider_mobile/features/auth/data/device_label_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('goofyrider/location_control');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('uses the native label and trims it to 80 characters', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'getDeviceLabel');
      return '  ${'x' * 100}  ';
    });

    final label = await DeviceLabelProvider(channel: channel).resolve();

    expect(label.length, 80);
    expect(label, 'x' * 80);
  });

  test('falls back to the operating system name when the channel is missing', () async {
    final label = await DeviceLabelProvider(channel: channel).resolve();

    expect(label, isNotEmpty);
    expect(label.length, lessThanOrEqualTo(80));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/unit/device_label_provider_test.dart`
Expected: FAIL, `device_label_provider.dart` does not exist.

- [ ] **Step 3: Implement the provider**

```dart
// lib/features/auth/data/device_label_provider.dart
import 'dart:io';

import 'package:flutter/services.dart';

/// Resolves a short human-readable device label (`Google Pixel 8 / Android 15`)
/// that the backend stores next to each refresh token so a user can tell
/// their devices apart. Never throws; falls back to the OS name.
class DeviceLabelProvider {
  DeviceLabelProvider({
    MethodChannel channel = const MethodChannel('goofyrider/location_control'),
  }) : _channel = channel;

  static const int maxLength = 80;

  final MethodChannel _channel;
  String? _cached;

  Future<String> resolve() async {
    final cached = _cached;
    if (cached != null) {
      return cached;
    }
    var label = Platform.operatingSystem;
    try {
      final native = await _channel.invokeMethod<String>('getDeviceLabel');
      final trimmed = native?.trim() ?? '';
      if (trimmed.isNotEmpty) {
        label = trimmed;
      }
    } on PlatformException {
      // Keep the fallback.
    } on MissingPluginException {
      // Keep the fallback (tests, non-Android platforms).
    }
    if (label.length > maxLength) {
      label = label.substring(0, maxLength);
    }
    _cached = label;
    return label;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/unit/device_label_provider_test.dart`
Expected: 2 tests pass.

- [ ] **Step 5: Add the native method**

In `AndroidFusedLocationBridge.kt`, inside `onMethodCall`'s `when (call.method)`, before the `else` branch, add:

```kotlin
            "getDeviceLabel" -> {
                result.success(
                    "${Build.MANUFACTURER} ${Build.MODEL} / Android ${Build.VERSION.RELEASE}".trim(),
                )
            }
```

`android.os.Build` is already imported.

- [ ] **Step 6: Extend AuthApi and the repository, and write the failing repository test**

In `lib/features/auth/data/auth_api.dart` add a `String? deviceLabel` named parameter to `login`, `register`, and `refresh`, and add `'device_label': deviceLabel,` to each request body. Example for `login`:

```dart
  Future<TokenPairResponse> login({
    required String email,
    required String password,
    String? deviceLabel,
  }) async {
    final response = await _dio.post<dynamic>(
      '/auth/login',
      data: <String, dynamic>{
        'email': email,
        'password': password,
        'device_label': deviceLabel,
      },
    );
    return TokenPairResponse.fromJson(response.data as Map<String, dynamic>);
  }
```

In `AuthRepositoryImpl`:

```dart
  AuthRepositoryImpl({
    required AuthApi authApi,
    required TokenStorage tokenStorage,
    DeviceLabelProvider? deviceLabelProvider,
  })  : _authApi = authApi,
        _tokenStorage = tokenStorage,
        _deviceLabelProvider = deviceLabelProvider ?? DeviceLabelProvider();

  final DeviceLabelProvider _deviceLabelProvider;
```

and pass `deviceLabel: await _deviceLabelProvider.resolve()` to `_authApi.login`, `_authApi.register`, and `_authApi.refresh`.

In `test/unit/auth_repository_impl_test.dart`, add a fake at the top:

```dart
class FakeDeviceLabelProvider extends DeviceLabelProvider {
  @override
  Future<String> resolve() async => 'Test Device / Android 15';
}
```

(with `import 'package:goofyrider_mobile/features/auth/data/device_label_provider.dart';`), construct every `AuthRepositoryImpl` in that file with `deviceLabelProvider: FakeDeviceLabelProvider()`, and change every `when(() => authApi.login(email: ..., password: ...))`, `authApi.register(...)`, and `authApi.refresh(refreshToken: ...)` stub to include `deviceLabel: any(named: 'deviceLabel')`. Add one assertion test:

```dart
  test('login sends the resolved device label', () async {
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
      deviceLabelProvider: FakeDeviceLabelProvider(),
    );
    when(() => authApi.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
          deviceLabel: any(named: 'deviceLabel'),
        )).thenAnswer(
      (_) async => TokenPairResponse(
        accessToken: tokenPair.accessToken,
        refreshToken: tokenPair.refreshToken,
      ),
    );
    when(() => tokenStorage.write(any<StoredTokens>())).thenAnswer((_) async {});
    when(() => authApi.me(accessToken: tokenPair.accessToken))
        .thenAnswer((_) async => userProfileResponse());

    await repository.login(email: 'a@b.c', password: 'pw');

    verify(() => authApi.login(
          email: 'a@b.c',
          password: 'pw',
          deviceLabel: 'Test Device / Android 15',
        )).called(1);
  });
```

- [ ] **Step 7: Run the auth tests**

Run: `flutter test test/unit/auth_repository_impl_test.dart test/unit/device_label_provider_test.dart`
Expected: all pass.

- [ ] **Step 8: Run analyze and the login widget test**

`auth_providers.dart` needs no change (the repository constructs a default `DeviceLabelProvider`). Run: `flutter analyze && flutter test test/unit test/widget/login_screen_test.dart`
Expected: no new analyzer issues in touched files; tests pass apart from the pre-existing failures listed in audit H2.

- [ ] **Step 9: Commit**

```bash
git add lib/features/auth android/app/src/main/kotlin test/unit/device_label_provider_test.dart test/unit/auth_repository_impl_test.dart
git commit -m "feat(mobile): send a device label with auth requests"
```

---

### Task 4: Move ordinary preferences to shared_preferences

**Files:**
- Modify: `pubspec.yaml` (add `shared_preferences: ^2.3.0`)
- Create: `lib/core/storage/app_preferences.dart`
- Create: `lib/core/providers/enum_preference_controller.dart`
- Modify: `lib/core/providers.dart` (add `appPreferencesProvider`)
- Modify: `lib/core/providers/distance_unit_preference_provider.dart`
- Modify: `lib/core/providers/speed_unit_preference_provider.dart`
- Modify: `lib/features/session/data/gps_warmup_permission_preference.dart`
- Modify: `lib/features/session/presentation/session_providers.dart` (`gpsWarmupPermissionPreferenceProvider`)
- Modify: `lib/main.dart` (load preferences at bootstrap and override the provider)
- Test: `test/unit/app_preferences_test.dart` (new), `test/unit/enum_preference_controller_test.dart` (new); adjust any existing test that constructs `GpsWarmupPermissionPreference(storage: ...)` or the unit controllers with a `storage:` argument.

**Interfaces:**
- Produces:
  - `class AppPreferences` with `static Future<AppPreferences> load({FlutterSecureStorage? legacyStorage})`, `factory AppPreferences.inMemory()`, `String? getString(String key)`, `Future<void> setString(String key, String value)`, `bool getBool(String key, {bool defaultValue = false})`, `Future<void> setBool(String key, bool value)`, and constants `speedUnitKey = 'speed_unit'`, `distanceUnitKey = 'distance_unit'`, `locationOnboardingSeenKey = 'location_onboarding_seen'`.
  - `class EnumPreferenceController<T extends Enum> extends StateNotifier<T>` with `Future<void> set(T value)` and `Future<void> get restored`.
  - `appPreferencesProvider: Provider<AppPreferences>` (defaults to `AppPreferences.inMemory()`, overridden in `main.dart`).
  - `GpsWarmupPermissionPreference(AppPreferences preferences)` keeps `hasBeenRequested()` and `markRequested()`.

- [ ] **Step 1: Add the dependency**

In `pubspec.yaml` under `dependencies:` add `shared_preferences: ^2.3.0`, then run `flutter pub get`.

- [ ] **Step 2: Write the failing AppPreferences test**

```dart
// test/unit/app_preferences_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goofyrider_mobile/core/storage/app_preferences.dart';

class MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migrates legacy secure-storage values once and deletes them', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final legacy = MockSecureStorage();
    when(() => legacy.read(key: 'goofyrider_speed_unit')).thenAnswer((_) async => 'mph');
    when(() => legacy.read(key: 'goofyrider_distance_unit')).thenAnswer((_) async => null);
    when(() => legacy.read(key: 'gps_warmup.foreground_permission_requested'))
        .thenAnswer((_) async => 'true');
    when(() => legacy.delete(key: any(named: 'key'))).thenAnswer((_) async {});

    final prefs = await AppPreferences.load(legacyStorage: legacy);

    expect(prefs.getString(AppPreferences.speedUnitKey), 'mph');
    expect(prefs.getString(AppPreferences.distanceUnitKey), isNull);
    expect(prefs.getBool(AppPreferences.locationOnboardingSeenKey), isTrue);
    verify(() => legacy.delete(key: 'goofyrider_speed_unit')).called(1);
    verify(() => legacy.delete(key: 'gps_warmup.foreground_permission_requested')).called(1);

    final again = await AppPreferences.load(legacyStorage: legacy);
    expect(again.getString(AppPreferences.speedUnitKey), 'mph');
    // Exactly one read per legacy key across both loads: the second load is
    // short-circuited by the migrated flag.
    verify(() => legacy.read(key: 'goofyrider_distance_unit')).called(1);
  });

  test('load survives a secure storage that throws', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final legacy = MockSecureStorage();
    when(() => legacy.read(key: any(named: 'key')))
        .thenThrow(PlatformException(code: 'unavailable'));

    final prefs = await AppPreferences.load(legacyStorage: legacy);

    expect(prefs.getBool(AppPreferences.locationOnboardingSeenKey), isFalse);
  });

  test('in-memory preferences round trip', () async {
    final prefs = AppPreferences.inMemory();
    await prefs.setString('k', 'v');
    await prefs.setBool('b', true);

    expect(prefs.getString('k'), 'v');
    expect(prefs.getBool('b'), isTrue);
    expect(prefs.getBool('missing'), isFalse);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/unit/app_preferences_test.dart`
Expected: FAIL, `app_preferences.dart` does not exist.

- [ ] **Step 4: Implement AppPreferences**

```dart
// lib/core/storage/app_preferences.dart
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-secret app preferences (units, onboarding flags). Backed by
/// `shared_preferences` in the app and by a map in tests. Credentials never
/// go here; they stay in `TokenStorage`.
class AppPreferences {
  AppPreferences._(this._store);

  factory AppPreferences.inMemory() => AppPreferences._(_MemoryStore());

  static const String speedUnitKey = 'speed_unit';
  static const String distanceUnitKey = 'distance_unit';
  static const String locationOnboardingSeenKey = 'location_onboarding_seen';
  static const String _legacyMigratedKey = 'legacy_secure_prefs_migrated';

  /// Legacy secure-storage keys (left side) and the preference key each one
  /// migrates into. Values are copied verbatim; `'true'` becomes a bool.
  static const Map<String, String> _legacyKeys = <String, String>{
    'goofyrider_speed_unit': speedUnitKey,
    'goofyrider_distance_unit': distanceUnitKey,
    'gps_warmup.foreground_permission_requested': locationOnboardingSeenKey,
  };

  final _PreferenceStore _store;

  static Future<AppPreferences> load({
    FlutterSecureStorage? legacyStorage,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final instance = AppPreferences._(_SharedPreferencesStore(prefs));
    await instance._migrateLegacy(legacyStorage ?? const FlutterSecureStorage());
    return instance;
  }

  String? getString(String key) => _store.getString(key);

  Future<void> setString(String key, String value) => _store.setString(key, value);

  bool getBool(String key, {bool defaultValue = false}) =>
      _store.getBool(key) ?? defaultValue;

  Future<void> setBool(String key, bool value) => _store.setBool(key, value);

  Future<void> _migrateLegacy(FlutterSecureStorage legacy) async {
    if (_store.getBool(_legacyMigratedKey) ?? false) {
      return;
    }
    for (final entry in _legacyKeys.entries) {
      String? value;
      try {
        value = await legacy.read(key: entry.key);
      } on PlatformException {
        continue;
      } on MissingPluginException {
        continue;
      }
      if (value == null) {
        continue;
      }
      if (entry.value == locationOnboardingSeenKey) {
        await _store.setBool(entry.value, value == 'true');
      } else {
        await _store.setString(entry.value, value);
      }
      try {
        await legacy.delete(key: entry.key);
      } on PlatformException {
        // Best effort; the migrated flag below stops repeat attempts.
      } on MissingPluginException {
        // Same.
      }
    }
    await _store.setBool(_legacyMigratedKey, true);
  }
}

abstract class _PreferenceStore {
  String? getString(String key);
  bool? getBool(String key);
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
}

class _SharedPreferencesStore implements _PreferenceStore {
  _SharedPreferencesStore(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);
  @override
  bool? getBool(String key) => _prefs.getBool(key);
  @override
  Future<void> setString(String key, String value) => _prefs.setString(key, value);
  @override
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);
}

class _MemoryStore implements _PreferenceStore {
  final Map<String, Object> _values = <String, Object>{};

  @override
  String? getString(String key) => _values[key] as String?;
  @override
  bool? getBool(String key) => _values[key] as bool?;
  @override
  Future<void> setString(String key, String value) async => _values[key] = value;
  @override
  Future<void> setBool(String key, bool value) async => _values[key] = value;
}
```

- [ ] **Step 5: Run the AppPreferences test**

Run: `flutter test test/unit/app_preferences_test.dart`
Expected: 3 tests pass.

- [ ] **Step 6: Write the failing controller test**

```dart
// test/unit/enum_preference_controller_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:goofyrider_mobile/core/providers/enum_preference_controller.dart';
import 'package:goofyrider_mobile/core/storage/app_preferences.dart';
import 'package:goofyrider_mobile/core/utils/speed_unit.dart';

void main() {
  const wire = <SpeedUnit, String>{
    SpeedUnit.kilometersPerHour: 'kmh',
    SpeedUnit.metersPerSecond: 'mps',
    SpeedUnit.milesPerHour: 'mph',
  };

  test('restores a stored value on construction', () async {
    final prefs = AppPreferences.inMemory();
    await prefs.setString(AppPreferences.speedUnitKey, 'mph');

    final controller = EnumPreferenceController<SpeedUnit>(
      preferences: prefs,
      key: AppPreferences.speedUnitKey,
      initial: SpeedUnit.kilometersPerHour,
      wireValues: wire,
    );
    await controller.restored;

    expect(controller.state, SpeedUnit.milesPerHour);
  });

  test('set persists the wire value and updates state', () async {
    final prefs = AppPreferences.inMemory();
    final controller = EnumPreferenceController<SpeedUnit>(
      preferences: prefs,
      key: AppPreferences.speedUnitKey,
      initial: SpeedUnit.kilometersPerHour,
      wireValues: wire,
    );
    await controller.restored;

    await controller.set(SpeedUnit.metersPerSecond);

    expect(controller.state, SpeedUnit.metersPerSecond);
    expect(prefs.getString(AppPreferences.speedUnitKey), 'mps');
  });

  test('unknown stored value keeps the initial state', () async {
    final prefs = AppPreferences.inMemory();
    await prefs.setString(AppPreferences.speedUnitKey, 'furlongs');

    final controller = EnumPreferenceController<SpeedUnit>(
      preferences: prefs,
      key: AppPreferences.speedUnitKey,
      initial: SpeedUnit.kilometersPerHour,
      wireValues: wire,
    );
    await controller.restored;

    expect(controller.state, SpeedUnit.kilometersPerHour);
  });
}
```

- [ ] **Step 7: Implement the generic controller and rewire the two unit providers**

```dart
// lib/core/providers/enum_preference_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/app_preferences.dart';

/// Persists an enum-valued preference through [AppPreferences].
/// [wireValues] maps each enum member to the string stored on disk.
class EnumPreferenceController<T extends Enum> extends StateNotifier<T> {
  EnumPreferenceController({
    required AppPreferences preferences,
    required String key,
    required T initial,
    required Map<T, String> wireValues,
  })  : _preferences = preferences,
        _key = key,
        _wireValues = wireValues,
        super(initial) {
    _restore();
  }

  final AppPreferences _preferences;
  final String _key;
  final Map<T, String> _wireValues;

  /// Completes after the stored value (if any) has been applied.
  /// Restoration is synchronous today, but callers await this so the store
  /// can become asynchronous without touching them.
  Future<void> get restored => Future<void>.value();

  Future<void> set(T value) async {
    if (state == value) {
      return;
    }
    state = value;
    final wire = _wireValues[value];
    if (wire != null) {
      await _preferences.setString(_key, wire);
    }
  }

  void _restore() {
    final raw = _preferences.getString(_key);
    if (raw == null) {
      return;
    }
    for (final entry in _wireValues.entries) {
      if (entry.value == raw) {
        state = entry.key;
        return;
      }
    }
  }
}
```

Replace `lib/core/providers/speed_unit_preference_provider.dart` with:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../storage/app_preferences.dart';
import '../utils/speed_unit.dart';
import 'enum_preference_controller.dart';

const Map<SpeedUnit, String> speedUnitWireValues = <SpeedUnit, String>{
  SpeedUnit.kilometersPerHour: 'kmh',
  SpeedUnit.metersPerSecond: 'mps',
  SpeedUnit.milesPerHour: 'mph',
};

class SpeedUnitPreferenceController extends EnumPreferenceController<SpeedUnit> {
  SpeedUnitPreferenceController({required AppPreferences preferences})
      : super(
          preferences: preferences,
          key: AppPreferences.speedUnitKey,
          initial: SpeedUnit.kilometersPerHour,
          wireValues: speedUnitWireValues,
        );

  Future<void> setSpeedUnit(SpeedUnit unit) => set(unit);
}

final speedUnitPreferenceProvider =
    StateNotifierProvider<SpeedUnitPreferenceController, SpeedUnit>(
  (Ref ref) => SpeedUnitPreferenceController(
    preferences: ref.watch(appPreferencesProvider),
  ),
);
```

Replace `lib/core/providers/distance_unit_preference_provider.dart` the same way with `DistanceUnit`, wire values `{DistanceUnit.meters: 'm', DistanceUnit.feet: 'ft'}` named `distanceUnitWireValues`, key `AppPreferences.distanceUnitKey`, initial `DistanceUnit.meters`, class `DistanceUnitPreferenceController`, and a `setDistanceUnit(DistanceUnit unit) => set(unit)` method.

Add to `lib/core/providers.dart`:

```dart
import 'storage/app_preferences.dart';

/// Overridden in `main.dart` with the loaded instance; the in-memory default
/// keeps widget tests and previews working without platform channels.
final appPreferencesProvider = Provider<AppPreferences>(
  (ref) => AppPreferences.inMemory(),
);
```

- [ ] **Step 8: Rewire the onboarding flag and bootstrap**

Replace `lib/features/session/data/gps_warmup_permission_preference.dart`:

```dart
import '../../../core/storage/app_preferences.dart';

/// Persists whether the app has already asked for foreground location
/// permission at startup. The warm-up flow should only prompt once.
class GpsWarmupPermissionPreference {
  GpsWarmupPermissionPreference(this._preferences);

  final AppPreferences _preferences;

  Future<bool> hasBeenRequested() async =>
      _preferences.getBool(AppPreferences.locationOnboardingSeenKey);

  Future<void> markRequested() =>
      _preferences.setBool(AppPreferences.locationOnboardingSeenKey, true);
}
```

In `session_providers.dart` change the provider to
`(ref) => GpsWarmupPermissionPreference(ref.watch(appPreferencesProvider))`.

In `lib/main.dart` `runAppWith`, after `final database = await loader();` add
`final preferences = await preferencesLoader();` and add
`appPreferencesProvider.overrideWithValue(preferences),` to the `overrides` list (import `core/storage/app_preferences.dart`). Add the parameter
`Future<AppPreferences> Function() preferencesLoader = AppPreferences.load,` next to `loader` so `app_bootstrap_test.dart` can pass `preferencesLoader: () async => AppPreferences.inMemory()`.

- [ ] **Step 9: Fix tests that used the old constructors**

Search: `grep -rn "GpsWarmupPermissionPreference(\|PreferenceController(\|runAppWith(" test/`. Replace `storage:`-based constructions with `AppPreferences.inMemory()` (for the warm-up preference: `GpsWarmupPermissionPreference(AppPreferences.inMemory())`; for controllers: `SpeedUnitPreferenceController(preferences: AppPreferences.inMemory())`), and pass `preferencesLoader: () async => AppPreferences.inMemory()` to any `runAppWith` call in tests.

- [ ] **Step 10: Run the affected suites**

Run: `flutter test test/unit/app_preferences_test.dart test/unit/enum_preference_controller_test.dart test/unit/gps_warmup_service_test.dart test/widget/profile_screen_test.dart test/widget/location_onboarding_screen_test.dart test/widget/app_bootstrap_test.dart`
Expected: the new tests pass; the widget suites pass except the three `profile_screen_test.dart` export tests that were already failing before this plan (audit H2). Do not fix those here.

- [ ] **Step 11: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/core lib/features/session/data/gps_warmup_permission_preference.dart lib/features/session/presentation/session_providers.dart lib/main.dart test
git commit -m "refactor(mobile): move unit and onboarding preferences to shared_preferences"
```

---

### Task 5: Android network policy and backup rules

**Files:**
- Create: `android/app/src/main/res/xml/network_security_config.xml`
- Create: `android/app/src/debug/res/xml/network_security_config.xml`
- Create: `android/app/src/main/res/xml/data_extraction_rules.xml`
- Modify: `android/app/src/main/AndroidManifest.xml` (`<application>` attributes)

**Interfaces:**
- Produces: release builds refuse cleartext HTTP; debug builds allow it; no app data is included in cloud or device-to-device backups.

- [ ] **Step 1: Write the release network policy**

```xml
<!-- android/app/src/main/res/xml/network_security_config.xml -->
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
```

(The XML declaration must be the first line of the file; the comment above is only a label for this plan.)

- [ ] **Step 2: Write the debug override**

```xml
<!-- android/app/src/debug/res/xml/network_security_config.xml -->
<?xml version="1.0" encoding="utf-8"?>
<!-- Debug builds talk to a local backend over plain HTTP (10.0.2.2 or a LAN IP). -->
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
```

- [ ] **Step 3: Write the backup exclusion rules**

```xml
<!-- android/app/src/main/res/xml/data_extraction_rules.xml -->
<?xml version="1.0" encoding="utf-8"?>
<data-extraction-rules>
    <cloud-backup>
        <exclude domain="root" />
        <exclude domain="file" />
        <exclude domain="database" />
        <exclude domain="sharedpref" />
        <exclude domain="external" />
    </cloud-backup>
    <device-transfer>
        <exclude domain="root" />
        <exclude domain="file" />
        <exclude domain="database" />
        <exclude domain="sharedpref" />
        <exclude domain="external" />
    </device-transfer>
</data-extraction-rules>
```

- [ ] **Step 4: Reference them from the manifest**

In `AndroidManifest.xml`, change the `<application` element to:

```xml
    <application
        android:label="GoofyRider"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:allowBackup="false"
        android:fullBackupContent="false"
        android:dataExtractionRules="@xml/data_extraction_rules"
        android:networkSecurityConfig="@xml/network_security_config">
```

- [ ] **Step 5: Verify both variants build**

Run: `flutter build apk --debug` and then `flutter build apk --release`
Expected: both succeed. Then confirm the merged resources:
`find build/app/intermediates -name network_security_config.xml` lists a debug and a release copy; `grep -o 'cleartextTrafficPermitted="[a-z]*"' <debug copy>` prints `true` and the release copy prints `false`.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml android/app/src/main/res/xml android/app/src/debug/res/xml
git commit -m "feat(android): enforce HTTPS in release and exclude app data from backups"
```

---

### Task 6: Release signing, shrinking, and README hardening

**Files:**
- Modify: `android/app/build.gradle.kts`
- Create: `android/app/proguard-rules.pro`
- Create: `android/key.properties.example`
- Modify: `README.md` (lines 8 to 9 and 69, plus a new "Release build" section near line 273)

**Interfaces:**
- Produces: a `release` signing config read from `android/key.properties` when present, otherwise the debug key with a Gradle warning; R8 minify and resource shrinking on for release; documented release command with `--obfuscate --split-debug-info`.

- [ ] **Step 1: Add the keystore example**

```properties
# android/key.properties.example
# Copy to android/key.properties (gitignored) and fill in your upload keystore.
# Generate one with:
#   keytool -genkey -v -keystore ~/fall-line-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
storeFile=../../fall-line-upload.jks
storePassword=change-me
keyAlias=upload
keyPassword=change-me
```

`android/.gitignore` already ignores `key.properties`, `**/*.jks`, and `**/*.keystore`; no change needed.

- [ ] **Step 2: Add ProGuard keep rules**

```
# android/app/proguard-rules.pro
# Flutter embedding and the native location bridge are reached by reflection.
-keep class io.flutter.** { *; }
-keep class com.example.goofyrider_mobile.** { *; }
-keep class com.google.android.gms.location.** { *; }
-dontwarn io.flutter.embedding.**
```

- [ ] **Step 3: Update the Gradle build script**

Replace `android/app/build.gradle.kts` with:

```kotlin
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
} else {
    logger.warn("android/key.properties not found: release builds will be signed with the DEBUG key. See android/key.properties.example.")
}

android {
    namespace = "com.example.goofyrider_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // applicationId is renamed on the rename/fall-line branch; do not change it here.
        applicationId = "com.example.goofyrider_mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.gms:play-services-location:21.2.0")
}
```

- [ ] **Step 4: Verify the release build**

Run: `flutter build apk --release --obfuscate --split-debug-info=build/symbols`
Expected: succeeds, Gradle prints the `key.properties not found` warning, and `build/app/outputs/flutter-apk/app-release.apk` exists. Then run `flutter build apk --debug` and `flutter test test/unit/native_android_tracking_repository_test.dart` to confirm nothing else moved.

- [ ] **Step 5: Update the README**

Replace lines 8 to 9 (`This project bundles a pre-populated ... so no keys need to be obtained.`) with:

```markdown
Copy `goofyrider/.env.example` to `goofyrider/.env` and
`goofyrider/mobile/mapbox.json.example` to `goofyrider/mobile/mapbox.json`,
then fill in your own SkiAPI key and Mapbox public token. Never commit or
share the filled-in files.
```

Replace the bullet at line 69 (`--dart-define-from-file=mapbox.json passes the pre-populated Mapbox tile credentials.`) with:

```markdown
- `--dart-define-from-file=mapbox.json` passes your Mapbox tile credentials.
  Omit it and map tiles fall back to OpenStreetMap in debug builds only.
```

Add after the existing release notes (around line 273):

```markdown
### Release build

1. Create an upload keystore and `android/key.properties` (see
   `android/key.properties.example`). Without it the release APK is signed
   with the debug key and must not be distributed.
2. Build with obfuscation and keep the symbol files for crash decoding:

   ```bash
   flutter build apk --release --obfuscate --split-debug-info=build/symbols \
     --dart-define=API_BASE_URL=https://<your-host>/v1 \
     --dart-define-from-file=mapbox.json
   ```

Release builds only talk HTTPS (see
`android/app/src/main/res/xml/network_security_config.xml`); plain
`http://` base URLs work in debug builds only.
```

- [ ] **Step 6: Commit**

```bash
git add android/app/build.gradle.kts android/app/proguard-rules.pro android/key.properties.example README.md
git commit -m "build(android): release signing config, R8 shrinking, and key handling docs"
```

---

### Task 7: Quality gates for the mobile branch

**Files:** none new.

- [ ] **Step 1: Format**

Run: `dart format lib test` then `dart format --set-exit-if-changed lib test`
Expected: exit 0.

- [ ] **Step 2: Analyze**

Run: `flutter analyze`
Expected: no new issues in files touched by this plan. Pre-existing `deprecated_member_use_from_same_package` infos (audit H3) remain and are handled by the cleanup sub-project.

- [ ] **Step 3: Full test run**

Run: `flutter test`
Expected: every test added or modified by this plan passes; the only failures are the pre-existing ones listed in audit H2.

- [ ] **Step 4: Commit any formatting changes**

```bash
git add -A lib test
git commit -m "style(mobile): dart format after security hardening"
```
