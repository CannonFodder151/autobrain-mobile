import 'package:flutter_test/flutter_test.dart';
import 'package:autobrain/core/models.dart';

void main() {
  test('FuelStationHistory.fromJson parses backend payload', () {
    final h = FuelStationHistory.fromJson({
      'station_id': 'S1',
      'source': 'nsw',
      'fuel_type': null,
      'days': 30,
      'series': [
        {
          'fuel_type': 'E10',
          'price': 1.599,
          'effective_at': '2026-08-20T00:00:00+10:00',
        },
        {
          'fuel_type': 'Diesel',
          'price': 1.849,
          'effective_at': '2026-08-21T00:00:00+10:00',
        },
      ],
    });
    expect(h.stationId, 'S1');
    expect(h.source, 'nsw');
    expect(h.days, 30);
    expect(h.isEmpty, isFalse);
    expect(h.series.length, 2);
    expect(h.series[0].fuelType, 'E10');
    expect(h.series[0].price, 1.599);
    expect(h.series[0].effectiveAt.year, 2026);
    expect(h.series[0].effectiveAt.month, 8);
  });

  test('FuelStationHistory empty when no series rows', () {
    final h = FuelStationHistory.fromJson({
      'station_id': 'S2',
      'source': 'qld',
      'days': 30,
      'series': const [],
    });
    expect(h.isEmpty, isTrue);
  });

  test('FuelStationHistory.fromJson defaults on missing fields', () {
    final h = FuelStationHistory.fromJson({});
    expect(h.stationId, '');
    expect(h.source, '');
    expect(h.days, 0);
    expect(h.isEmpty, isTrue);
  });
}
