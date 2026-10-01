import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Runtime configuration.
///
/// The base URLs are compiled in via --dart-define as defaults. On mobile the
/// user can override them at runtime via the server picker (stored in
/// SharedPreferences) so a single APK can target the hosted subscription or
/// any self-hosted server. On web/desktop the compiled URL is always used.
class AppConfig {
  static const String _defaultApiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000/api/v1',
  );
  static const String _defaultWsBase = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'ws://localhost:8000/ws',
  );

  static const String _prefsKey = 'server_config';

  /// Whether a server has been resolved yet (picker only runs on mobile).
  static bool serverConfigured = false;

  static String apiBase = _defaultApiBase;
  static String wsBase = _defaultWsBase;

  /// Result of the last [validate] probe: null = never run / inconclusive,
  /// true = backend answered, false = backend unreachable.
  static bool? lastValidationOk;

  /// Human-readable reason for the last failed [validate] probe.
  static String? lastValidationError;

  /// Hard ceiling on the boot probe. Boot must not stall on a dead host, so
  /// the request is abandoned rather than awaited indefinitely.
  static const Duration validateTimeout = Duration(seconds: 5);

  /// Boot-time reachability probe (AUT-2272 M0).
  ///
  /// GETs the unauthenticated `/health` endpoint and records the outcome in
  /// [lastValidationOk] / [lastValidationError]. Never throws — callers treat
  /// a probe failure as diagnostic information, not a fatal error.
  static Future<void> validate() async {
    lastValidationError = null;
    // The default base points at localhost until the picker runs, so probing
    // it would report a false failure on a fresh install.
    if (!serverConfigured) {
      lastValidationOk = null;
      return;
    }
    try {
      final origin = apiBase.replaceFirst(RegExp(r'/api/v1/?$'), '');
      final res = await http
          .get(
            Uri.parse('$origin/health'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(validateTimeout);
      // Any HTTP answer means the host is up and reachable. A 401/404 from a
      // misconfigured path is a routing problem, not an unreachable backend.
      lastValidationOk = true;
      if (res.statusCode >= 500) {
        lastValidationOk = false;
        lastValidationError = 'backend returned HTTP ${res.statusCode}';
      }
    } catch (e) {
      lastValidationOk = false;
      lastValidationError = _describeProbeError(e);
    }
  }

  static String _describeProbeError(Object e) {
    final s = e.toString();
    if (s.contains('TimeoutException')) return 'timeout after ${validateTimeout.inSeconds}s';
    if (s.contains('SocketException') || s.contains('Connection refused')) {
      return 'connection refused';
    }
    if (s.contains('Failed host lookup')) return 'DNS lookup failed';
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  /// Whether running natively on Android/iOS (as opposed to web/desktop).
  static bool get isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether this build is a store build (App Store / Google Play) compiled
  /// for store-native IAP. Set via --dart-define=MOBILE_STORE_BUILD=true in
  /// the store release pipeline; web and self-hosted/sideloaded builds leave
  /// it off and keep the external browser purchase path (AUT-610).
  static const bool storeBuild = bool.fromEnvironment('MOBILE_STORE_BUILD');

  /// Loads a saved server selection (called once at startup).
  static Future<void> load() async {
    // Web and desktop always use the compiled base URL — no picker.
    if (!isMobile) {
      serverConfigured = true;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && saved.isNotEmpty) {
      final parts = saved.split('|');
      if (parts.length == 2) {
        apiBase = parts[0];
        wsBase = parts[1];
        serverConfigured = true;
        return;
      }
    }
    // Demo build is pre-wired to the demo instance — no picker needed.
    if (_defaultApiBase.contains('demo.autobrainservice.app')) {
      serverConfigured = true;
    }
  }

  /// Persists the chosen server and applies it immediately.
  static Future<void> setServer({
    required String apiBaseUrl,
    required String wsBaseUrl,
  }) async {
    apiBase = apiBaseUrl;
    wsBase = wsBaseUrl;
    serverConfigured = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, '$apiBaseUrl|$wsBaseUrl');
  }

  /// Builds API/WS base URLs from a custom server host + optional port.
  /// `secure=true` uses https/wss (typical for 443), otherwise http/ws.
  static ({String api, String ws}) customBase(
      String host, int? port, bool secure) {
    final scheme = secure ? 'https' : 'http';
    final wsScheme = secure ? 'wss' : 'ws';
    final authority = port == null || port == (secure ? 443 : 80)
        ? host
        : '$host:$port';
    return (
      api: '$scheme://$authority/api/v1',
      ws: '$wsScheme://$authority/ws',
    );
  }

  /// Hosted subscription target.
  static const hostedApi = 'https://hosted.autobrainservice.app/api/v1';
  static const hostedWs = 'wss://hosted.autobrainservice.app/ws';
}
