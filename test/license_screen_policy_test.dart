// Play-policy gating on the License screen (AUT-931).
//
// A store build (MOBILE_STORE_BUILD=true) whose server does not advertise an
// IAP catalogue must never show the external Stripe checkout/portal — it shows
// a "not configured" state instead. Web/sideload builds keep the Stripe path.
//
// Run BOTH modes to exercise both branches:
//   flutter test test/license_screen_policy_test.dart
//   flutter test --dart-define=MOBILE_STORE_BUILD=true test/license_screen_policy_test.dart
// Each mode runtime-skips the other branch, so a plain `flutter test` also
// stays green.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:autobrain/core/api_client.dart';
import 'package:autobrain/core/auth_state.dart';
import 'package:autobrain/core/config.dart';
import 'package:autobrain/screens/settings/license_screen.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(null);
  @override
  Future<dynamic> get(String path) async {
    if (path == '/auth/me') {
      return <String, dynamic>{
        'id': 'u1',
        'role': 'user',
        'subscription_status': null,
        'max_vehicles': 1,
      };
    }
    if (path == '/billing/pricing') {
      return <String, dynamic>{
        'currency': 'aud',
        'sale': {'active': false},
        'plans': [
          {'key': 'enthusiast', 'name': 'Enthusiast', 'monthly': 900, 'yearly': 8400},
          {'key': 'garage', 'name': 'Garage', 'monthly': 1900, 'yearly': 16800},
        ],
      };
    }
    throw ApiException(404, 'no catalogue');
  }
}

class _FakeAuth extends AuthState {
  @override
  ApiClient get api => _FakeApi();
}

Widget _app() => ChangeNotifierProvider<AuthState>(
      create: (_) => _FakeAuth(),
      child: const MaterialApp(home: LicenseScreen()),
    );

/// Exercises the store-build branch of the License screen. The platform
/// override must be set/reset inside the test body (flutter_test asserts
/// foundation debug vars are untouched at teardown).
Future<void> _pumpAsAndroid(WidgetTester tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  try {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  testWidgets(
      'store build with no IAP catalogue shows not-configured, never Stripe',
      (WidgetTester tester) async {
        await _pumpAsAndroid(tester);

        expect(find.text('In-app purchase is not configured yet'),
            findsOneWidget);
        expect(find.textContaining('update the app'), findsOneWidget);
        expect(find.textContaining('Upgrade to Enthusiast'), findsNothing);
        expect(find.textContaining('Stripe'), findsNothing);
        expect(find.text('Billing period'), findsNothing);
        expect(find.byType(TextField), findsNothing);
      },
      skip: !AppConfig.storeBuild);

  testWidgets('non-store build keeps the Stripe plans path',
      (WidgetTester tester) async {
        await _pumpAsAndroid(tester);

        expect(find.text('In-app purchase is not configured yet'), findsNothing);
        expect(find.textContaining('Upgrade to Enthusiast'), findsOneWidget);
        expect(find.textContaining('billed monthly or yearly by Stripe'),
            findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
      },
      skip: AppConfig.storeBuild);
}