// Servo-spy favourites in the petrol-price map call sheet (AUT-1859-3).
//
// Proves a user's watch list drives the map markers and that the station
// call sheet ships the documented API contract: direction (up/down/both) and
// a threshold_pct, upserted idempotently via POST, and removed via DELETE.
// Backend shape is from autobrain PR #345 (FuelPriceWatchlistIn/Out).
//
// History: these assertions used to run against a "Servo spy alerts" section
// inside NotificationsScreen. That section moved to the price map's per-station
// call sheet (AUT-1868), so this file now drives PetrolPriceMapScreen.
//
//   flutter test test/petrol_price_map_servo_spy_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:autobrain/core/api_client.dart';
import 'package:autobrain/core/auth_state.dart';
import 'package:autobrain/screens/fuel/petrol_price_map_screen.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(null);

  Map<String, dynamic>? lastPost;
  String? lastDelete;

  // One station, sitting on the map's initial centre so its marker is tappable
  // at the default zoom.
  static const _price = <String, dynamic>{
    'state': 'NSW',
    'station_code': 'S123',
    'station_name': 'Shell North',
    'brand': 'Shell',
    'latitude': -32.5,
    'longitude': 147.0,
    'fuel_type': 'U91',
    'price': 1.60,
  };

  static const _watch = <String, dynamic>{
    'id': 'w1',
    'state': 'NSW',
    'station_code': 'S123',
    'station_name': 'Shell North',
    'brand': 'Shell',
    'fuel_type': 'U91',
    'direction': 'both',
    'threshold_pct': 5.0,
  };

  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/fuel-prices') return [_price];
    if (path == '/fuel-prices/watchlist') return [_watch];
    throw ApiException(404, path);
  }

  @override
  Future<dynamic> post(String path,
      [Object? body, Map<String, String>? headers]) async {
    lastPost = body as Map<String, dynamic>?;
    return {'id': 'w1', ...?lastPost};
  }

  @override
  Future<dynamic> delete(String path) async {
    lastDelete = path;
    return null;
  }
}

class _FakeAuth extends AuthState {
  final _api = _FakeApi();
  @override
  ApiClient get api => _api;
}

Future<_FakeAuth> _pump(WidgetTester tester) async {
  final auth = _FakeAuth();
  await tester.pumpWidget(ChangeNotifierProvider<AuthState>(
    create: (_) => auth,
    child: const MaterialApp(home: PetrolPriceMapScreen(state: 'NSW')),
  ));
  // The screen loads prices + watch list asynchronously, then lays the map out.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return auth;
}

/// Opens the marker for the single fake station and settles the bottom sheet.
Future<void> _openStationSheet(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.location_on));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('favourited station renders as a starred marker and in the legend',
      (WidgetTester tester) async {
    await _pump(tester);

    expect(find.byIcon(Icons.location_on), findsOneWidget);
    // Marker star overlay + the legend's star.
    expect(find.byIcon(Icons.star), findsWidgets);
    expect(find.text('1 favourited station'), findsOneWidget);
  });

  testWidgets('changing direction upserts the documented contract',
      (WidgetTester tester) async {
    final auth = await _pump(tester);
    await _openStationSheet(tester);

    expect(find.text('Shell'), findsOneWidget);
    expect(find.text('U91'), findsOneWidget);
    expect(find.text('Alert me when price moves'), findsOneWidget);
    // Favourites render a filled star and the editor's current direction.
    expect(find.byTooltip('Favourited'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Up only'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(auth._api.lastPost, isNotNull);
    expect(auth._api.lastPost!['state'], 'NSW');
    expect(auth._api.lastPost!['station_code'], 'S123');
    expect(auth._api.lastPost!['fuel_type'], 'U91');
    expect(auth._api.lastPost!['direction'], 'up');
    expect(auth._api.lastPost!['threshold_pct'], 5.0);
  });

  testWidgets('removing a favourite calls DELETE /fuel-prices/watchlist/{id}',
      (WidgetTester tester) async {
    final auth = await _pump(tester);
    await _openStationSheet(tester);

    await tester.tap(find.byTooltip('Favourited'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(auth._api.lastDelete, '/fuel-prices/watchlist/w1');
    // The alert editor goes with the favourite, and the star unfills.
    expect(find.text('Alert me when price moves'), findsNothing);
    expect(find.byTooltip('Favourite'), findsOneWidget);
  });
}