import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_models.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_repository.dart';
import 'package:goofyrider_mobile/features/resorts/presentation/resort_providers.dart';
import 'package:goofyrider_mobile/features/resorts/presentation/resorts_list_screen.dart';

class NoopResortRepository implements ResortRepository {
  @override
  Future<ResortSummary> getResortDetail(String resortId) async {
    throw UnimplementedError();
  }

  @override
  Future<List<ResortSummary>> listFavoriteResorts() async => <ResortSummary>[];

  @override
  Future<ResortListResult> searchResorts({required String query, String? region}) async {
    return const ResortListResult(items: <ResortSummary>[], total: 0, usedCache: false, isStale: false);
  }

  @override
  Future<ResortSummary> toggleFavoriteResort(ResortSummary resort) async => resort;
}

class TestResortsController extends ResortsController {
  TestResortsController(AsyncValue<ResortListResult> initial)
      : super(NoopResortRepository()) {
    state = initial;
  }
}

void main() {
  testWidgets('resorts screen shows empty state', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          resortsControllerProvider.overrideWith(
            (Ref ref) => TestResortsController(
              const AsyncValue.data(
                ResortListResult(items: <ResortSummary>[], total: 0, usedCache: false, isStale: false),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: ResortsListScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('No resorts found'), findsOneWidget);
  });

  testWidgets('resorts screen shows list in success state', (WidgetTester tester) async {
    const ResortSummary resort = ResortSummary(
      id: 'r-1',
      name: 'Whistler',
      country: 'Canada',
      region: 'British Columbia',
      city: 'Whistler',
      latitude: 50.1,
      longitude: -122.9,
      elevationBaseM: 700,
      elevationTopM: 2200,
      isFavorite: true,
      cachedWeatherText: 'Snow',
      cachedWeatherTempC: -2,
      isStale: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          resortsControllerProvider.overrideWith(
            (Ref ref) => TestResortsController(
              const AsyncValue.data(
                ResortListResult(items: <ResortSummary>[resort], total: 1, usedCache: false, isStale: false),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: ResortsListScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Whistler'), findsOneWidget);
    expect(find.byType(ListTile), findsWidgets);
  });
}
