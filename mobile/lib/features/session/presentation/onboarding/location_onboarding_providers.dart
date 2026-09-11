import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/gps_warmup_permission_preference.dart';
import '../session_providers.dart';

/// `null` until loaded, then whether the location onboarding step has been
/// shown (it piggybacks on the existing warm-up permission preference).
class LocationOnboardingSeenController extends StateNotifier<bool?> {
  LocationOnboardingSeenController(this._preference) : super(null);

  final GpsWarmupPermissionPreference _preference;

  Future<void> load() async {
    state = await _preference.hasBeenRequested();
  }

  Future<void> markSeen() async {
    await _preference.markRequested();
    state = true;
  }
}

final locationOnboardingSeenProvider =
    StateNotifierProvider<LocationOnboardingSeenController, bool?>(
  (ref) => LocationOnboardingSeenController(
    ref.watch(gpsWarmupPermissionPreferenceProvider),
  ),
);
