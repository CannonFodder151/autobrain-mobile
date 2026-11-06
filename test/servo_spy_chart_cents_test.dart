// AUT-4772: the Servo Spy history chart must render $/L, not raw cents.
//
// Backend contract (`app/schemas/fuel_servo.py`) is cents per litre, so a
// 159.9 c/L price has to read $1.60 on the Y axis and in the tooltip — the
// pre-fix chart plotted p.price raw and labelled it as dollars ($159.90).
import 'package:flutter_test/flutter_test.dart';
import 'package:autobrain/screens/servo_spy/servo_spy_station_history_screen.dart';
import 'package:autobrain/services/fuel_prices_api.dart';

void main() {
  group('Servo Spy history chart price units', () {
    test('159.9 c/L payload renders 1.60 dollars per litre', () {
      final history = StationPriceHistory.fromJson({
        'station_id': 'S3',
        'days': 30,
        'series': [
          {
            'fuel_type': 'E10',
            'price': 159.9,
            'effective_at': '2026-08-20T00:00:00+10:00',
          },
        ],
      });

      // The model keeps the wire value in cents...
      final cents = history.series.single.points.single.priceCents;
      expect(cents, 159.9);

      // ...and every chart label converts it to dollars.
      expect(formatDollarsPerLitre(cents), r'$1.60');
    });

    test('rounds to two decimals like the axis gridline labels', () {
      expect(formatDollarsPerLitre(184.9), r'$1.85');
      expect(formatDollarsPerLitre(159), r'$1.59');
      expect(formatDollarsPerLitre(0), r'$0.00');
      expect(formatDollarsPerLitre(2650), r'$26.50');
    });
  });
}
