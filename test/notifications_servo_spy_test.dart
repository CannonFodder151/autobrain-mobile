// Servo-spy favourites section in the notification menu (AUT-1859-3).
//
// Proves the new section renders a user's watch list and that editing a
// favourite ships the documented API contract: direction (up/down/both),
// a threshold_pct that must be > 0, and idempotent POST upsert. Backend
// shape is from autobrain PR #345 (FuelPriceWatchlistIn/Out).
//
//   flutter test test/notifications_servo_spy_test.dart

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:autobrain/core/api_client.dart';
import 'package:autobrain/core/auth_state.dart';
import 'package:autobrain/screens/notifications/notifications_screen.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(null);

  Map<String, dynamic>? lastPost;
  String? lastDelete;

  static const _prefs = <String, dynamic>{
    'push_enabled': true,
    'email_enabled': true,
    'discord_enabled': false,
    'service_due_days': 7,
    'service_due_km': 500,
    'fuel_gap_km': 0,
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
    if (path.startsWith('/vehicles/') && path.endsWith('/notifications')) {
      return _prefs;
    }
    if (path == '/fuel-prices/watchlist') {
      return [_watch];
    }
    if (path.startsWith('/fuel-prices')) {
      // Latest price markers (Add-favourite picker source).
      return [
        {
          'state': 'NSW',
          'station_code': 'S123',
          'station_name': 'Shell North',
          'brand': 'Shell',
          'fuel_type': 'U91',
          'price': 1.60,
        }
      ];
    }
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
  @override
  ApiClient get api => _FakeApi();
}

Widget _app() => ChangeNotifierProvider<AuthState>(
      create: (_) => _FakeAuth(),
      child: const MaterialApp(home: NotificationsScreen(vehicleId: 'v1')),
    );

void main() {
  testWidgets('servo-spy section lists the user\'s favourites',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    // The screen loads the watch list asynchronously; pump until the section
    // is present (also lets AuthState._restore's deferred work settle).
    for (var i = 0;
        i < 40 && find.text('Servo spy alerts').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Servo spy alerts'), findsOneWidget);
    expect(find.text('Shell · Shell North'), findsOneWidget);
    expect(find.text('U91'), findsWidgets);
  });

  testWidgets('editing a favourite rejects <=0 threshold and upserts valid',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final threshold = find.widgetWithText(TextField, 'Threshold % (must be > 0)');
    expect(threshold, findsOneWidget);

    // Zero threshold is rejected client-side before any request.
    await tester.enterText(threshold, '0');
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();
    expect(find.text('Threshold must be greater than 0'), findsOneWidget);
    final api = Provider.of<AuthState>(tester.element(find.byType(NotificationsScreen)),
            listen: false)
        .api as _FakeApi;
    expect(api.lastPost, isNull);

    // Valid threshold + direction change ships the documented contract.
    await tester.tap(find.text('Rises'));
    await tester.pumpAndSettle();
    await tester.enterText(threshold, '8.5');
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();

    expect(api.lastPost, isNotNull);
    expect(api.lastPost!['state'], 'NSW');
    expect(api.lastPost!['station_code'], 'S123');
    expect(api.lastPost!['fuel_type'], 'U91');
    expect(api.lastPost!['direction'], 'up');
    expect(api.lastPost!['threshold_pct'], 8.5);
  });

  testWidgets('removing a favourite calls DELETE /fuel-prices/watchlist/{id}',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Remove favourite'));
    await tester.pumpAndSettle();

    final api = Provider.of<AuthState>(tester.element(find.byType(NotificationsScreen)),
            listen: false)
        .api as _FakeApi;
    expect(api.lastDelete, '/fuel-prices/watchlist/w1');
  });
}
