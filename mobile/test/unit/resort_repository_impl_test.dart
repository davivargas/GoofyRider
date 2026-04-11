import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:goofyrider_mobile/core/storage/drift_local_database.dart';
import 'package:goofyrider_mobile/features/resorts/data/resort_repository_impl.dart';
import 'package:goofyrider_mobile/features/resorts/data/resorts_api.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_models.dart';

class MockDriftLocalDatabase extends Mock implements DriftLocalDatabase {}

class MockResortsApi extends Mock implements ResortsApi {}

class FavoritesFailingResortRepository extends ResortRepositoryImpl {
  FavoritesFailingResortRepository({
    required super.api,
    required super.localDatabase,
    required super.currentUserIdGetter,
  });

  @override
  Future<List<ResortSummary>> listFavoriteResorts() async {
    throw DioException(
      requestOptions: RequestOptions(path: '/users/me/favorites'),
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/users/me/favorites'),
        statusCode: 500,
      ),
    );
  }
}

Map<String, dynamic> _resortJson({
  required String id,
  required String name,
}) {
  return <String, dynamic>{
    'id': id,
    'name': name,
    'country': 'Canada',
    'region': 'British Columbia',
    'city': 'Whistler',
    'latitude': 50.0,
    'longitude': -122.0,
    'elevation_base_m': 700,
    'elevation_top_m': 2200,
  };
}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  late MockDriftLocalDatabase localDatabase;
  late MockResortsApi api;
  late FavoritesFailingResortRepository repository;
  late ResortRepositoryImpl baseRepository;
  late String? currentUserId;

  setUp(() {
    currentUserId = 'user-1';
    localDatabase = MockDriftLocalDatabase();
    api = MockResortsApi();
    repository = FavoritesFailingResortRepository(
      api: api,
      localDatabase: localDatabase,
      currentUserIdGetter: () => currentUserId,
    );
    baseRepository = ResortRepositoryImpl(
      api: api,
      localDatabase: localDatabase,
      currentUserIdGetter: () => currentUserId,
    );

    when(
      () => localDatabase.upsertCachedResort(
        any(),
        any(),
        ownerUserId: any(named: 'ownerUserId'),
      ),
    )
        .thenAnswer((_) async {});
    when(() => localDatabase.readCachedWeather(any()))
        .thenAnswer((_) async => null);
    when(
      () => localDatabase.readCachedResorts(
        ownerUserId: any(named: 'ownerUserId'),
      ),
    )
        .thenAnswer((_) async => <Map<String, dynamic>>[]);
  });

  test('searchResorts returns public payload when favorites lookup fails',
      () async {
    when(() => api.listResorts(query: 'whistler', region: null)).thenAnswer(
      (_) async => <String, dynamic>{
        'items': <Map<String, dynamic>>[
          _resortJson(id: 'whistler', name: 'Whistler Blackcomb'),
        ],
        'total': 1,
      },
    );

    final ResortListResult result =
        await repository.searchResorts(query: 'whistler');

    expect(result.usedCache, isFalse);
    expect(result.isStale, isFalse);
    expect(result.total, 1);
    expect(result.items, hasLength(1));
    expect(result.items.single.id, 'whistler');
    expect(result.items.single.isFavorite, isFalse);
    verify(
      () => localDatabase.upsertCachedResort(
        'whistler',
        any(),
        ownerUserId: 'user-1',
      ),
    ).called(1);
  });

  test('getResortDetail returns public payload when favorites lookup fails',
      () async {
    when(() => api.getResortDetail('whistler')).thenAnswer(
      (_) async => _resortJson(id: 'whistler', name: 'Whistler Blackcomb'),
    );

    final ResortSummary result = await repository.getResortDetail('whistler');

    expect(result.id, 'whistler');
    expect(result.name, 'Whistler Blackcomb');
    expect(result.isFavorite, isFalse);
    expect(result.isStale, isFalse);
    verify(
      () => localDatabase.upsertCachedResort(
        'whistler',
        any(),
        ownerUserId: 'user-1',
      ),
    ).called(1);
  });

  test('toggleFavoriteResort writes updated favorite state to cache', () async {
    const ResortSummary resort = ResortSummary(
      id: 'whistler',
      name: 'Whistler Blackcomb',
      country: 'Canada',
      region: 'British Columbia',
      city: 'Whistler',
      latitude: 50.0,
      longitude: -122.0,
      elevationBaseM: 700,
      elevationTopM: 2200,
      isFavorite: true,
      cachedWeatherText: null,
      cachedWeatherTempC: null,
      isStale: false,
    );
    when(() => api.removeFavorite('whistler')).thenAnswer((_) async {});

    final ResortSummary updated =
        await baseRepository.toggleFavoriteResort(resort);

    expect(updated.isFavorite, isFalse);
    final List<dynamic> captured = verify(
      () => localDatabase.upsertCachedResort(
        captureAny(),
        captureAny(),
        ownerUserId: captureAny(named: 'ownerUserId'),
      ),
    ).captured;
    expect(captured, hasLength(3));
    expect(captured[0], 'whistler');
    expect((captured[1] as Map<String, dynamic>)['is_favorite'], isFalse);
    expect(captured[2], 'user-1');
  });

  test('listFavoriteResorts clears stale cached favorites not in payload',
      () async {
    when(() => api.listFavoriteResorts()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        _resortJson(id: 'whistler', name: 'Whistler Blackcomb'),
      ],
    );
    when(
      () => localDatabase.readCachedResorts(
        ownerUserId: any(named: 'ownerUserId'),
      ),
    ).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        <String, dynamic>{
          ..._resortJson(id: 'whistler', name: 'Whistler Blackcomb'),
          'is_favorite': true,
        },
        <String, dynamic>{
          ..._resortJson(id: 'zermatt', name: 'Zermatt'),
          'is_favorite': true,
          'cached_fetched_at': '2026-03-22T00:00:00.000Z',
        },
      ],
    );

    final List<ResortSummary> favorites =
        await baseRepository.listFavoriteResorts();

    expect(favorites, hasLength(1));
    expect(favorites.single.id, 'whistler');
    expect(favorites.single.isFavorite, isTrue);

    final List<dynamic> captured = verify(
      () => localDatabase.upsertCachedResort(
        captureAny(),
        captureAny(),
        ownerUserId: captureAny(named: 'ownerUserId'),
      ),
    ).captured;
    expect(captured, hasLength(6));
    expect(captured[0], 'whistler');
    expect((captured[1] as Map<String, dynamic>)['is_favorite'], isTrue);
    expect(captured[2], 'user-1');
    expect(captured[3], 'zermatt');
    expect((captured[4] as Map<String, dynamic>)['is_favorite'], isFalse);
    expect(
      (captured[4] as Map<String, dynamic>).containsKey('cached_fetched_at'),
      isFalse,
    );
    expect(captured[5], 'user-1');
  });
}
