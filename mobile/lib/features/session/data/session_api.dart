import 'package:dio/dio.dart';

class SessionApi {
  SessionApi(this._dio);

  final Dio _dio;

  Future<Map<String, dynamic>> createRemoteDraft({
    required String? resortId,
    required DateTime startedAt,
  }) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/sessions',
      data: <String, dynamic>{
        'resort_id': resortId,
        'started_at': startedAt.toUtc().toIso8601String(),
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> uploadPointBatch({
    required String remoteSessionId,
    required List<Map<String, dynamic>> points,
  }) async {
    await _dio.post<dynamic>(
      '/sessions/$remoteSessionId/points:batch',
      data: <String, dynamic>{'points': points},
    );
  }

  Future<Map<String, dynamic>> completeRemoteSession({
    required String remoteSessionId,
    required DateTime endedAt,
    required int durationS,
    required double distanceM,
    required double maxSpeedMps,
    required double avgSpeedMps,
    required int? elevationGainM,
    required int? elevationLossM,
  }) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/sessions/$remoteSessionId/complete',
      data: <String, dynamic>{
        'ended_at': endedAt.toUtc().toIso8601String(),
        'duration_s': durationS,
        'distance_m': distanceM,
        'max_speed_mps': maxSpeedMps,
        'avg_speed_mps': avgSpeedMps,
        'elevation_gain_m': elevationGainM,
        'elevation_loss_m': elevationLossM,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listRemoteSessions() async {
    const int pageSize = 100;
    final List<Map<String, dynamic>> sessions = <Map<String, dynamic>>[];
    int page = 1;
    int? total;

    while (true) {
      final Response<dynamic> response = await _dio.get<dynamic>(
        '/users/me/sessions',
        queryParameters: <String, dynamic>{
          'page': page,
          'page_size': pageSize,
        },
      );
      final Map<String, dynamic> payload =
          response.data as Map<String, dynamic>;
      final List<dynamic> items =
          payload['items'] as List<dynamic>? ?? <dynamic>[];
      sessions.addAll(items.cast<Map<String, dynamic>>());
      total ??= (payload['total'] as num?)?.toInt();

      if (items.isEmpty || items.length < pageSize) {
        break;
      }
      if (total != null && sessions.length >= total) {
        break;
      }
      page += 1;
    }

    return sessions;
  }

  Future<Map<String, dynamic>> getRemoteSession(String sessionId) async {
    final Response<dynamic> response =
        await _dio.get<dynamic>('/sessions/$sessionId');
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getRemoteSessionPoints(
      String sessionId) async {
    final Response<dynamic> response =
        await _dio.get<dynamic>('/sessions/$sessionId/points');
    final Map<String, dynamic> payload = response.data as Map<String, dynamic>;
    final List<dynamic> items =
        payload['items'] as List<dynamic>? ?? <dynamic>[];
    return items.cast<Map<String, dynamic>>();
  }
}
