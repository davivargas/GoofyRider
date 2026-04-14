import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/geolocator_tracking_repository.dart';
import '../data/native_android_tracking_repository.dart';
import '../data/session_api.dart';
import '../data/session_repository_impl.dart';
import '../domain/location_tracking_repository.dart';
import '../domain/session_repository.dart';
import 'history_view_models.dart';
import 'recording_controller.dart';

final sessionApiProvider = Provider<SessionApi>(
  (ref) => SessionApi(ref.watch(authorizedDioProvider)),
);

final locationTrackingRepositoryProvider = Provider<LocationTrackingRepository>(
  (ref) {
    if (!kIsWeb && Platform.isAndroid) {
      return NativeAndroidTrackingRepository();
    }
    return GeolocatorTrackingRepository();
  },
);

final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) {
    return SessionRepositoryImpl(
      localDatabase: ref.watch(driftLocalDatabaseProvider),
      api: ref.watch(sessionApiProvider),
      currentUserIdGetter: () =>
          ref.read(authControllerProvider).session?.user.id,
    );
  },
);

final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingViewState>(
  (ref) {
    final controller = RecordingController(
      sessionRepository: ref.watch(sessionRepositoryProvider),
      locationTrackingRepository: ref.watch(locationTrackingRepositoryProvider),
    );
    controller.initialize();
    return controller;
  },
);

final historyProvider = FutureProvider.autoDispose(
  (ref) {
    ref.watch(
      recordingControllerProvider.select(
        (RecordingViewState state) => state.sync.historyRevision,
      ),
    );
    return ref
        .watch(sessionRepositoryProvider)
        .listLocalAndRemoteSessionHistory();
  },
);

final historySectionsProvider =
    FutureProvider.autoDispose<List<SessionHistorySeasonSection>>((ref) async {
  final sessions =
      await ref.watch(historyProvider.future);
  final repository = ref.watch(sessionRepositoryProvider);

  final items =
      <SessionHistoryEntryViewModel>[];
  for (final session in sessions) {
    final resortLabel = await repository.resolveSessionResortLabel(
      session,
    );
    items.add(
      SessionHistoryEntryViewModel(
        session: session,
        resortLabel: resortLabel,
      ),
    );
  }
  return buildSessionHistorySections(items);
});

final sessionDetailProvider = FutureProvider.family.autoDispose(
  (ref, int localSessionId) =>
      ref.watch(sessionRepositoryProvider).getSessionDetail(localSessionId),
);

final unsyncedSessionCountProvider = FutureProvider.autoDispose(
  (ref) {
    ref.watch(
      recordingControllerProvider.select(
        (RecordingViewState state) => state.sync.historyRevision,
      ),
    );
    return ref.watch(sessionRepositoryProvider).unsyncedCount();
  },
);
