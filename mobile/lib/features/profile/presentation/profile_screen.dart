import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/providers.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/speed_unit.dart';
import '../../../core/widgets/design_widgets.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../session/domain/session_models.dart';
import '../../session/presentation/season_summary.dart';
import '../../session/presentation/session_providers.dart';
import 'debug_export_service.dart';
import '../../../app/shell/app_tab_bar.dart';

typedef DebugExportAction = Future<String> Function({
  required String ownerUserId,
  required String? userEmail,
  required SpeedUnit speedUnit,
  required DistanceUnit distanceUnit,
});

final debugExportActionProvider = Provider<DebugExportAction>((ref) {
  final service = DebugExportService(
    localDatabase: ref.watch(driftLocalDatabaseProvider),
  );
  return ({
    required String ownerUserId,
    required String? userEmail,
    required SpeedUnit speedUnit,
    required DistanceUnit distanceUnit,
  }) async {
    final file = await service.export(
      ownerUserId: ownerUserId,
      userEmail: userEmail,
      speedUnit: speedUnit,
      distanceUnit: distanceUnit,
    );
    return file.path;
  };
});

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final speedUnit = ref.watch(speedUnitPreferenceProvider);
    final distanceUnit = ref.watch(distanceUnitPreferenceProvider);
    final history = ref.watch(historyProvider);
    final t = context.tokens;
    final name = authState.session?.user.displayName ?? 'Guest';
    final email = authState.session?.user.email ?? 'Not signed in';

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 24,
            24, AppTabBar.bottomClearance(context) + 24),
        children: <Widget>[
          Row(
            children: <Widget>[
              InitialsAvatar(name: name, size: 56, ring: true),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(name, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 3),
                    MonoLabel(email,
                        size: 11,
                        tone: MonoTone.muted,
                        letterSpacing: 0.8,
                        uppercase: false,
                        maxLines: 1),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          history.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (List<LocalRideSession> sessions) {
              final s = buildSeasonSummary(sessions, now: DateTime.now());
              return SurfaceCard(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    MonoLabel('Season ${shortSeasonLabel(s.label)}',
                        size: 8, tone: MonoTone.muted, letterSpacing: 1.8),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 26,
                      runSpacing: 12,
                      children: <Widget>[
                        StatBlock(
                            value: '${s.daysRidden}',
                            label: 'Days',
                            size: StatSize.large),
                        StatBlock(
                            value: distanceUnit.formatFromMeters(s.totalVertM),
                            label: 'Vert',
                            size: StatSize.large),
                        StatBlock(
                            value: speedUnit
                                .convertFromMetersPerSecond(s.topSpeedMps)
                                .toStringAsFixed(1),
                            label: 'Top ${speedUnit.shortLabel}',
                            size: StatSize.large),
                        StatBlock(
                            value: '${s.sessionCount}',
                            label: 'Sessions',
                            size: StatSize.large),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 22),
          SurfaceCard(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const MonoLabel('Units',
                    size: 10, tone: MonoTone.muted, letterSpacing: 1.8),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text('Speed',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: t.textSecondary,
                            fontWeight: FontWeight.w600)),
                    PillToggle<SpeedUnit>(
                      options: const <(SpeedUnit, String)>[
                        (SpeedUnit.kilometersPerHour, 'KM/H'),
                        (SpeedUnit.milesPerHour, 'MPH'),
                        (SpeedUnit.metersPerSecond, 'M/S'),
                      ],
                      selected: speedUnit,
                      onChanged: (SpeedUnit v) => ref
                          .read(speedUnitPreferenceProvider.notifier)
                          .setSpeedUnit(v),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text('Distance',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: t.textSecondary,
                            fontWeight: FontWeight.w600)),
                    PillToggle<DistanceUnit>(
                      options: const <(DistanceUnit, String)>[
                        (DistanceUnit.meters, 'M'),
                        (DistanceUnit.feet, 'FT')
                      ],
                      selected: distanceUnit,
                      onChanged: (DistanceUnit v) => ref
                          .read(distanceUnitPreferenceProvider.notifier)
                          .setDistanceUnit(v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          // Card(
          //   child: ListTile(
          //     title: const Text('Map attribution'),
          //     subtitle: Text(activeMapTileProviderConfig.attribution),
          //   ),
          // ),
          // Card(
          //   child: ListTile(
          //     title: const Text('Clear local cache'),
          //     subtitle: const Text('Clears cached weather and resort data.'),
          //     trailing: const Icon(Icons.delete_outline),
          //     onTap: () async {
          //       await ref.read(driftLocalDatabaseProvider).clearCaches();
          //       if (context.mounted) {
          //         ScaffoldMessenger.of(context).showSnackBar(
          //           const SnackBar(content: Text('Local cache cleared.')),
          //         );
          //       }
          //     },
          //   ),
          // ),
          // Card(
          //   child: ListTile(
          //     title: const Text('Export debug info'),
          //     subtitle: const Text(
          //       'Writes a JSON troubleshooting snapshot to the app documents folder.',
          //     ),
          //     trailing: const Icon(Icons.download_outlined),
          //     onTap: () async {
          //       final ownerUserId = authState.session?.user.id;
          //       if (ownerUserId == null || ownerUserId.isEmpty) {
          //         if (context.mounted) {
          //           ScaffoldMessenger.of(context).showSnackBar(
          //             const SnackBar(
          //               content: Text('Sign in to export debug info.'),
          //             ),
          //           );
          //         }
          //         return;
          //       }

          //       try {
          //         final exportAction =
          //             ref.read(debugExportActionProvider);
          //         final filePath = await exportAction(
          //           ownerUserId: ownerUserId,
          //           userEmail: authState.session?.user.email,
          //           speedUnit: speedUnit,
          //           distanceUnit: distanceUnit,
          //         );
          //         if (context.mounted) {
          //           ScaffoldMessenger.of(context).showSnackBar(
          //             SnackBar(
          //               content: Text('Debug info exported to $filePath'),
          //             ),
          //           );
          //         }
          //       } catch (error) {
          //         if (context.mounted) {
          //           ScaffoldMessenger.of(context).showSnackBar(
          //             SnackBar(content: Text('Debug export failed: $error')),
          //           );
          //         }
          //       }
          //     },
          //   ),
          // ),
          const SizedBox(height: 18),
          const MonoLabel(
            CatalogAttribution.openSkiData,
            size: 10,
            tone: MonoTone.faint,
            uppercase: false,
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              SizedBox(
                width: 140,
                child: GhostButton(
                  label: 'Log out',
                  onPressed: () async {
                    await ref.read(authControllerProvider.notifier).logout();
                    if (context.mounted) {
                      context.go(RoutePaths.login);
                    }
                  },
                ),
              ),
              const MonoLabel('v0.1.0 · Sync ok',
                  size: 10, tone: MonoTone.faint),
            ],
          ),
        ],
      ),
    );
  }
}
