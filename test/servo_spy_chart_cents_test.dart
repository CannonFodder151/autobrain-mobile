import 'package:flutter_test/flutter_test.dart';
import 'package:autobrain/core/models.dart';

void main() {
  test('history price is cents per litre and renders as dollars', () {
    final h = FuelStationHistory.fromJson({
      'station_id': 'S3',
      'series': [
        {
          'fuel_type': 'E10',
          'price': 159.9,
          'effective_at': '2026-08-20T00:00:00+10:00',
        },
      ],
    });
    final cents = h.series.single.price;
    expect(cents, 159.9);
    final dollars = priceCentsToDollars(cents);
    expect(dollars, closeTo(1.599, 1e-9));
    expect(formatChartPrice(dollars), r'$1.60');
  });

  test('formatChartPrice rounds cents to two decimals', () {
    expect(formatChartPrice(priceCentsToDollars(184.9)), r'$1.85');
    expect(formatChartPrice(priceCentsToDollars(159)), r'$1.59');
    expect(formatChartPrice(priceCentsToDollars(0)), r'$0.00');
  });
}
