import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/resort_repository_impl.dart';
import '../data/resorts_api.dart';
import '../domain/resort_models.dart';
import '../domain/resort_repository.dart';

final resortsApiProvider = Provider<ResortsApi>(
  (ref) => ResortsApi(ref.watch(authorizedDioProvider)),
);

final resortRepositoryProvider = Provider<ResortRepository>(
  (ref) => ResortRepositoryImpl(
    api: ref.watch(resortsApiProvider),
    localDatabase: ref.watch(driftLocalDatabaseProvider),
  ),
);

final resortsControllerProvider =
    StateNotifierProvider<ResortsController, AsyncValue<ResortListResult>>(
  (ref) => ResortsController(ref.watch(resortRepositoryProvider))..search(''),
);

final resortDetailProvider = FutureProvider.family<ResortSummary, String>(
  (ref, resortId) => ref.watch(resortRepositoryProvider).getResortDetail(resortId),
);

final favoriteResortsProvider = FutureProvider<List<ResortSummary>>(
  (ref) => ref.watch(resortRepositoryProvider).listFavoriteResorts(),
);

class ResortsController extends StateNotifier<AsyncValue<ResortListResult>> {
  ResortsController(this._repository) : super(const AsyncValue.loading());

  final ResortRepository _repository;

  String _lastQuery = '';
  String? _lastRegion;

  Future<void> search(String query, {String? region}) async {
    _lastQuery = query;
    _lastRegion = region;
    state = const AsyncValue.loading();

    state = await AsyncValue.guard(
      () => _repository.searchResorts(query: query, region: region),
    );
  }

  Future<void> refresh() {
    return search(_lastQuery, region: _lastRegion);
  }

  Future<void> toggleFavorite(ResortSummary resort) async {
    final AsyncValue<ResortListResult> previous = state;

    try {
      final ResortSummary updated = await _repository.toggleFavoriteResort(resort);
      final ResortListResult? current = state.value;
      if (current == null) {
        await refresh();
        return;
      }

      final List<ResortSummary> replaced = current.items
          .map(
            (ResortSummary item) => item.id == updated.id ? updated : item,
          )
          .toList(growable: false);

      state = AsyncValue.data(
        ResortListResult(
          items: replaced,
          total: current.total,
          usedCache: current.usedCache,
          isStale: current.isStale,
        ),
      );
    } catch (_) {
      state = previous;
    }
  }
}
