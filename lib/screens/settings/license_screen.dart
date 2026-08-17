import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/auth_state.dart';
import '../../core/config.dart';
import '../../services/iap_service.dart';

/// License/subscription purchase.
///
/// Store builds (MOBILE_STORE_BUILD) purchase via Apple StoreKit / Google
/// Play Billing; a store build with no IAP catalogue available shows a
/// not-configured state and never falls back to the external Stripe path
/// (AUT-931, Google Play policy). Web and self-hosted builds keep the
/// external browser (Stripe) path (AUT-531).
class LicenseScreen extends StatefulWidget {
  const LicenseScreen({super.key});

  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  static const _fallbackPlans = [
    {'key': 'enthusiast', 'name': 'Enthusiast', 'monthly': 900, 'yearly': 8400},
    {'key': 'garage', 'name': 'Garage', 'monthly': 1900, 'yearly': 16800},
  ];

  final _promoController = TextEditingController();

  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _plans = _fallbackPlans;
  Map<String, dynamic> _sale = const {};
  String _currency = 'aud';
  bool _saleActive = false;
  bool _loading = true;
  bool _yearly = false;
  bool _busy = false;
  String? _error;

  bool _iapMode = false;
  Map<String, IapProduct> _iapProducts = const {};
  Map<String, ProductDetails> _storeProducts = const {};
  StreamSubscription<PurchaseDetails>? _iapSub;

  String get _platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  String? get _subStatus => _profile?['subscription_status'] as String?;
  bool get _hasSub =>
      _subStatus == 'active' ||
      _subStatus == 'trialing' ||
      _subStatus == 'past_due' ||
      _profile?['iap_status'] == 'active';
  int get _maxVehicles => (_profile?['max_vehicles'] as int?) ?? 1;

