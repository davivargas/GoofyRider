import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/storage/drift_local_database.dart';
import '../../../core/utils/distance_unit.dart';
import '../../../core/utils/speed_unit.dart';
import '../../session/domain/session_models.dart';

const int _debugExportSchemaVersion = 2;
const int _trackingDiagnosticsLimit = 400;
const int _pointSamplePerSide = 50;
const int _pointSampleRecentSyncedSessionCount = 3;

class DebugExportService {
  DebugExportService({
    required DriftLocalDatabase localDatabase,
    Future<Directory> Function()? documentsDirectoryProvider,
  })  : _localDatabase = localDatabase,
        _documentsDirectoryProvider =
            documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  final DriftLocalDatabase _localDatabase;
  final Future<Directory> Function() _documentsDirectoryProvider;

  Future<File> export({
    required String ownerUserId,
    required String? userEmail,
    required SpeedUnit speedUnit,
    required DistanceUnit distanceUnit,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    final List<LocalRideSession> sessions =
        await _localDatabase.listSessions(ownerUserId: ownerUserId);
    final List<LocalRideSession> orderedSessions = List<LocalRideSession>.from(
      sessions,
    )..sort((LocalRideSession a, LocalRideSession b) {
        return b.startedAt.compareTo(a.startedAt);
      });
    final List<LocalRideSession> pendingSync =
        await _localDatabase.listPendingSyncSessions(ownerUserId: ownerUserId);
    final List<Map<String, dynamic>> cachedRemote =
        await _localDatabase.readCachedRemoteSessions(ownerUserId: ownerUserId);
    final List<Map<String, dynamic>> cachedResorts =
        await _localDatabase.readCachedResorts();
    final List<Map<String, dynamic>> cachedWeatherMetadata =
        await _localDatabase.readCachedWeatherMetadata();
    final Map<String, Map<String, dynamic>> cachedResortById =
        _buildCachedResortIndex(cachedResorts);

    final Map<String, dynamic> payload = <String, dynamic>{
      'schema_version': _debugExportSchemaVersion,
      'generated_at_utc': now.toIso8601String(),
      'user_context': <String, dynamic>{
        'owner_user_id': ownerUserId,
        'is_signed_in': true,
        'masked_email': _maskEmail(userEmail),
      },
      'settings': <String, dynamic>{
        'speed_unit': speedUnit.name,
        'distance_unit': distanceUnit.name,
      },
      'summary': <String, dynamic>{
        'session_count': sessions.length,
        'unsynced_session_count': pendingSync.length,
        'cached_remote_session_count': cachedRemote.length,
        'cached_resort_count': cachedResorts.length,
        'cached_weather_count': cachedWeatherMetadata.length,
      },
      'unsynced_sessions': pendingSync.map(_sessionToJson).toList(growable: false),
      'cached_remote_sessions':
          cachedRemote.map(_sanitizeDynamic).toList(growable: false),
      'cached_resorts':
          cachedResorts.map(_sanitizeDynamic).toList(growable: false),
      'cached_weather_metadata':
          cachedWeatherMetadata.map(_sanitizeDynamic).toList(growable: false),
      'sessions': <Map<String, dynamic>>[],
    };

    final List<Map<String, dynamic>> sessionMaps =
        payload['sessions'] as List<Map<String, dynamic>>;
    for (int index = 0; index < orderedSessions.length; index++) {
      final LocalRideSession session = orderedSessions[index];
      final List<TrackingDiagnosticEvent> diagnostics =
          await _localDatabase.listTrackingDiagnostics(
        session.localId,
        limit: _trackingDiagnosticsLimit,
      );
      final List<LocalSessionPoint> pointCandidates = await _readPointCandidates(
        session.localId,
      );
      final List<LocalSessionPoint> pointSample =
          _sampleSessionPoints(pointCandidates);
      final bool includePointSample =
          session.isUnsynced || index < _pointSampleRecentSyncedSessionCount;

      final Map<String, dynamic>? cachedRemoteSummary =
          session.remoteId == null || session.remoteId!.trim().isEmpty
              ? null
              : await _localDatabase.readCachedRemoteSessionSummary(
                  ownerUserId: ownerUserId,
                  remoteId: session.remoteId!,
                );
      final Map<String, dynamic>? cachedResortPayload =
          session.resortId == null || session.resortId!.trim().isEmpty
              ? null
              : cachedResortById[session.resortId!.trim()];

      sessionMaps.add(
        <String, dynamic>{
          'session': _sessionToJson(session),
          'resort_context': <String, dynamic>{
            'stored_resort_id': session.resortId,
            'has_explicit_resort_id': session.resortId != null,
            'cached_resort_payload': _sanitizeDynamic(cachedResortPayload),
          },
          'cached_remote_summary': _sanitizeDynamic(cachedRemoteSummary),
          'diagnostics':
              diagnostics.map(_diagnosticToJson).toList(growable: false),
          'point_sample': <String, dynamic>{
            'included': includePointSample,
            'accepted_points_preferred': true,
            'sample_strategy': 'first_last_$_pointSamplePerSide',
            'total_points_available': pointCandidates.length,
            'sampled_points': includePointSample
                ? pointSample.map(_pointToJson).toList(growable: false)
                : <Map<String, dynamic>>[],
          },
        },
      );
    }

    final Directory directory = await _documentsDirectoryProvider();
    final String fileName =
        'goofyrider_debug_${now.toIso8601String().replaceAll(':', '-')}.json';
    final File file = File(path.join(directory.path, fileName));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    return file;
  }

  Map<String, dynamic> _sessionToJson(LocalRideSession session) {
    return <String, dynamic>{
      'local_id': session.localId,
      'owner_user_id': session.ownerUserId,
      'remote_id': session.remoteId,
      'resort_id': session.resortId,
      'started_at': session.startedAt.toIso8601String(),
      'ended_at': session.endedAt?.toIso8601String(),
      'active_duration_s': session.activeDurationS,
      'distance_m': session.distanceM,
      'max_speed_mps': session.maxSpeedMps,
      'avg_speed_mps': session.avgSpeedMps,
      'elevation_gain_m': session.elevationGainM,
      'elevation_loss_m': session.elevationLossM,
      'state': session.state.wireValue,
      'point_count': session.pointCount,
      'sync_attempt_count': session.syncAttemptCount,
      'last_sync_error': session.lastSyncError,
      'created_at': session.createdAt.toIso8601String(),
      'updated_at': session.updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> _diagnosticToJson(TrackingDiagnosticEvent event) {
    return <String, dynamic>{
      'id': event.id,
      'local_session_id': event.localSessionId,
      'occurred_at': event.occurredAt.toIso8601String(),
      'event_type': event.eventType,
      'message': event.message,
      'details': _sanitizeDynamic(event.details),
    };
  }

  Map<String, dynamic> _pointToJson(LocalSessionPoint point) {
    return <String, dynamic>{
      'id': point.id,
      'local_session_id': point.localSessionId,
      'recorded_at': point.recordedAt.toIso8601String(),
      't_offset_ms': point.tOffsetMs,
      'latitude': point.latitude,
      'longitude': point.longitude,
      'accuracy_m': point.accuracyM,
      'altitude_m': point.altitudeM,
      'vertical_accuracy_m': point.verticalAccuracyM,
      'speed_mps': point.speedMps,
      'speed_accuracy_mps': point.speedAccuracyMps,
      'heading_deg': point.headingDeg,
      'bearing_accuracy_deg': point.bearingAccuracyDeg,
      'provider': point.provider,
      'is_mocked': point.isMocked,
      'quality_class': point.qualityClass,
      'quality_score': point.qualityScore,
      'quality_reason': point.qualityReason,
      'filtered_latitude': point.filteredLatitude,
      'filtered_longitude': point.filteredLongitude,
      'filtered_altitude_m': point.filteredAltitudeM,
      'fused_speed_mps': point.fusedSpeedMps,
      'derived_speed_mps': point.derivedSpeedMps,
      'distance_delta_m': point.distanceDeltaM,
      'motion_state': point.motionState,
      'accepted_for_analytics': point.acceptedForAnalytics,
    };
  }

  String? _maskEmail(String? email) {
    if (email == null || email.trim().isEmpty) {
      return null;
    }
    final String value = email.trim();
    final int atIndex = value.indexOf('@');
    if (atIndex <= 0 || atIndex == value.length - 1) {
      return '***';
    }
    final String localPart = value.substring(0, atIndex);
    final String domainPart = value.substring(atIndex + 1);
    final String localMasked = localPart.length <= 2
        ? '${localPart[0]}*'
        : '${localPart.substring(0, 2)}***';
    return '$localMasked@$domainPart';
  }

  Map<String, Map<String, dynamic>> _buildCachedResortIndex(
    List<Map<String, dynamic>> cachedResorts,
  ) {
    final Map<String, Map<String, dynamic>> index =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> resort in cachedResorts) {
      final String? id = _extractResortId(resort);
      if (id == null || id.isEmpty) {
        continue;
      }
      index[id] = resort;
    }
    return index;
  }

  String? _extractResortId(Map<String, dynamic> payload) {
    final Object? directId = payload['id'] ?? payload['resort_id'];
    if (directId is String && directId.trim().isNotEmpty) {
      return directId.trim();
    }
    final Object? nestedResort = payload['resort'];
    if (nestedResort is Map<String, dynamic>) {
      final Object? nestedId = nestedResort['id'] ?? nestedResort['resort_id'];
      if (nestedId is String && nestedId.trim().isNotEmpty) {
        return nestedId.trim();
      }
    }
    return null;
  }

  Future<List<LocalSessionPoint>> _readPointCandidates(int localSessionId) async {
    final List<LocalSessionPoint> accepted = await _localDatabase.listPoints(
      localSessionId,
      onlyAccepted: true,
    );
    if (accepted.isNotEmpty) {
      return accepted;
    }
    return _localDatabase.listPoints(localSessionId);
  }

  List<LocalSessionPoint> _sampleSessionPoints(List<LocalSessionPoint> points) {
    final int cap = _pointSamplePerSide * 2;
    if (points.length <= cap) {
      return points;
    }

    final List<LocalSessionPoint> sampled = <LocalSessionPoint>[
      ...points.take(_pointSamplePerSide),
    ];
    final Set<int> seen =
        sampled.map((LocalSessionPoint point) => point.id).toSet();
    for (final LocalSessionPoint point
        in points.skip(points.length - _pointSamplePerSide)) {
      if (seen.add(point.id)) {
        sampled.add(point);
      }
    }
    return sampled;
  }

  dynamic _sanitizeDynamic(dynamic value) {
    if (value is Map<String, dynamic>) {
      final Map<String, dynamic> sanitized = <String, dynamic>{};
      for (final MapEntry<String, dynamic> entry in value.entries) {
        if (_isSensitiveKey(entry.key)) {
          continue;
        }
        sanitized[entry.key] = _sanitizeDynamic(entry.value);
      }
      return sanitized;
    }
    if (value is List) {
      return value.map(_sanitizeDynamic).toList(growable: false);
    }
    return value;
  }

  bool _isSensitiveKey(String key) {
    final String normalized = key.toLowerCase();
    return normalized.contains('token') ||
        normalized.contains('password') ||
        normalized.contains('secret') ||
        normalized == 'authorization' ||
        normalized == 'auth_header';
  }
}
