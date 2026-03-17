import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/utils/debounce.dart';
import '../../../core/widgets/app_empty_view.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../domain/resort_models.dart';
import 'resort_providers.dart';

class ResortsListScreen extends ConsumerStatefulWidget {
  const ResortsListScreen({super.key});

  @override
  ConsumerState<ResortsListScreen> createState() => _ResortsListScreenState();
}

class _ResortsListScreenState extends ConsumerState<ResortsListScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Debouncer _debouncer = Debouncer(const Duration(milliseconds: 350));

  @override
  void dispose() {
    _searchController.dispose();
    _debouncer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<ResortListResult> state = ref.watch(resortsControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Resorts')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: (String value) {
                _debouncer.run(
                  () => ref.read(resortsControllerProvider.notifier).search(value),
                );
              },
              decoration: const InputDecoration(
                hintText: 'Search resorts',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: state.when(
              loading: () => const AppLoadingView(label: 'Loading resorts...'),
              error: (Object error, StackTrace _) => AppErrorView(
                message: error.toString(),
                onRetry: () => ref.read(resortsControllerProvider.notifier).refresh(),
              ),
              data: (ResortListResult result) {
                if (result.items.isEmpty) {
                  return AppEmptyView(
                    title: 'No resorts found',
                    subtitle: result.usedCache
                        ? 'Offline cache is empty. Connect and retry.'
                        : 'Try adjusting your search.',
                  );
                }

                return RefreshIndicator(
                  onRefresh: () => ref.read(resortsControllerProvider.notifier).refresh(),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: result.items.length,
                    itemBuilder: (BuildContext context, int index) {
                      final ResortSummary resort = result.items[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: ListTile(
                          title: Text(resort.name),
                          subtitle: Text(
                            '${resort.region}, ${resort.country}'
                            '${resort.cachedWeatherText != null ? ' • ${resort.cachedWeatherText}' : ''}',
                          ),
                          trailing: IconButton(
                            icon: Icon(
                              resort.isFavorite ? Icons.favorite : Icons.favorite_border,
                              color: resort.isFavorite
                                  ? Theme.of(context).colorScheme.secondary
                                  : null,
                            ),
                            onPressed: () => ref
                                .read(resortsControllerProvider.notifier)
                                .toggleFavorite(resort),
                          ),
                          onTap: () => context.go(
                            RoutePaths.resortDetail.replaceAll(':resortId', resort.id),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