  /// Store build whose server does not advertise an IAP catalogue. Store
  /// policies (Google Play / App Store) forbid paying outside store billing,
  /// so this build must never show the external Stripe path (AUT-931).
  bool get _iapUnavailable =>
      AppConfig.storeBuild && AppConfig.isMobile && !_iapMode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _iapSub?.cancel();
    _promoController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<AuthState>().api;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final me = await api.get('/auth/me') as Map<String, dynamic>;
      setState(() => _profile = me);
    } catch (_) {
      setState(() => _error = 'Could not load your license status.');
    }
    // Pricing is public; ignore failures so a host without it still renders.
    try {
      final data = await api.get('/billing/pricing') as Map<String, dynamic>;
      setState(() {
        _currency = (data['currency'] as String?) ?? 'aud';
        _sale = (data['sale'] as Map<String, dynamic>?) ?? const {};
        _saleActive = _sale['active'] == true;
        _plans = ((data['plans'] as List?) ?? [])
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList();
        if (_plans.isEmpty) _plans = _fallbackPlans;
      });
    } catch (_) {
      // keep fallback plans
    }
    await _initIap();
    if (mounted) setState(() => _loading = false);
  }

  /// Switches the screen to store-native IAP when this is a store build,
  /// the connected server advertises an IAP catalogue, AND the store query
  /// actually resolves at least one of the advertised products. Entering IAP
  /// mode on the catalogue alone — before confirming the store serves it —
  /// left the plans list empty (no upgrade buttons, blank License, AUT-1004).
  /// When the store cannot resolve any product (unavailable, unconfigured, or
  /// the account lacks them) `_iapMode` stays off and the not-configured state
  /// renders; it never falls back to Stripe on a store build (AUT-931).
  Future<void> _initIap() async {
    if (!AppConfig.storeBuild || !AppConfig.isMobile) return;
    final api = context.read<AuthState>().api;
    IapCatalog catalog;
    try {
      catalog = IapCatalog.fromJson(
        await api.get('/billing/iap/catalog') as Map<String, dynamic>,
      );
    } catch (_) {
      return; // catalogue missing → not-configured state on store builds
    }
    final platformProducts = catalog.forPlatform(_platform);
    if (!catalog.enabled || platformProducts.isEmpty) return;

    IapService.instance.listen();
    _iapSub ??= IapService.instance.updates.listen(_onIapUpdate);
    final Map<String, ProductDetails> storeProducts;
    try {
      final res = await IapService.instance
          .queryProducts(platformProducts.keys.toSet());
      storeProducts = {for (final p in res.productDetails) p.id: p};
    } catch (_) {
      return; // store query failed → not-configured state on store builds
    }
    if (!platformProducts.keys.any(storeProducts.containsKey)) {
      return; // store serves none of the advertised products (AUT-1004)
    }
    setState(() {
      _iapMode = true;
      _iapProducts = platformProducts;
      _storeProducts = storeProducts;
    });
  }

  void _onIapUpdate(PurchaseDetails purchase) {
    if (!mounted) return;
    switch (purchase.status) {
      case PurchaseStatus.pending:
        _setError('Your purchase is pending approval. It will appear here '
            'once the store confirms it.');
      case PurchaseStatus.error:
        _setError(
            'Purchase failed: ${purchase.error?.message ?? 'unknown error'}');
        _completeIfNeeded(purchase);
      case PurchaseStatus.canceled:
        break;
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        _verifyIap(purchase);
    }
  }

  /// Sends the store transaction to the backend for verification. Only once
  /// the server has granted the entitlement is the purchase completed
  /// (acknowledged on Android / cleared from Apple's queue on iOS) — that way
  /// a failed verification re-delivers the purchase instead of losing it.
  Future<void> _verifyIap(PurchaseDetails purchase) async {
    if (!mounted) return;
    final api = context.read<AuthState>().api;
    final auth = context.read<AuthState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.post('/billing/iap/verify', {
        'platform': _platform,
        'product_id': purchase.productID,
        'transaction_id': purchase.purchaseID ?? '',
        'purchase_token': purchase.verificationData.serverVerificationData,
        'purchase_time_ms': purchase.transactionDate,
      });
      await auth.refreshProfile();
      if (!mounted) return;
      final restored = purchase.status == PurchaseStatus.restored;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(restored
            ? 'Your licence has been restored.'
            : 'Thank you — your licence is active.'),
      ));
      await _completeIfNeeded(purchase);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'The purchase was recorded by the store but your '
          'licence could not be activated: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeIfNeeded(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    try {
      await IapService.instance.complete(purchase);
    } catch (_) {
      // Retried on the next purchase-stream delivery.
    }
  }

  Future<void> _iapPurchase(String productId) async {
    final product = _storeProducts[productId];
    if (product == null) {
      setState(() => _error = 'This plan is not available from the store yet.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await IapService.instance.buy(product);
      if (!ok && mounted) {
        setState(() => _error = 'The purchase could not be started.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start the purchase: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restorePurchases() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await IapService.instance.restorePurchases();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not restore purchases: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setError(String message) {
    if (mounted) setState(() => _error = message);
  }

  Future<void> _checkout(String plan) async {
    final api = context.read<AuthState>().api;
    final promo = _promoController.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await api.post('/billing/checkout', {
        'plan': plan,
        'billing': _yearly ? 'yearly' : 'monthly',
        if (promo.isNotEmpty) 'promo_code': promo,
      }) as Map<String, dynamic>;
      await _openUrl(data['url'] as String);
    } on ApiException catch (e) {
      final notConfigured =
          e.statusCode == 503 || e.message.contains('not configured');
      setState(() => _error = notConfigured
          ? 'Payments are not enabled on this server yet. Contact support to '
              'upgrade your licence.'
          : 'Could not start checkout: ${e.message}');
    } catch (e) {
      setState(() => _error = 'Could not start checkout: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _portal() async {
    final api = context.read<AuthState>().api;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data =
          await api.post('/billing/portal') as Map<String, dynamic>;
      await _openUrl(data['url'] as String);
    } catch (e) {
      setState(() => _error = 'Could not open billing: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Store subscriptions are managed in the store itself, not a Stripe portal.
  Future<void> _openStoreSubscriptions() async {
    final url = _platform == 'ios'
        ? 'https://apps.apple.com/account/subscriptions'
        : 'https://play.google.com/store/account/subscriptions';
    await _openUrl(url);
  }

  /// Opens [url] in an external browser. Android 11+ hides other apps unless
  /// the manifest declares the https/http VIEW intents (AUT-926); when no
  /// handler resolves or the launch still fails, surface an actionable error
  /// and copy the link to the clipboard instead of a silent "Could not open".
  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await canLaunchUrl(uri)) {
      await Clipboard.setData(ClipboardData(text: url));
      _setError('No browser is installed to open the payment link. '
          'The link was copied to your clipboard — paste it into any browser.');
      return;
    }
    final ok =
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      await Clipboard.setData(ClipboardData(text: url));
      _setError('The payment page could not be opened. '
          'The link was copied to your clipboard — paste it into your '
          'browser and try again.');
    }
  }

  String _fmt(int cents) {
    final whole = cents ~/ 100;
    final frac = (cents % 100).toString().padLeft(2, '0');
    final symbol = _currency == 'aud' ? 'A\$' : '\$';
    return '$symbol$whole.$frac';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('License')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _statusCard(context),
                  if (_iapUnavailable) ...[
                    const SizedBox(height: 20),
                    _iapNotConfigured(context),
                  ] else if (!_iapMode) ...[
                    if (_saleActive) ...[
                      const SizedBox(height: 16),
                      _saleBanner(context),
                    ],
                    const SizedBox(height: 20),
                    Text('Plans',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('Upgrade any time — billed monthly or yearly by '
                        'Stripe. Cancel from your billing portal; your account '
                        'stays upgraded until the end of the period.',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Billing period'),
                        const Spacer(),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                                value: false, label: Text('Monthly')),
                            ButtonSegment(value: true, label: Text('Yearly')),
                          ],
                          selected: {_yearly},
                          onSelectionChanged: (s) =>
                              setState(() => _yearly = s.first),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _promoField(context),
                    const SizedBox(height: 8),
                    for (final plan in _plans) ...[
                      _planCard(context, plan),
                      const SizedBox(height: 16),
                    ],
                  ] else ...[
                    const SizedBox(height: 20),
                    Text('Plans',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('Upgrade any time — billed monthly or yearly by the '
                        'app store. Manage or cancel your subscription from '
                        'your store account.',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Billing period'),
                        const Spacer(),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                                value: false, label: Text('Monthly')),
                            ButtonSegment(value: true, label: Text('Yearly')),
                          ],
                          selected: {_yearly},
                          onSelectionChanged: (s) =>
                              setState(() => _yearly = s.first),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _IapPlansList(context),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: TextStyle(color: Colors.red.shade600)),
                  ],
                ],
              ),
            ),
    );
  }

  /// IAP plans for the selected billing period, in a stable plan order.
  List<(IapProduct, ProductDetails)> _iapPlansForPeriod() {
    const order = {'enthusiast': 0, 'garage': 1};
    final period = _yearly ? 'yearly' : 'monthly';
    final result = <(IapProduct, ProductDetails)>[];
    for (final entry in _iapProducts.entries) {
      final iap = entry.value;
      final store = _storeProducts[entry.key];
      if (iap.billing != period || store == null) continue;
      result.add((iap, store));
    }
    result.sort((a, b) => (order[a.$1.plan] ?? 9) - (order[b.$1.plan] ?? 9));
    return result;
  }

  Widget _IapPlansList(BuildContext context) {
    final plans = _iapPlansForPeriod();
    if (plans.isEmpty) {
      return Text('No plans are available from the store for this '
          'billing period yet. Try the other period.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (iap, store) in plans) ...[
          _iapPlanCard(context, iap, store),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _iapNotConfigured(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.storefront_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('In-app purchase is not configured yet',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Upgrades are only available through the app store on this '
                'build. Please update the app to the latest version to buy or '
                'manage your licence.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _saleBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary),
      ),
      child: Row(
        children: [
          Icon(Icons.local_fire_department, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Early-adopter sale — 40% off your first 3 months. '
              'First 100 subscribers only.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _promoField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entered = _promoController.text.trim().toUpperCase();
    final code = (_sale['code'] as String? ?? 'EARLY40').toUpperCase();
    final matches = entered.isNotEmpty && entered == code;
    return TextField(
      controller: _promoController,
      textCapitalization: TextCapitalization.characters,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
      ],
      decoration: InputDecoration(
        labelText: 'Promo code',
        hintText: 'e.g. $code',
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: matches
            ? Icon(Icons.check_circle, color: Colors.green.shade600)
            : null,
        helperText: matches
            ? '40% off your first 3 months applied at checkout'
            : 'Applied automatically at checkout when entered.',
        helperStyle: TextStyle(
          color: matches ? Colors.green.shade700 : scheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _planCard(BuildContext context, Map<String, dynamic> plan) {
    final scheme = Theme.of(context).colorScheme;
    final key = plan['key'] as String;
    final name = plan['name'] as String;
    final monthly = plan['monthly'] as int? ?? 900;
    final yearly = plan['yearly'] as int? ?? 8400;
    final saleMonthly = plan['sale_monthly'] as int?;
    final isGarage = key == 'garage';
    final vehicles = isGarage ? 5 : 1;

    final String price;
    final String period;
    if (_yearly) {
      price = _fmt(yearly);
      period = '/year';
    } else if (_saleActive && saleMonthly != null) {
      price = _fmt(saleMonthly);
      period = '/month';
    } else {
      price = _fmt(monthly);
      period = '/month';
    }

    return Card(
      shape: isGarage
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.primary, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (isGarage)
                  Chip(
                    label: const Text('Most popular'),
                    labelStyle: TextStyle(color: scheme.primary, fontSize: 12),
                    side: BorderSide(color: scheme.primary),
                    backgroundColor: scheme.primary.withValues(alpha: 0.1),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(price,
                    style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary)),
                const SizedBox(width: 4),
                Text(period,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                if (_saleActive && saleMonthly != null && !_yearly) ...[
                  const SizedBox(width: 8),
                  Text(_fmt(monthly),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        decoration: TextDecoration.lineThrough,
                      )),
                  const SizedBox(width: 6),
                  Chip(
                    label: const Text('40% off'),
                    labelStyle: TextStyle(color: Colors.green.shade800),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: Colors.green.shade400),
                    backgroundColor: Colors.green.withValues(alpha: 0.08),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text('$vehicles vehicle${vehicles == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ..._featuresFor(key).map(
              (f) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(Icons.check_circle,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : () => _checkout(key),
                child: Text('Upgrade to $name'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iapPlanCard(
      BuildContext context, IapProduct iap, ProductDetails store) {
    final scheme = Theme.of(context).colorScheme;
    final name = _nameFor(iap.plan);
    final isGarage = iap.plan == 'garage';
    final vehicles = isGarage ? 5 : 1;

    return Card(
      shape: isGarage
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.primary, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (isGarage)
                  Chip(
                    label: const Text('Most popular'),
                    labelStyle: TextStyle(color: scheme.primary, fontSize: 12),
                    side: BorderSide(color: scheme.primary),
                    backgroundColor: scheme.primary.withValues(alpha: 0.1),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(store.price,
                    style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary)),
                const SizedBox(width: 4),
                Text(_yearly ? '/year' : '/month',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 4),
            Text('$vehicles vehicle${vehicles == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ..._featuresFor(iap.plan).map(
              (f) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(Icons.check_circle,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : () => _iapPurchase(iap.productId),
                child: Text('Upgrade to $name'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _nameFor(String key) {
    for (final plan in _plans) {
      if (plan['key'] == key) return plan['name'] as String;
    }
    return key == 'garage' ? 'Garage' : 'Enthusiast';
  }

  List<String> _featuresFor(String key) {
    return key == 'garage'
        ? const [
            '5 vehicles',
            'All AI features included',
            'Rego lookup',
            'Priority support',
          ]
        : const [
            '1 vehicle',
            'All AI features included',
            'Rego lookup',
          ];
  }

  Widget _statusCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final IconData icon;
    final String title;
    final String subtitle;
    final Color color;
    if (_hasSub) {
      icon = Icons.verified_user;
      color = Colors.green;
      title = 'Subscription active';
      subtitle = _iapMode
          ? 'You have full access to AutoBrain. Managed by your app store '
              'account.'
          : 'You have full access to AutoBrain. Managed by Stripe.';
    } else {
      icon = Icons.info_outline;
      color = Colors.blue;
      title = 'No active subscription';
      subtitle = '$_maxVehicles vehicle, no AI. '
          'Upgrade for rego lookup and more vehicles.';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                if (_hasSub && (_iapMode || !AppConfig.storeBuild))
                  IconButton(
                    icon: const Icon(Icons.manage_accounts_outlined),
                    tooltip: 'Manage subscription',
                    onPressed: _busy
                        ? null
                        : _iapMode
                            ? _openStoreSubscriptions
                            : _portal,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(subtitle,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            if (_hasSub && _iapMode && _platform == 'ios') ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : _restorePurchases,
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('Restore purchases'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
