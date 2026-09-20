import 'package:flutter_test/flutter_test.dart';

import 'package:fall_line_mobile/core/utils/distance_unit.dart';
import 'package:fall_line_mobile/core/utils/vertical_unit.dart';

void main() {
  group('VerticalUnit', () {
    test('meters pass through and format with no decimals', () {
      expect(VerticalUnit.meters.convertFromMeters(320), 320);
      expect(VerticalUnit.meters.formatFromMeters(320), '320 m');
    });

    test('feet convert from meters', () {
      expect(VerticalUnit.feet.convertFromMeters(1000), closeTo(3280.84, 0.01));
      expect(VerticalUnit.feet.formatFromMeters(320), '1050 ft');
    });
  });

  group('DistanceUnit', () {
    test('kilometers convert from meters and format with one decimal', () {
      expect(
          DistanceUnit.kilometers.convertFromMeters(2150), closeTo(2.15, 1e-9));
      expect(DistanceUnit.kilometers.formatFromMeters(2140), '2.1 km');
    });

    test('miles convert from meters', () {
      expect(DistanceUnit.miles.convertFromMeters(1609.344), closeTo(1, 1e-9));
      expect(DistanceUnit.miles.formatFromMeters(8046.72), '5.0 mi');
    });

    test('short labels are horizontal units', () {
      expect(DistanceUnit.kilometers.shortLabel, 'km');
      expect(DistanceUnit.miles.shortLabel, 'mi');
    });
  });
}
