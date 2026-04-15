import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_models.dart';
import 'package:goofyrider_mobile/features/resorts/domain/resort_repository.dart';
import 'package:goofyrider_mobile/features/resorts/presentation/resort_providers.dart';

class _FakeResortRepository implements ResortRepository {
  _FakeResortRepository({required List<ResortSummary> resorts})
      : _resortsById = <String, ResortSummary>{
          for (final ResortSummary resort in resorts) resort.id: resort,
        };

  final Map<String, ResortSummary> _resortsById;

  int searchCalls = 0;
  int detailCalls = 0;
  int toggleCalls = 0;
  int favoriteListCalls = 0;
  Completer<void>? toggleCompleter;

  @override
  Future<ResortSummary> getResortDetail(String resortId) async {
    detailCalls++;
    return _resortsById[resortId]!;
  }

  @override
  Future<List<ResortSummary>> listFavoriteResorts() async {
    favoriteListCalls++;
    return _resortsById.values
        .where((ResortSummary resort) => resort.isFavorite)
        .toList(growable: false);
  }

  @override
  Future<ResortListResult> searchResorts({
    required String query,
    String? region,
  }) async {
    searchCalls++;
    final items =
        _resortsById.values.toList(growable: false);
    return ResortListResult(
      items: items,
      total: items.length,
      usedCache: false,
      isStale: false,
    );
  }

  @override
  Future<ResortSummary> toggleFavoriteResort(ResortSummary resort) async {
    toggleCalls++;
    final completer = toggleCompleter;
    if (completer != null) {
      await completer.future;
    }
    final updated =
        resort.copyWith(isFavorite: !resort.isFavorite);
    _resortsById[resort.id] = updated;
    return updated;
  }
}

ResortSummary _buildResort({required bool isFavorite}) {
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

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
      'ResortsController.toggleFavorite patches list and invalidates favorites and detail providers',
      () async {
    final initial = _buildResort(isFavorite: false);
    final repository =
        _FakeResortRepository(resorts: <ResortSummary>[initial]);
    final container = ProviderContainer(
      overrides: <Override>[
        resortRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final resortsController =
        container.read(resortsControllerProvider.notifier);
    await resortsController.search('');

    final previousDetailController =
        container.read(resortDetailControllerProvider(initial.id).notifier);
    await previousDetailController.load();
    await _flush();

    final previousFavorites =
        await container.read(favoriteResortsProvider.future);
    expect(previousFavorites, isEmpty);
    expect(repository.favoriteListCalls, 1);
    expect(
      container.read(resortsControllerProvider).value?.items.single.isFavorite,
      isFalse,
    );

    await resortsController.toggleFavorite(initial);
    await _flush();

    final refreshedFavorites =
        await container.read(favoriteResortsProvider.future);
    expect(refreshedFavorites, hasLength(1));
    expect(refreshedFavorites.single.isFavorite, isTrue);

    final refreshedDetailController =
        container.read(resortDetailControllerProvider(initial.id).notifier);
    expect(refreshedDetailController, isNot(same(previousDetailController)));

    expect(
      container.read(resortsControllerProvider).value?.items.single.isFavorite,
      isTrue,
    );
  });

  test(
      'ResortDetailController.toggleFavorite updates detail state, list state, and invalidates favorites',
      () async {
    final initial = _buildResort(isFavorite: false);
    final repository =
        _FakeResortRepository(resorts: <ResortSummary>[initial]);
    final container = ProviderContainer(
      overrides: <Override>[
        resortRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final beforeFavorites =
        await container.read(favoriteResortsProvider.future);
    expect(beforeFavorites, isEmpty);
    expect(repository.favoriteListCalls, 1);

    final resortsController =
        container.read(resortsControllerProvider.notifier);
    await resortsController.search('');

    container.read(resortDetailControllerProvider(initial.id));
    await _flush();
    expect(
      container
          .read(resortDetailControllerProvider(initial.id))
          .value
          ?.isFavorite,
      isFalse,
    );

    await container
        .read(resortDetailControllerProvider(initial.id).notifier)
        .toggleFavorite();
    await _flush();

    final afterFavorites =
        await container.read(favoriteResortsProvider.future);

    expect(
      container
          .read(resortDetailControllerProvider(initial.id))
          .value
          ?.isFavorite,
      isTrue,
    );
    expect(
      container.read(resortsControllerProvider).value?.items.single.isFavorite,
      isTrue,
    );
    expect(afterFavorites, hasLength(1));
    expect(afterFavorites.single.isFavorite, isTrue);
    expect(container.read(resortDetailToggleInFlightProvider(initial.id)),
        isFalse);
  });

  test(
      'ResortDetailController exposes in-flight toggle state while request runs',
      () async {
    final initial = _buildResort(isFavorite: false);
    final repository =
        _FakeResortRepository(resorts: <ResortSummary>[initial])
          ..toggleCompleter = Completer<void>();
    final container = ProviderContainer(
      overrides: <Override>[
        resortRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(resortDetailControllerProvider(initial.id));
    await _flush();

    final pendingToggle = container
        .read(resortDetailControllerProvider(initial.id).notifier)
        .toggleFavorite();

    await _flush();
    expect(
        container.read(resortDetailToggleInFlightProvider(initial.id)), isTrue);

    repository.toggleCompleter!.complete();
    await pendingToggle;
    await _flush();

    expect(container.read(resortDetailToggleInFlightProvider(initial.id)),
        isFalse);
    expect(
      container
          .read(resortDetailControllerProvider(initial.id))
          .value
          ?.isFavorite,
      isTrue,
    );
  });
}
