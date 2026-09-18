import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _load(String name) {
  final file = File('test/fixtures/contracts/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  test('point batch contract fixture carries pressure_hpa on the first point',
      () {
    final points = _load('session_point_batch.json')['points'] as List<dynamic>;
    expect((points[0] as Map<String, dynamic>)['pressure_hpa'],
        closeTo(898.7, 1e-9));
    expect((points[1] as Map<String, dynamic>).containsKey('pressure_hpa'),
        isFalse);
  });

  test(
      'session detail contract fixture carries the summary fields the app maps',
      () {
    final session =
        _load('session_detail.json')['session'] as Map<String, dynamic>;
    for (final key in <String>[
      'descent_duration_s',
      'descent_distance_m',
      'avg_descent_speed_mps',
      'descent_vertical_m',
      'lift_vertical_m',
      'break_count',
      'break_duration_s',
      'max_speed_mps',
    ]) {
      expect(session.containsKey(key), isTrue, reason: key);
    }
    expect(session['break_count'], 1);
    expect(session['break_duration_s'], 240.0);
  });
}
