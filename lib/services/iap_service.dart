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
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

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
    this.trialDays,
  });

  factory IapProduct.fromJson(Map<String, dynamic> json) => IapProduct(
        productId: json['product_id'] as String,
        platform: json['platform'] as String,
        plan: json['plan'] as String,
        billing: json['billing'] as String,
        trialDays: json['trial_days'] as int?,
      );

  final String productId;
  final String platform;
  final String plan;
  final String billing;

  /// Days of the free-trial period advertised by the server catalogue, if any
  /// (fallback when the store SDK does not expose an introductory offer).
  final int? trialDays;
}

/// Detects the free-trial period (in days) of a store product from the SDK's
/// product details. Returns `null` when the product has no introductory offer
/// or the SDK does not expose one; callers fall back to the catalogue
/// `trial_days` field in that case (AUT-1198).
int? trialDaysFrom(ProductDetails product) {
  // Google Play: an introductory offer is a pricing phase at zero cost with a
  // finite recurrence before the paid phase, e.g. P7D free then P1M paid.
  if (product is GooglePlayProductDetails) {
    for (final offer in product.productDetails.subscriptionOfferDetails ??
        const <SubscriptionOfferDetailsWrapper>[]) {
      for (final phase in offer.pricingPhases) {
        if (phase.priceAmountMicros == 0 && phase.billingPeriod.isNotEmpty) {
          final days = _daysFromIso8610(phase.billingPeriod);
          if (days != null && days > 0) return days;
        }
      }
    }
  }
  // iOS StoreKit 1: SKProduct exposes the introductory offer's period.
  if (product is AppStoreProductDetails) {
    final intro = product.skProduct.introductoryPrice;
    if (intro != null) {
      final days = _daysFromStoreKitPeriod(intro.subscriptionPeriod);
      if (days != null && days > 0) return days;
    }
  }
  // iOS StoreKit 2: the plugin wrapper does not surface the introductory offer
  // in this version, so catalog trial_days is the fallback for iOS.
  return null;
}

/// Parses an ISO 8601 duration like "P7D" / "P1W" / "P1M" / "P1Y" into days.
int? _daysFromIso8610(String duration) {
  final match = RegExp(r'^P(?:(\d+)D)?(?:(\d+)W)?(?:(\d+)M)?(?:(\d+)Y)?$')
      .firstMatch(duration);
  if (match == null) return null;
  final values = [
    int.tryParse(match.group(1) ?? ''),
    int.tryParse(match.group(2) ?? ''),
    int.tryParse(match.group(3) ?? ''),
    int.tryParse(match.group(4) ?? ''),
  ];
  final days = (values[0] ?? 0) +
      (values[1] ?? 0) * 7 +
      (values[2] ?? 0) * 30 +
      (values[3] ?? 0) * 365;
  return days > 0 ? days : null;
}

/// Converts a StoreKit 1 subscription period (days/weeks/months/years) to days.
int? _daysFromStoreKitPeriod(SKProductSubscriptionPeriodWrapper period) {
  switch (period.unit) {
    case SKSubscriptionPeriodUnit.day:
      return period.numberOfUnits;
    case SKSubscriptionPeriodUnit.week:
      return period.numberOfUnits * 7;
    case SKSubscriptionPeriodUnit.month:
      return period.numberOfUnits * 30;
    case SKSubscriptionPeriodUnit.year:
      return period.numberOfUnits * 365;
  }
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
