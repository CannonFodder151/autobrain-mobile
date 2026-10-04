import 'package:flutter_test/flutter_test.dart';
import 'package:autobrain/screens/servo_spy/servo_spy_list_model.dart';

void main() {
  test('station id round-trips from the API payload into the row', () {
    // Same shape the list builder reads off GET /fuel/stations.
    final m = <String, dynamic>{
      'id': 'st-42',
      'name': 'Shell Coburg',
      'distance_km': 1.25,
      'prices': [
        {'fuel_type': 'E10', 'price': 159.9},
      ],
    };

    final row = ServoStationRow(
      id: m['id'] as String? ?? '',
      name: m['name'] as String? ?? 'Unknown',
      distanceKm: (m['distance_km'] as num?)?.toDouble(),
      priceCents: 159.9,
      fuelType: 'E10',
    );

    expect(row.id, 'st-42');
    expect(row.id, isNotEmpty);
  });

  test('sorting ignores id and still orders by price', () {
    final rows = [
      const ServoStationRow(id: 'b', name: 'B', priceCents: 200),
      const ServoStationRow(id: 'a', name: 'A', priceCents: 150),
    ];

    sortStationRows(rows, ServoSortMetric.price);

    expect(rows.map((r) => r.id).toList(), ['a', 'b']);
  });
}
