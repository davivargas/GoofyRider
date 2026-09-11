import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/utils/debounce.dart';
import '../../../core/widgets/app_empty_view.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_loading_view.dart';
import '../../../core/widgets/design_widgets.dart';
import '../domain/resort_models.dart';
import 'resort_providers.dart';
import '../../../app/shell/app_tab_bar.dart';

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
    final state = ref.watch(resortsControllerProvider);
    final t = context.tokens;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
              child: Text('RESORTS', style: Theme.of(context).textTheme.headlineSmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
              child: TextField(
                controller: _searchController,
                onChanged: (String value) {
                  _debouncer.run(() => ref.read(resortsControllerProvider.notifier).search(value));
                },
                decoration: InputDecoration(
                  hintText: 'Search resorts…',
                  prefixIcon: Icon(Icons.search, size: 18, color: t.textMuted),
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
                      subtitle: result.usedCache ? 'Offline cache is empty. Connect and retry.' : 'Try adjusting your search.',
                    );
                  }
                  final hasFavorite = result.items.any((ResortSummary r) => r.isFavorite);
                  return RefreshIndicator(
                    onRefresh: () => ref.read(resortsControllerProvider.notifier).refresh(),
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(24, 8, 24, AppTabBar.bottomClearance(context) + 24),
                      itemCount: result.items.length + 1,
                      itemBuilder: (BuildContext context, int index) {
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
                            child: MonoLabel(hasFavorite ? 'Favorites first' : 'All resorts', size: 8, tone: MonoTone.muted, letterSpacing: 1.8),
                          );
                        }
                        return _ResortRow(resort: result.items[index - 1]);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResortRow extends ConsumerWidget {
  const _ResortRow({required this.resort});

  final ResortSummary resort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final weather = resort.cachedWeatherText;
    final temp = resort.cachedWeatherTempC;
    final chip = <String>[
      if (temp != null) '${temp.toStringAsFixed(0)}°',
      if (weather != null && weather.trim().isNotEmpty) weather,
    ].join(' · ');

    return InkWell(
      onTap: () => context.go(RoutePaths.resortDetail.replaceAll(':resortId', resort.id)),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(resort.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  MonoLabel('${resort.region}, ${resort.country}', size: 8, tone: MonoTone.muted, letterSpacing: 1.1, maxLines: 1),
                ],
              ),
            ),
            if (chip.isNotEmpty) ...<Widget>[
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: t.raised, borderRadius: BorderRadius.circular(6)),
                child: MonoLabel(chip, size: 9, weight: FontWeight.w700, letterSpacing: 1, maxLines: 1),
              ),
            ],
            IconButton(
              icon: Icon(
                resort.isFavorite ? Icons.favorite : Icons.favorite_border,
                color: resort.isFavorite ? t.voltText : t.textMuted,
                size: 18,
              ),
              onPressed: () => ref.read(resortsControllerProvider.notifier).toggleFavorite(resort),
            ),
          ],
        ),
      ),
    );
  }
}
