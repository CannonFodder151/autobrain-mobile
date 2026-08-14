// IAP catalogue parsing + platform filtering (AUT-610).

import 'package:flutter_test/flutter_test.dart';

import 'package:autobrain/services/iap_service.dart';

void main() {
  test('IapCatalog.fromJson parses enabled flag and products', () {
    final catalog = IapCatalog.fromJson({
      'enabled': true,
      'products': [
        {
          'product_id': 'com.autobrainservice.app.enthusiast.monthly',
          'platform': 'android',
          'plan': 'enthusiast',
          'billing': 'monthly',
        },
        {
          'product_id': 'com.autobrainservice.app.enthusiast.monthly',
          'platform': 'ios',
          'plan': 'enthusiast',
          'billing': 'monthly',
        },
        {
          'product_id': 'com.autobrainservice.app.garage.yearly',
          'platform': 'android',
          'plan': 'garage',
          'billing': 'yearly',
        },
      ],
    });

    expect(catalog.enabled, isTrue);
    expect(catalog.products, hasLength(3));

    final android = catalog.forPlatform('android');
    expect(android.keys, contains('com.autobrainservice.app.enthusiast.monthly'));
    expect(android['com.autobrainservice.app.garage.yearly']?.plan, 'garage');
    expect(catalog.forPlatform('android'), isNot(contains('ios')));
    expect(catalog.forPlatform('android').length, 2);
  });

  test('IapCatalog.fromJson tolerates a missing products list', () {
    final catalog = IapCatalog.fromJson({'enabled': false});
    expect(catalog.enabled, isFalse);
    expect(catalog.products, isEmpty);
    expect(catalog.forPlatform('android'), isEmpty);
  });
}
