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

  setUp(() {
    localDatabase = MockDriftLocalDatabase();
    api = MockResortsApi();
    repository = FavoritesFailingResortRepository(
      api: api,
      localDatabase: localDatabase,
    );

    when(() => localDatabase.upsertCachedResort(any(), any()))
        .thenAnswer((_) async {});
    when(() => localDatabase.readCachedWeather(any()))
        .thenAnswer((_) async => null);
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
    verify(() => localDatabase.upsertCachedResort('whistler', any())).called(1);
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
    verify(() => localDatabase.upsertCachedResort('whistler', any())).called(1);
  });
}
