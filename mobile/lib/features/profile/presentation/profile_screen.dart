import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_paths.dart';
import '../../../core/providers/speed_unit_preference_provider.dart';
import '../../../core/providers.dart';
import '../../../core/utils/speed_unit.dart';
import '../../auth/presentation/auth_providers.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final SpeedUnit speedUnit = ref.watch(speedUnitPreferenceProvider);

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
                    ],
                    selected: <SpeedUnit>{speedUnit},
                    onSelectionChanged: (Set<SpeedUnit> selection) {
                      ref
                          .read(speedUnitPreferenceProvider.notifier)
                          .setSpeedUnit(selection.first);
                    },
                  ),
                ],
              ),
            ),
          ),
          const Card(
            child: ListTile(
              title: Text('Map attribution'),
              subtitle: Text('OpenStreetMap contributors'),
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
          const Card(
            child: ListTile(
              title: Text('Export debug info'),
              subtitle: Text('Dev-only placeholder'),
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
