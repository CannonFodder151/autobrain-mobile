/// Store-native IAP (Apple StoreKit / Google Play Billing) for store builds.
///
/// Wraps the official `in_app_purchase` plugin and exposes the server-driven
/// IAP catalogue plus the store purchase stream for the License screen. Only
/// active on store builds (MOBILE_STORE_BUILD) where the backend advertises an
/// IAP catalogue (GET /billing/iap/catalog); web and self-hosted builds keep
/// the external browser purchase path (AUT-610).
library;

import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

import '../core/config.dart';

/// Server-advertised IAP catalogue (GET /billing/iap/catalog).
class IapCatalog {
  IapCatalog({required this.enabled, required this.products});

  factory IapCatalog.fromJson(Map<String, dynamic> json) {
    final list = (json['products'] as List?) ?? const [];
    return IapCatalog(
      enabled: json['enabled'] == true,
      products: [
        for (final p in list)
          IapProduct.fromJson(Map<String, dynamic>.from(p as Map)),
      ],
    );
  }

  final bool enabled;
  final List<IapProduct> products;

  /// Products for [platform] (android|ios), keyed by store product id.
  Map<String, IapProduct> forPlatform(String platform) => {
        for (final p in products)
          if (p.platform == platform) p.productId: p,
      };
}

/// A single store product in the catalogue, mapped to an AutoBrain plan.
class IapProduct {
  IapProduct({
    required this.productId,
    required this.platform,
    required this.plan,
    required this.billing,
  });

  factory IapProduct.fromJson(Map<String, dynamic> json) => IapProduct(
        productId: json['product_id'] as String,
        platform: json['platform'] as String,
        plan: json['plan'] as String,
        billing: json['billing'] as String,
      );

  final String productId;
  final String platform;
  final String plan;
  final String billing;
}

/// Thin facade over [InAppPurchase] (StoreKit / Play Billing).
class IapService {
  IapService._();

  static final IapService instance = IapService._();

  final InAppPurchase _iap = InAppPurchase.instance;
  final StreamController<PurchaseDetails> _updates =
      StreamController<PurchaseDetails>.broadcast();
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  /// Real-time store purchase updates (purchased / restored / pending / error).
  Stream<PurchaseDetails> get updates => _updates.stream;

  /// True when this build is a store build compiled for IAP.
  static bool get storeBuild => AppConfig.storeBuild;

  /// Whether the platform payment client is ready (Play Billing / StoreKit).
  Future<bool> isAvailable() => _iap.isAvailable();

  /// Fetches store product details for the given store product ids.
  Future<ProductDetailsResponse> queryProducts(Set<String> ids) =>
      _iap.queryProductDetails(ids);

  /// Starts a purchase for [product] (subscription or non-consumable).
  Future<bool> buy(ProductDetails product) => _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );

  /// Restores past purchases. On iOS this is the App Store restore; on Android
  /// it returns the account's owned items from Play Billing.
  Future<void> restorePurchases() => _iap.restorePurchases();

  /// Finalises a delivered purchase. On Android this acknowledges the purchase
  /// to Play Billing (required within 3 days of purchase); on iOS it clears
  /// the transaction from Apple's unfinished-transaction queue.
  Future<void> complete(PurchaseDetails purchase) =>
      _iap.completePurchase(purchase);

  /// Starts listening to the store purchase stream (idempotent).
  void listen() {
    if (_subscription != null) return;
    _subscription = _iap.purchaseStream.listen((details) {
      for (final d in details) {
        _updates.add(d);
      }
    });
  }
}
