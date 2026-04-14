import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/providers.dart';
import '../../../core/providers/distance_unit_preference_provider.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/speed_unit.dart';
import '../../auth/presentation/auth_providers.dart';
import 'debug_export_service.dart';

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
    final activeMapTileProviderConfig =
        ref.watch(activeMapTileProviderConfigProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(authState.session?.user.displayName ?? 'Guest'),
              subtitle: Text(authState.session?.user.email ?? 'Not signed in'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Units preference'),
                  const SizedBox(height: 10),
                  const Text('Speed'),
                  const SizedBox(height: 8),
                  SegmentedButton<SpeedUnit>(
                    segments: const <ButtonSegment<SpeedUnit>>[
                      ButtonSegment<SpeedUnit>(
                        value: SpeedUnit.kilometersPerHour,
                        label: Text('km/h'),
                      ),
                      ButtonSegment<SpeedUnit>(
                        value: SpeedUnit.metersPerSecond,
                        label: Text('m/s'),
                      ),
                      ButtonSegment<SpeedUnit>(
                        value: SpeedUnit.milesPerHour,
                        label: Text('mph'),
                      ),
                    ],
                    selected: <SpeedUnit>{speedUnit},
                    onSelectionChanged: (Set<SpeedUnit> selection) {
                      ref
                          .read(speedUnitPreferenceProvider.notifier)
                          .setSpeedUnit(selection.first);
                    },
                  ),
                  const SizedBox(height: 14),
                  const Text('Distance'),
                  const SizedBox(height: 8),
                  SegmentedButton<DistanceUnit>(
                    segments: const <ButtonSegment<DistanceUnit>>[
                      ButtonSegment<DistanceUnit>(
                        value: DistanceUnit.meters,
                        label: Text('m'),
                      ),
                      ButtonSegment<DistanceUnit>(
                        value: DistanceUnit.feet,
                        label: Text('ft'),
                      ),
                    ],
                    selected: <DistanceUnit>{distanceUnit},
                    onSelectionChanged: (Set<DistanceUnit> selection) {
                      ref
                          .read(distanceUnitPreferenceProvider.notifier)
                          .setDistanceUnit(selection.first);
                    },
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Map attribution'),
              subtitle: Text(activeMapTileProviderConfig.attribution),
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Clear local cache'),
              subtitle: const Text('Clears cached weather and resort data.'),
              trailing: const Icon(Icons.delete_outline),
              onTap: () async {
                await ref.read(driftLocalDatabaseProvider).clearCaches();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Local cache cleared.')),
                  );
                }
              },
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Export debug info'),
              subtitle: const Text(
                'Writes a JSON troubleshooting snapshot to the app documents folder.',
              ),
              trailing: const Icon(Icons.download_outlined),
              onTap: () async {
                final ownerUserId = authState.session?.user.id;
                if (ownerUserId == null || ownerUserId.isEmpty) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Sign in to export debug info.'),
                      ),
                    );
                  }
                  return;
                }

                try {
                  final exportAction =
                      ref.read(debugExportActionProvider);
                  final filePath = await exportAction(
                    ownerUserId: ownerUserId,
                    userEmail: authState.session?.user.email,
                    speedUnit: speedUnit,
                    distanceUnit: distanceUnit,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Debug info exported to $filePath'),
                      ),
                    );
                  }
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Debug export failed: $error')),
                    );
                  }
                }
              },
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              await ref.read(authControllerProvider.notifier).logout();
              if (context.mounted) {
                context.go(RoutePaths.login);
              }
            },
            child: const Text('Log out'),
          ),
        ],
      ),
    );
  }
}
