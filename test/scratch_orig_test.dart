import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:autobrain/core/api_client.dart';
import 'package:autobrain/core/auth_state.dart';
import 'package:autobrain/screens/notifications/notifications_screen.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(null);
  @override
  Future<dynamic> get(String path) async {
    if (path.startsWith('/vehicles/') && path.endsWith('/notifications')) {
      // Force the error branch so `controller.text` is never assigned.
      throw ApiException(500, 'boom');
    }
    throw ApiException(404, path);
  }

  @override
  Future<dynamic> put(String path, [Object? body, Map<String, String>? headers]) async => null;
  @override
  Future<dynamic> post(String path, [Object? body, Map<String, String>? headers]) async => null;
  @override
  Future<dynamic> delete(String path) async => null;
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
  testWidgets('original screen renders full set of cards',
      (WidgetTester t) async {
    await t.pumpWidget(_app());
    for (var i = 0; i < 50; i++) {
      await t.pump(const Duration(milliseconds: 100));
      if (find.text('Discord webhook').evaluate().isNotEmpty) break;
    }
    debugDumpApp();
    // ignore: avoid_print
    print('ORIG cards=${t.widgetList(find.byType(Card)).length}');
    // ignore: avoid_print
    print('ORIG channels=${find.text('Channels').evaluate().length}');
    // ignore: avoid_print
    print('ORIG service_due=${find.text('Service due alerts').evaluate().length}');
    // ignore: avoid_print
    print('ORIG discord(skipOffstage false)=${find.text("Discord webhook", skipOffstage: false).evaluate().length}');
    // ignore: avoid_print
    print('ORIG save(skipOffstage false)=${find.text("Save notification settings", skipOffstage: false).evaluate().length}');
  });
}
