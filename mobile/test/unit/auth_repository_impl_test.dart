import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:goofyrider_mobile/core/errors/failures.dart';
import 'package:goofyrider_mobile/core/storage/token_storage.dart';
import 'package:goofyrider_mobile/features/auth/data/auth_api.dart';
import 'package:goofyrider_mobile/features/auth/data/auth_api_models.dart';
import 'package:goofyrider_mobile/features/auth/data/auth_repository_impl.dart';
import 'package:goofyrider_mobile/features/auth/data/device_label_provider.dart';
import 'package:goofyrider_mobile/features/auth/domain/auth_models.dart';

class MockAuthApi extends Mock implements AuthApi {}

class MockTokenStorage extends Mock implements TokenStorage {}

class FakeDeviceLabelProvider extends DeviceLabelProvider {
  @override
  Future<String> resolve() async => 'Test Device / Android 15';
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const StoredTokens(accessToken: 'access', refreshToken: 'refresh'),
    );
  });

  const tokenPair = StoredTokens(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
  );

  const userProfile = UserProfile(
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
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
      deviceLabelProvider: FakeDeviceLabelProvider(),
    );
    final loginPayload = TokenPairResponse(
      accessToken: tokenPair.accessToken,
      refreshToken: tokenPair.refreshToken,
    );

    when(() => authApi.login(
          email: 'test@example.com',
          password: 'password123',
          deviceLabel: any(named: 'deviceLabel'),
        )).thenAnswer((_) async => loginPayload);
    when(() => tokenStorage.write(any<StoredTokens>()))
        .thenAnswer((_) async {});
    when(() => authApi.me(accessToken: tokenPair.accessToken))
        .thenAnswer((_) async => userProfileResponse());

    final session = await repository.login(
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
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
      deviceLabelProvider: FakeDeviceLabelProvider(),
    );
    final registerPayload = TokenPairResponse(
      accessToken: tokenPair.accessToken,
      refreshToken: tokenPair.refreshToken,
    );
    final meFailure = DioException(
      requestOptions: RequestOptions(path: '/auth/me'),
      type: DioExceptionType.connectionError,
      message: 'Network unavailable',
    );

    when(() => authApi.register(
          email: 'test@example.com',
          password: 'password123',
          displayName: 'Tester',
          deviceLabel: any(named: 'deviceLabel'),
        )).thenAnswer((_) async => registerPayload);
    when(() => tokenStorage.write(any<StoredTokens>()))
        .thenAnswer((_) async {});
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
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
      deviceLabelProvider: FakeDeviceLabelProvider(),
    );
    final cachedTokens = const StoredTokens(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      userId: 'user-1',
      email: 'test@example.com',
      displayName: 'Tester',
    );
    final offlineError = DioException(
      requestOptions: RequestOptions(path: '/auth/me'),
      type: DioExceptionType.connectionError,
      message: 'Network unavailable',
    );

    when(() => tokenStorage.read()).thenAnswer((_) async => cachedTokens);
    when(() => authApi.me(accessToken: cachedTokens.accessToken))
        .thenThrow(offlineError);

    final session = await repository.restoreSession();

    expect(session, isNotNull);
    expect(session!.user.id, cachedTokens.userId);
    expect(session.user.email, cachedTokens.email);
    expect(session.user.displayName, cachedTokens.displayName);
    expect(session.accessToken, cachedTokens.accessToken);
    expect(session.refreshToken, cachedTokens.refreshToken);
    verifyNever(() => tokenStorage.clear());
    verifyNever(() => tokenStorage.write(any<StoredTokens>()));
  });

  test(
      'restoreSession clears tokens when refreshed identity lookup fails online',
      () async {
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
      deviceLabelProvider: FakeDeviceLabelProvider(),
    );
    final cachedTokens = const StoredTokens(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      userId: 'user-1',
      email: 'test@example.com',
      displayName: 'Tester',
    );
    final meRequest = RequestOptions(path: '/auth/me');
    final expiredAccess = DioException(
      requestOptions: meRequest,
      response: Response<dynamic>(
        requestOptions: meRequest,
        statusCode: 401,
      ),
      type: DioExceptionType.badResponse,
    );
    final refreshPayload = TokenPairResponse(
      accessToken: 'new-access-token',
      refreshToken: 'refresh-token',
    );
    final rejectedMe = DioException(
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
    when(() => authApi.refresh(
          refreshToken: cachedTokens.refreshToken,
          deviceLabel: any(named: 'deviceLabel'),
        )).thenAnswer((_) async => refreshPayload);
    when(() => authApi.me(accessToken: 'new-access-token'))
        .thenThrow(rejectedMe);
    when(() => tokenStorage.write(any<StoredTokens>()))
        .thenAnswer((_) async {});
    when(() => tokenStorage.clear()).thenAnswer((_) async {});

    final session = await repository.restoreSession();

    expect(session, isNull);
    verify(() => tokenStorage.clear()).called(1);
  });

  test(
      'refreshAccessToken throws AuthFailure when the backend rejects the token',
      () async {
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
      deviceLabelProvider: FakeDeviceLabelProvider(),
    );
    final options = RequestOptions(path: '/auth/refresh');
    when(() => authApi.refresh(
          refreshToken: 'stale',
          deviceLabel: any(named: 'deviceLabel'),
        )).thenThrow(
      DioException(
        requestOptions: options,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: 401,
          data: <String, dynamic>{
            'detail': 'Invalid or expired refresh token.'
          },
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
      deviceLabelProvider: FakeDeviceLabelProvider(),
    );
    when(() => authApi.refresh(
          refreshToken: 'offline',
          deviceLabel: any(named: 'deviceLabel'),
        )).thenThrow(
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
      deviceLabelProvider: FakeDeviceLabelProvider(),
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
    when(() => authApi.refresh(
          refreshToken: tokenPair.refreshToken,
          deviceLabel: any(named: 'deviceLabel'),
        )).thenThrow(
      DioException(
        requestOptions: refreshOptions,
        response:
            Response<dynamic>(requestOptions: refreshOptions, statusCode: 401),
        type: DioExceptionType.badResponse,
      ),
    );
    when(() => tokenStorage.clear()).thenAnswer((_) async {});

    final session = await repository.restoreSession();

    expect(session, isNull);
    verify(() => tokenStorage.clear()).called(1);
  });

  test('restoreSession keeps the rotated refresh token after refreshing',
      () async {
    final authApi = MockAuthApi();
    final tokenStorage = MockTokenStorage();
    final repository = AuthRepositoryImpl(
      authApi: authApi,
      tokenStorage: tokenStorage,
      deviceLabelProvider: FakeDeviceLabelProvider(),
    );
    const storedTokens = StoredTokens(
      accessToken: 'access-0',
      refreshToken: 'refresh-0',
      userId: 'user-1',
      email: 'test@example.com',
      displayName: 'Tester',
    );
    final meRequest = RequestOptions(path: '/auth/me');
    final expiredAccess = DioException(
      requestOptions: meRequest,
      response: Response<dynamic>(
        requestOptions: meRequest,
        statusCode: 401,
      ),
      type: DioExceptionType.badResponse,
    );

    when(() => tokenStorage.read()).thenAnswer((_) async => storedTokens);
    when(() => tokenStorage.write(any<StoredTokens>()))
        .thenAnswer((_) async {});
    when(() => tokenStorage.clear()).thenAnswer((_) async {});
    when(() => authApi.me(accessToken: 'access-0')).thenThrow(expiredAccess);
    when(() => authApi.refresh(
          refreshToken: 'refresh-0',
          deviceLabel: any(named: 'deviceLabel'),
        )).thenAnswer(
      (_) async => const TokenPairResponse(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
      ),
    );
    when(() => authApi.me(accessToken: 'access-1'))
        .thenAnswer((_) async => userProfileResponse());

    final session = await repository.restoreSession();

    expect(session, isNotNull);
    expect(session!.accessToken, 'access-1');
    expect(session.refreshToken, 'refresh-1');

    final written =
        verify(() => tokenStorage.write(captureAny<StoredTokens>())).captured;
    expect(written, isNotEmpty);
    final lastWrite = written.last as StoredTokens;
    expect(lastWrite.refreshToken, 'refresh-1');
    expect(lastWrite.accessToken, 'access-1');
    verifyNever(() => tokenStorage.clear());
  });

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
    when(() => tokenStorage.write(any<StoredTokens>()))
        .thenAnswer((_) async {});
    when(() => authApi.me(accessToken: tokenPair.accessToken))
        .thenAnswer((_) async => userProfileResponse());

    await repository.login(email: 'a@b.c', password: 'pw');

    verify(() => authApi.login(
          email: 'a@b.c',
          password: 'pw',
          deviceLabel: 'Test Device / Android 15',
        )).called(1);
  });
}
