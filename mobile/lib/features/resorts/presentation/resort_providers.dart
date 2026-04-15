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
  (ref) {
    ref.watch(authControllerProvider.select((state) => state.session?.user.id));
    return ResortRepositoryImpl(
      api: ref.watch(resortsApiProvider),
      localDatabase: ref.watch(driftLocalDatabaseProvider),
      currentUserIdGetter: () =>
          ref.read(authControllerProvider).session?.user.id,
    );
  },
);

final resortsControllerProvider =
    StateNotifierProvider<ResortsController, AsyncValue<ResortListResult>>(
  (Ref ref) => ResortsController(
    ref: ref,
    repository: ref.watch(resortRepositoryProvider),
  )..search(''),
);

final resortDetailControllerProvider = StateNotifierProvider.family<
    ResortDetailController, AsyncValue<ResortSummary>, String>(
  (Ref ref, String resortId) {
    final controller = ResortDetailController(
      ref: ref,
      repository: ref.watch(resortRepositoryProvider),
      resortId: resortId,
    );
    controller.load();
    return controller;
  },
);

final resortDetailToggleInFlightProvider =
    StateProvider.family<bool, String>((Ref ref, String resortId) => false);

final favoriteResortsProvider = FutureProvider<List<ResortSummary>>(
  (ref) => ref.watch(resortRepositoryProvider).listFavoriteResorts(),
);

class ResortsController extends StateNotifier<AsyncValue<ResortListResult>> {
  ResortsController({
    required Ref ref,
    required ResortRepository repository,
  })  : _ref = ref,
        _repository = repository,
        super(const AsyncValue.loading());

  final Ref _ref;
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

  void applyFavoriteUpdate(ResortSummary updated) {
    final current = state.value;
    if (current == null) {
      return;
    }

    var hasMatch = false;
    final replaced =
        current.items.map((ResortSummary item) {
      if (item.id != updated.id) {
        return item;
      }

      hasMatch = true;
      return updated;
    }).toList(growable: false);

    if (!hasMatch) {
      return;
    }

    state = AsyncValue.data(
      ResortListResult(
        items: replaced,
        total: current.total,
        usedCache: current.usedCache,
        isStale: current.isStale,
      ),
    );
  }

  Future<void> toggleFavorite(ResortSummary resort) async {
    final previous = state;

    try {
      final updated =
          await _repository.toggleFavoriteResort(resort);
      applyFavoriteUpdate(updated);
      _ref.invalidate(favoriteResortsProvider);
      _ref.invalidate(resortDetailControllerProvider(updated.id));
    } catch (_) {
      state = previous;
    }
  }
}

class ResortDetailController extends StateNotifier<AsyncValue<ResortSummary>> {
  ResortDetailController({
    required Ref ref,
    required ResortRepository repository,
    required String resortId,
  })  : _ref = ref,
        _repository = repository,
        _resortId = resortId,
        super(const AsyncValue.loading());

  final Ref _ref;
  final ResortRepository _repository;
  final String _resortId;

  bool _hasLoaded = false;
  Future<void>? _loadFuture;

  Future<void> load() {
    if (_hasLoaded) {
      return Future<void>.value();
    }

    final inFlight = _loadFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final started = _load();
    _loadFuture = started;
    return started;
  }

  Future<void> _load() async {
    state = const AsyncValue.loading();
    final loaded = await AsyncValue.guard(
      () => _repository.getResortDetail(_resortId),
    );
    state = loaded;
    _hasLoaded = loaded.hasValue;
    _loadFuture = null;
  }

  Future<void> toggleFavorite() async {
    final current = state.value;
    if (current == null) {
      return;
    }

    _ref.read(resortDetailToggleInFlightProvider(_resortId).notifier).state =
        true;
    try {
      final updated =
          await _repository.toggleFavoriteResort(current);
      state = AsyncValue.data(updated);
      _ref
          .read(resortsControllerProvider.notifier)
          .applyFavoriteUpdate(updated);
      _ref.invalidate(favoriteResortsProvider);
    } catch (_) {
      state = AsyncValue.data(current);
    } finally {
      _ref.read(resortDetailToggleInFlightProvider(_resortId).notifier).state =
          false;
    }
  }
}
