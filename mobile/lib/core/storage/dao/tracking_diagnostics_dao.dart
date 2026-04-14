import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../features/session/domain/session_models.dart';
import '../drift_local_database.dart';
import '_db_type_helpers.dart' as h;

/// Data-access object for session tracking diagnostics.
class TrackingDiagnosticsDao {
  TrackingDiagnosticsDao(this._db);
  final DriftLocalDatabase _db;

  static const int _maxTrackingDiagnosticsPerSession = 400;

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  Future<void> insertTrackingDiagnostic({
    required int localSessionId,
    required String eventType,
    String? message,
    Map<String, dynamic>? details,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.customInsert(
      '''
      INSERT INTO local_session_tracking_diagnostics (
        local_session_id,
        occurred_at,
        event_type,
        message,
        details_json
      ) VALUES (?, ?, ?, ?, ?)
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
        Variable<String>(now.toIso8601String()),
        Variable<String>(eventType),
        Variable<String>(message),
        Variable<String>(
          details == null ? null : jsonEncode(details),
        ),
      ],
    );

    await _db.customStatement(
      '''
      DELETE FROM local_session_tracking_diagnostics
      WHERE local_session_id = ?
      AND id NOT IN (
        SELECT id
        FROM local_session_tracking_diagnostics
        WHERE local_session_id = ?
        ORDER BY occurred_at DESC
        LIMIT $_maxTrackingDiagnosticsPerSession
      )
      ''',
      <Object?>[
        localSessionId,
        localSessionId,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Future<List<TrackingDiagnosticEvent>> listTrackingDiagnostics(
    int localSessionId, {
    int limit = 120,
  }) async {
    final safeLimit =
        limit.clamp(1, _maxTrackingDiagnosticsPerSession).toInt();
    final rows = await _db.customSelect(
      '''
      SELECT *
      FROM local_session_tracking_diagnostics
      WHERE local_session_id = ?
      ORDER BY occurred_at DESC
      LIMIT ?
      ''',
      variables: <Variable>[
        Variable<int>(localSessionId),
        Variable<int>(safeLimit),
      ],
    ).get();

    return rows.map(_mapTrackingDiagnostic).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  TrackingDiagnosticEvent _mapTrackingDiagnostic(QueryRow row) {
    final Map<String, Object?> data = row.data;
    final detailsJson = data['details_json'] as String?;
    return TrackingDiagnosticEvent(
      id: h.asInt(data['id']),
      localSessionId: h.asInt(data['local_session_id']),
      occurredAt: DateTime.parse(data['occurred_at'] as String).toUtc(),
      eventType: data['event_type'] as String,
      message: data['message'] as String?,
      details: _parseJsonMap(detailsJson),
    );
  }

  Map<String, dynamic> _parseJsonMap(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (Object? key, Object? value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      return const <String, dynamic>{};
    }
    return const <String, dynamic>{};
  }
}
