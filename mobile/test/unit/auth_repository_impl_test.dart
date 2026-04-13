import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:goofyrider_mobile/core/storage/token_storage.dart';
import 'package:goofyrider_mobile/features/auth/data/auth_api.dart';
import 'package:goofyrider_mobile/features/auth/data/auth_api_models.dart';
import 'package:goofyrider_mobile/features/auth/data/auth_repository_impl.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_models.dart';

class MockAuthApi extends Mock implements AuthApi {}

class MockTokenStorage extends Mock implements TokenStorage {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const StoredTokens(accessToken: 'access', refreshToken: 'refresh'),
    );
  });

  const StoredTokens tokenPair = StoredTokens(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
  );

  const UserProfile userProfile = UserProfile(
    id: 'user-1',
    email: 'test@example.com',
    displayName: 'Tester',
  );

  UserProfileResponse userProfileResponse() => UserProfileResponse(
        id: userProfile.id,
        email: userProfile.email,
        displayName: userProfile.displayName,
      );

  test('login persists the token pair before hydrating the profile', () async {
    final MockAuthApi authApi = MockAuthApi();
    final MockTokenStorage tokenStorage = MockTokenStorage();
    final AuthRepositoryImpl repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
    );
    final TokenPairResponse loginPayload = TokenPairResponse(
      accessToken: tokenPair.accessToken,
      refreshToken: tokenPair.refreshToken,
    );

    when(() => authApi.login(
      email: 'test@example.com',
      password: 'password123',
    )).thenAnswer((_) async => loginPayload);
    when(() => tokenStorage.write(any<StoredTokens>())).thenAnswer((_) async {});
    when(() => authApi.me(accessToken: tokenPair.accessToken))
        .thenAnswer((_) async => userProfileResponse());

    final AuthSession session = await repository.login(
      email: 'Test@Example.com',
      password: 'password123',
    );

    expect(session.accessToken, tokenPair.accessToken);
    expect(session.refreshToken, tokenPair.refreshToken);
    expect(session.user.id, userProfile.id);
    expect(session.user.email, userProfile.email);
    expect(session.user.displayName, userProfile.displayName);
    verifyInOrder(<void Function()>[
      () => tokenStorage.write(any<StoredTokens>()),
      () => authApi.me(accessToken: tokenPair.accessToken),
      () => tokenStorage.write(any<StoredTokens>()),
    ]);
  });

  test('register keeps the token pair when profile hydration fails', () async {
    final MockAuthApi authApi = MockAuthApi();
    final MockTokenStorage tokenStorage = MockTokenStorage();
    final AuthRepositoryImpl repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
    );
    final TokenPairResponse registerPayload = TokenPairResponse(
      accessToken: tokenPair.accessToken,
      refreshToken: tokenPair.refreshToken,
    );
    final DioException meFailure = DioException(
      requestOptions: RequestOptions(path: '/auth/me'),
      type: DioExceptionType.connectionError,
      message: 'Network unavailable',
    );

    when(() => authApi.register(
      email: 'test@example.com',
      password: 'password123',
      displayName: 'Tester',
    )).thenAnswer((_) async => registerPayload);
    when(() => tokenStorage.write(any<StoredTokens>())).thenAnswer((_) async {});
    when(() => authApi.me(accessToken: tokenPair.accessToken))
        .thenThrow(meFailure);

    await expectLater(
      repository.register(
        email: 'Test@Example.com',
        password: 'password123',
        displayName: ' Tester ',
      ),
      throwsA(isA<DioException>()),
    );

    verifyInOrder(<void Function()>[
      () => tokenStorage.write(any<StoredTokens>()),
      () => authApi.me(accessToken: tokenPair.accessToken),
    ]);
    verifyNever(() => tokenStorage.clear());
  });

  test('restoreSession keeps cached identity when the backend is offline',
      () async {
    final MockAuthApi authApi = MockAuthApi();
    final MockTokenStorage tokenStorage = MockTokenStorage();
    final AuthRepositoryImpl repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
    );
    final StoredTokens cachedTokens = const StoredTokens(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      userId: 'user-1',
      email: 'test@example.com',
      displayName: 'Tester',
    );
    final DioException offlineError = DioException(
      requestOptions: RequestOptions(path: '/auth/me'),
      type: DioExceptionType.connectionError,
      message: 'Network unavailable',
    );

    when(() => tokenStorage.read()).thenAnswer((_) async => cachedTokens);
    when(() => authApi.me(accessToken: cachedTokens.accessToken))
        .thenThrow(offlineError);

    final AuthSession? session = await repository.restoreSession();

    expect(session, isNotNull);
    expect(session!.user.id, cachedTokens.userId);
    expect(session.user.email, cachedTokens.email);
    expect(session.user.displayName, cachedTokens.displayName);
    expect(session.accessToken, cachedTokens.accessToken);
    expect(session.refreshToken, cachedTokens.refreshToken);
    verifyNever(() => tokenStorage.clear());
    verifyNever(() => tokenStorage.write(any<StoredTokens>()));
  });

  test('restoreSession clears tokens when refreshed identity lookup fails online',
      () async {
    final MockAuthApi authApi = MockAuthApi();
    final MockTokenStorage tokenStorage = MockTokenStorage();
    final AuthRepositoryImpl repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
    );
    final StoredTokens cachedTokens = const StoredTokens(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      userId: 'user-1',
      email: 'test@example.com',
      displayName: 'Tester',
    );
    final RequestOptions meRequest = RequestOptions(path: '/auth/me');
    final DioException expiredAccess = DioException(
      requestOptions: meRequest,
      response: Response<dynamic>(
        requestOptions: meRequest,
        statusCode: 401,
      ),
      type: DioExceptionType.badResponse,
    );
    final TokenPairResponse refreshPayload = TokenPairResponse(
      accessToken: 'new-access-token',
      refreshToken: 'refresh-token',
    );
    final DioException rejectedMe = DioException(
      requestOptions: meRequest,
      response: Response<dynamic>(
        requestOptions: meRequest,
        statusCode: 401,
      ),
      type: DioExceptionType.badResponse,
    );

    when(() => tokenStorage.read()).thenAnswer((_) async => cachedTokens);
    when(() => authApi.me(accessToken: cachedTokens.accessToken))
        .thenThrow(expiredAccess);
    when(() => authApi.refresh(refreshToken: cachedTokens.refreshToken))
        .thenAnswer((_) async => refreshPayload);
    when(() => authApi.me(accessToken: 'new-access-token'))
        .thenThrow(rejectedMe);
    when(() => tokenStorage.write(any<StoredTokens>()))
        .thenAnswer((_) async {});
    when(() => tokenStorage.clear()).thenAnswer((_) async {});

    final AuthSession? session = await repository.restoreSession();

    expect(session, isNull);
    verify(() => tokenStorage.clear()).called(1);
  });
}
