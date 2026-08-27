// AUT-1198 — Trial badge rendering on the License screen (Stripe path).
//
// Verifies the '7-day free trial' badge renders when the backend advertises
// trial_days and the user has not yet claimed a trial, and is hidden when
// trial_available is false.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:autobrain/core/api_client.dart';
import 'package:autobrain/core/auth_state.dart';
import 'package:autobrain/core/config.dart';
import 'package:autobrain/screens/settings/license_screen.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this._pricing, this._profile) : super(null);

  final Map<String, dynamic> _pricing;
  final Map<String, dynamic> _profile;

  @override
  Future<dynamic> get(String path) async {
    if (path == '/auth/me') return _profile;
    if (path == '/billing/pricing') return _pricing;
    throw ApiException(404, 'no catalogue');
  }
}

class _FakeAuth extends AuthState {
  _FakeAuth(this._api);
  final ApiClient _api;
  @override
  ApiClient get api => _api;
}

Widget _app(ApiClient api) => ChangeNotifierProvider<AuthState>(
      create: (_) => _FakeAuth(api),
      child: const MaterialApp(home: LicenseScreen()),
    );

const _plans = [
  {
    'key': 'enthusiast',
    'name': 'Enthusiast',
    'monthly': 900,
    'yearly': 8400,
    'trial_days': 7,
  },
  {
    'key': 'garage',
    'name': 'Garage',
    'monthly': 1900,
    'yearly': 16800,
  },
];

const _profile = {
  'id': 'u1',
  'role': 'user',
  'subscription_status': null,
  'max_vehicles': 1,
  'trial_available': true,
};

void main() {
  Future<void> pumpEligible(WidgetTester tester, Map<String, dynamic> profile) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(_FakeApi(
        {
          'currency': 'aud',
          'sale': {'active': false},
          'plans': _plans,
        },
        profile,
      )),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'shows "7-day free trial" badge on plan card when trial_days is present and user is eligible',
      (WidgetTester tester) async {
    await pumpEligible(tester, _profile);

    expect(find.text('7-day free trial'), findsOneWidget);
    expect(find.textContaining('Start 7-day free trial'), findsOneWidget);
    // Garage plan has no trial
    expect(find.textContaining('Upgrade to Garage'), findsOneWidget);
  },
      skip: AppConfig.storeBuild);

  testWidgets(
      'hides trial badge when trial_available is false (user already used trial)',
      (WidgetTester tester) async {
    await pumpEligible(tester, {
      ..._profile,
      'trial_available': false,
    });

    expect(find.text('7-day free trial'), findsNothing);
    expect(find.textContaining('Start 7-day free trial'), findsNothing);
    // Stripe upgrade buttons still show
    expect(find.textContaining('Upgrade to Enthusiast'), findsOneWidget);
    expect(find.textContaining('Upgrade to Garage'), findsOneWidget);
  },
      skip: AppConfig.storeBuild);
}