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
  Future<void> _scrollToLabel(WidgetTester tester, String label) async {
    final Finder target = find.text(label, skipOffstage: false);
    expect(target, findsOneWidget);
    await tester.dragUntilVisible(
      target,
      find.byType(ListView),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
  }

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
      'detail favorite toggle updates to remove favorite label and amber heart',
      (WidgetTester tester) async {
    final _FakeResortRepository repository =
        _FakeResortRepository(initialResort: _resort(isFavorite: false));

    await tester.pumpWidget(_buildTestHost(repository: repository));

    await tester.pumpAndSettle();

    await _scrollToLabel(tester, 'Add favorite');

    expect(find.text('Add favorite'), findsOneWidget);
    expect(find.text('Remove favorite'), findsNothing);

    await tester.tap(find.text('Add favorite'));
    await tester.pumpAndSettle();

    expect(find.text('Remove favorite'), findsOneWidget);

    final Icon icon = tester.widget<Icon>(find.byIcon(Icons.favorite));
    expect(icon.color, Colors.amber);
  });

  testWidgets(
      'detail favorite toggle updates back to add favorite label and border icon',
      (WidgetTester tester) async {
    final _FakeResortRepository repository =
        _FakeResortRepository(initialResort: _resort(isFavorite: false));

    await tester.pumpWidget(_buildTestHost(repository: repository));

    await tester.pumpAndSettle();

    await _scrollToLabel(tester, 'Add favorite');

    await tester.tap(find.text('Add favorite'));
    await tester.pumpAndSettle();
    expect(find.text('Remove favorite'), findsOneWidget);

    await tester.tap(find.text('Remove favorite'));
    await tester.pumpAndSettle();

    expect(find.text('Add favorite'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });
}
