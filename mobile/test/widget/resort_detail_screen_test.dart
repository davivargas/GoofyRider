import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:goofyrider_mobile/core/constants/app_constants.dart';
import 'package:goofyrider_mobile/core/providers.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_models.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_repository.dart';
import 'package:goofyrider_mobile/features/resorts/presentation/resort_detail_screen.dart';
import 'package:goofyrider_mobile/features/resorts/presentation/resort_providers.dart';
import 'package:goofyrider_mobile/features/weather/presentation/weather_providers.dart';

class _FakeResortRepository implements ResortRepository {
  _FakeResortRepository({required this.initialResort});

  final ResortSummary initialResort;
  late ResortSummary _current = initialResort;

  @override
  Future<ResortSummary> getResortDetail(String resortId) async {
    return _current;
  }

  @override
  Future<List<ResortSummary>> listFavoriteResorts() async {
    if (_current.isFavorite) {
      return <ResortSummary>[_current];
    }
    return <ResortSummary>[];
  }

  @override
  Future<ResortListResult> searchResorts({
    required String query,
    String? region,
  }) async {
    return ResortListResult(
      items: <ResortSummary>[_current],
      total: 1,
      usedCache: false,
      isStale: false,
    );
  }

  @override
  Future<ResortSummary> toggleFavoriteResort(ResortSummary resort) async {
    _current = resort.copyWith(isFavorite: !resort.isFavorite);
    return _current;
  }
}

ResortSummary _resort({required bool isFavorite}) {
  return ResortSummary(
    id: 'resort-1',
    name: 'Whistler Blackcomb',
    country: 'Canada',
    region: 'BC',
    city: 'Whistler',
    latitude: 50.1163,
    longitude: -122.9574,
    elevationBaseM: 653,
    elevationTopM: 2240,
    isFavorite: isFavorite,
    cachedWeatherText: 'Snow',
    cachedWeatherTempC: -4,
    isStale: false,
  );
}

void main() {
  Widget _buildTestHost({required ResortRepository repository}) {
    return ProviderScope(
      overrides: <Override>[
        resortRepositoryProvider.overrideWithValue(repository),
        resortWeatherProvider.overrideWith(
          (Ref ref, String resortId) async => null,
        ),
        activeMapTileProviderConfigProvider
            .overrideWithValue(MapTileProviderConfig.devFallback),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
            viewInsets: EdgeInsets.zero,
          ),
          child: const ResortDetailScreen(resortId: 'resort-1'),
        ),
      ),
    );
  }

  testWidgets(
      'detail favorite toggle updates to app bar filled amber heart',
      (WidgetTester tester) async {
    final repository =
        _FakeResortRepository(initialResort: _resort(isFavorite: false));

    await tester.pumpWidget(_buildTestHost(repository: repository));

    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.text('Add favorite'), findsNothing);
    expect(find.text('Remove favorite'), findsNothing);

    await tester.tap(find.byTooltip('Add favorite'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite), findsOneWidget);

    final icon = tester.widget<Icon>(find.byIcon(Icons.favorite));
    expect(icon.color, Colors.amber);
  });

  testWidgets(
      'detail favorite toggle updates back to app bar border heart',
      (WidgetTester tester) async {
    final repository =
        _FakeResortRepository(initialResort: _resort(isFavorite: false));

    await tester.pumpWidget(_buildTestHost(repository: repository));

    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add favorite'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsOneWidget);

    await tester.tap(find.byTooltip('Remove favorite'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });

  testWidgets('detail screen keeps info row and start recording action',
      (WidgetTester tester) async {
    final repository =
        _FakeResortRepository(initialResort: _resort(isFavorite: false));

    await tester.pumpWidget(_buildTestHost(repository: repository));
    await tester.pumpAndSettle();

    expect(find.text('Location'), findsNothing);
    expect(find.text('BC, Canada'), findsOneWidget);
    expect(find.text('Whistler'), findsOneWidget);
    expect(find.text('Elevation'), findsOneWidget);
    expect(find.text('Start recording here'), findsOneWidget);
  });
}
