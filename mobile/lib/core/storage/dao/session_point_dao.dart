import 'package:drift/drift.dart';

import '../../../features/session/domain/session_models.dart';
import '../drift_local_database.dart';
import '_db_type_helpers.dart' as h;

/// Data-access object for local session points.
class SessionPointDao {
  SessionPointDao(this._db);
  final DriftLocalDatabase _db;

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<void> insertPoint({
    required int localSessionId,
    required NewSessionPoint point,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await _db.transaction(() async {
      await _db.customInsert(
        '''
        INSERT OR IGNORE INTO local_session_points (
          local_session_id,
          recorded_at,
          t_offset_ms,
          latitude,
          longitude,
          accuracy_m,
          elapsed_realtime_ns,
          altitude_m,
          vertical_accuracy_m,
          speed_mps,
          speed_accuracy_mps,
          heading_deg,
          bearing_accuracy_deg,
          provider,
          is_mocked,
          quality_class,
          quality_score,
          quality_reason,
          filtered_latitude,
          filtered_longitude,
          filtered_altitude_m,
          fused_speed_mps,
          derived_speed_mps,
          distance_delta_m,
          motion_state,
          accepted_for_analytics,
          created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        variables: <Variable>[
          Variable<int>(localSessionId),
          Variable<String>(point.recordedAt.toUtc().toIso8601String()),
          Variable<int>(point.tOffsetMs),
          Variable<double>(point.latitude),
          Variable<double>(point.longitude),
          Variable<double>(point.accuracyM),
          Variable<int>(point.elapsedRealtimeNs),
          Variable<double>(point.altitudeM),
          Variable<double>(point.verticalAccuracyM),
          Variable<double>(point.speedMps),
          Variable<double>(point.speedAccuracyMps),
          Variable<double>(point.headingDeg),
          Variable<double>(point.bearingAccuracyDeg),
          Variable<String>(point.provider),
          Variable<int>(
              point.isMocked == null ? null : (point.isMocked! ? 1 : 0)),
          Variable<String>(point.qualityClass),
          Variable<double>(point.qualityScore),
          Variable<String>(point.qualityReason),
          Variable<double>(point.filteredLatitude),
          Variable<double>(point.filteredLongitude),
          Variable<double>(point.filteredAltitudeM),
          Variable<double>(point.fusedSpeedMps),
          Variable<double>(point.derivedSpeedMps),
          Variable<double>(point.distanceDeltaM),
          Variable<String>(point.motionState),
          Variable<int>(point.acceptedForAnalytics ? 1 : 0),
          Variable<String>(now.toIso8601String()),
        ],
      );

      await _refreshSessionPointCount(
        localSessionId: localSessionId,
        updatedAt: now,
      );
    });
  }

  Future<void> replaceSessionPoints({
    required int localSessionId,
    required List<NewSessionPoint> points,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    await _db.transaction(() async {
      await _db.customStatement(
        'DELETE FROM local_session_points WHERE local_session_id = ?',
        <Object?>[localSessionId],
      );

      for (final NewSessionPoint point in points) {
        await _db.customInsert(
          '''
          INSERT OR IGNORE INTO local_session_points (
            local_session_id,
            recorded_at,
            t_offset_ms,
            latitude,
            longitude,
            accuracy_m,
            elapsed_realtime_ns,
            altitude_m,
            vertical_accuracy_m,
            speed_mps,
            speed_accuracy_mps,
            heading_deg,
            bearing_accuracy_deg,
            provider,
            is_mocked,
            quality_class,
            quality_score,
            quality_reason,
            filtered_latitude,
            filtered_longitude,
            filtered_altitude_m,
            fused_speed_mps,
            derived_speed_mps,
            distance_delta_m,
            motion_state,
            accepted_for_analytics,
            created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          variables: <Variable>[
            Variable<int>(localSessionId),
            Variable<String>(point.recordedAt.toUtc().toIso8601String()),
            Variable<int>(point.tOffsetMs),
            Variable<double>(point.latitude),
            Variable<double>(point.longitude),
            Variable<double>(point.accuracyM),
            Variable<int>(point.elapsedRealtimeNs),
            Variable<double>(point.altitudeM),
            Variable<double>(point.verticalAccuracyM),
            Variable<double>(point.speedMps),
            Variable<double>(point.speedAccuracyMps),
            Variable<double>(point.headingDeg),
            Variable<double>(point.bearingAccuracyDeg),
            Variable<String>(point.provider),
            Variable<int>(
              point.isMocked == null ? null : (point.isMocked! ? 1 : 0),
            ),
            Variable<String>(point.qualityClass),
            Variable<double>(point.qualityScore),
            Variable<String>(point.qualityReason),
            Variable<double>(point.filteredLatitude),
            Variable<double>(point.filteredLongitude),
            Variable<double>(point.filteredAltitudeM),
            Variable<double>(point.fusedSpeedMps),
            Variable<double>(point.derivedSpeedMps),
            Variable<double>(point.distanceDeltaM),
            Variable<String>(point.motionState),
            Variable<int>(point.acceptedForAnalytics ? 1 : 0),
            Variable<String>(now.toIso8601String()),
          ],
        );
      }

      await _refreshSessionPointCount(
        localSessionId: localSessionId,
        updatedAt: now,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Future<LocalSessionPoint?> latestAcceptedPoint(int localSessionId) async {
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_session_points
      WHERE local_session_id = ?
      AND accepted_for_analytics = 1
      ORDER BY recorded_at DESC
      LIMIT 1
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
      ],
    ).get();

    if (rows.isEmpty) {
      return null;
    }
    return _mapPoint(rows.first);
  }

  Future<List<LocalSessionPoint>> listPoints(
    int localSessionId, {
    bool onlyAccepted = false,
  }) async {
    final String acceptedClause =
        onlyAccepted ? 'AND accepted_for_analytics = 1' : '';
    final List<QueryRow> rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_session_points
      WHERE local_session_id = ?
      $acceptedClause
      ORDER BY recorded_at ASC
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
      ],
    ).get();

    return rows.map(_mapPoint).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Internal helpers (also used by migration code in DriftLocalDatabase)
  // ---------------------------------------------------------------------------

  Future<void> _refreshSessionPointCount({
    required int localSessionId,
    required DateTime updatedAt,
  }) {
    return _db.customUpdate(
      '''
      UPDATE local_ride_sessions
      SET point_count = (
            SELECT COUNT(*)
            FROM local_session_points
            WHERE local_session_id = ?
          ),
          updated_at = ?
      WHERE local_id = ?
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
        Variable<String>(updatedAt.toIso8601String()),
        Variable<int>(localSessionId),
      ],
    );
  }

  LocalSessionPoint _mapPoint(QueryRow row) {
    final Map<String, Object?> data = row.data;
    return LocalSessionPoint(
      id: h.asInt(data['id']),
      localSessionId: h.asInt(data['local_session_id']),
      recordedAt: DateTime.parse(data['recorded_at'] as String).toUtc(),
      tOffsetMs: h.asInt(data['t_offset_ms']),
      latitude: h.asDouble(data['latitude']),
      longitude: h.asDouble(data['longitude']),
      accuracyM: h.asNullableDouble(data['accuracy_m']),
      altitudeM: h.asNullableDouble(data['altitude_m']),
      speedMps: h.asNullableDouble(data['speed_mps']),
      headingDeg: h.asNullableDouble(data['heading_deg']),
      acceptedForAnalytics: h.asInt(data['accepted_for_analytics']) == 1,
      elapsedRealtimeNs: h.asNullableInt(data['elapsed_realtime_ns']),
      verticalAccuracyM: h.asNullableDouble(data['vertical_accuracy_m']),
      speedAccuracyMps: h.asNullableDouble(data['speed_accuracy_mps']),
      bearingAccuracyDeg: h.asNullableDouble(data['bearing_accuracy_deg']),
      provider: data['provider'] as String?,
      isMocked: h.asNullableBool(data['is_mocked']),
      qualityClass: data['quality_class'] as String?,
      qualityScore: h.asNullableDouble(data['quality_score']),
      qualityReason: data['quality_reason'] as String?,
      filteredLatitude: h.asNullableDouble(data['filtered_latitude']),
      filteredLongitude: h.asNullableDouble(data['filtered_longitude']),
      filteredAltitudeM: h.asNullableDouble(data['filtered_altitude_m']),
      fusedSpeedMps: h.asNullableDouble(data['fused_speed_mps']),
      derivedSpeedMps: h.asNullableDouble(data['derived_speed_mps']),
      distanceDeltaM: h.asNullableDouble(data['distance_delta_m']),
      motionState: data['motion_state'] as String?,
    );
  }
}
