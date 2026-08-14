/// Global auth + navigation state (ChangeNotifier via provider).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'config.dart';
import 'token_store.dart';
import 'version_check.dart';

enum LoginOutcome { ok, mfaRequired, mfaSetupRequired, failed }

/// Credentials live in secure storage (Keystore/Keychain) so they are not
/// readable as plaintext on disk / from app backups. Non-sensitive prefs
/// (dark mode, server picker) stay in SharedPreferences.
class AuthState extends ChangeNotifier {
  AuthState() {
    _restore();
  }

  String? _token;
  String? _refreshToken;
  String? _role;
  String? _userId;
  String? _mfaToken;
  bool _darkMode = true;
  bool _signupEnabled = true;
  bool _licenseEnabled = false;
  bool _freeAccount = false;
  bool _updateAvailable = false;
  String? _latestVersion;
  String? _installedVersion;
  String? _serverVersion;
  bool _releaseReachable = false;
  String? _releaseSource; // 'github' | 'server' | null
  String? get token => _token;
  String? get role => _role;
  String? get userId => _userId;
  String? get mfaTokenHint => _mfaToken;
  bool get darkMode => _darkMode;
  bool get isLoggedIn => _token != null;
  bool get isAdmin => _role == 'admin';
  bool get isDemo => _role == 'demo';
  /// Free-tier accounts cannot access premium features (Community Garage).
  bool get freeAccount => _freeAccount;
  bool get premium => !_freeAccount;
  /// Whether this server allows self-service signup (from /auth/config).
  bool get signupEnabled => _signupEnabled;
  /// Whether the licence/upgrade feature is enabled on this server
  /// (LICENSE_ENABLED env var; on for hosted, off for demo/default).
  bool get licenseEnabled => _licenseEnabled;
  /// Latest known mobile release (GitHub release tag when reachable,
  /// otherwise the release advertised by this server from /auth/config).
  String? get latestVersion => _latestVersion;
  /// Installed mobile app version (from PackageInfo).
  String? get installedVersion => _installedVersion;
  /// Version of the connected backend server (from GET /health).
  String? get serverVersion => _serverVersion;
  /// True when the latest mobile release was read from GitHub directly.
  bool get releaseReachable => _releaseReachable;
  /// Where [latestVersion] came from: 'github' or 'server' fallback.
  String? get releaseSource => _releaseSource;
  /// True when the installed app is older than the latest mobile release.
  bool get updateAvailable => _updateAvailable;

  Future<void> toggleThemeMode() async {
    _darkMode = !_darkMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', _darkMode);
    notifyListeners();
  }

  final TokenStore _tokens = TokenStore();
  ApiClient? _client;
  ApiClient get api => _client!;

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    await AppConfig.load();
    final (token, refreshToken, role) = await _tokens.read();
    _token = token;
    _refreshToken = refreshToken;
    _role = role;
    _darkMode = prefs.getBool('dark_mode') ?? true;
    await _loadConfig();
    _loadVersionInfo();
    if (_token != null) {
      _client = ApiClient(_token, onRefresh: _refreshAccess);
      refreshProfile();
      notifyListeners();
    }
  }

  /// Fetches public server config (self-signup enabled, MFA enforced,
  /// licence feature enabled, current app release). Any failure is silent.
  Future<void> _loadConfig() async {
    try {
      final data = await _anonymous().get('/auth/config') as Map<String, dynamic>;
      _signupEnabled = data['signup_enabled'] != false;
      _licenseEnabled = data['license_enabled'] == true;
      final serverVersion = data['app_version'] as String?;
      if (serverVersion != null && serverVersion.isNotEmpty) {
        _latestVersion = serverVersion;
        _updateAvailable = await _isBehind(serverVersion);
      }
      notifyListeners();
    } catch (_) {
      // Defaults to enabled; the backend still enforces SELF_SIGNUP_ENABLED.
    }
  }

  /// True when the installed app version is older than [serverVersion].
  /// The `+build` suffix is ignored by the comparison helper.
  Future<bool> _isBehind(String serverVersion) async {
    try {
      final info = await PackageInfo.fromPlatform();
      return isVersionNewerThan(serverVersion, info.version);
    } catch (_) {
      return false;
    }
  }

  /// Collects version awareness in the background: installed app version,
  /// connected server version (/health), and the latest mobile release
  /// (GitHub releases/latest, falling back to this server's /auth/config
  /// when GitHub is unreachable). Never throws — shows what we know.
  Future<void> _loadVersionInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _installedVersion = info.version;
    } catch (_) {}
    await _loadServerVersion();
    await _loadLatestRelease();
    notifyListeners();
  }

  Future<void> _loadServerVersion() async {
    try {
      final origin = AppConfig.apiBase.replaceFirst(RegExp(r'/api/v1/?$'), '');
      final res = await http.get(
        Uri.parse('$origin/health'),
        headers: const {'Accept': 'application/json'},
      );
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body is Map && body['version'] is String) {
          _serverVersion = body['version'] as String;
        }
      }
    } catch (_) {
      // Server unreachable — keep null, show what we know.
    }
  }

  /// Latest mobile release via the connected server's /version/mobile proxy.
  /// The autobrain-mobile repo is private, so the app cannot query GitHub
  /// directly; the server reads it with its GITHUB_TOKEN. Falls back to the
  /// server-advertised release from /auth/config when the proxy is unavailable.
  Future<void> _loadLatestRelease() async {
    try {
      final data = await _anonymous()
          .get('/version/mobile') as Map<String, dynamic>;
      final latest = data['latest_version']?.toString();
      if (latest != null && latest.isNotEmpty) {
        _releaseReachable = data['reachable'] != false;
        _releaseSource = 'github';
        _latestVersion = latest.replaceFirst(RegExp(r'^v'), '');
        _updateAvailable = await _isBehind(_latestVersion!);
        return;
      }
    } catch (_) {
      // Proxy unreachable — fall through to the server-advertised release.
    }
    // Conservative fallback: the release this server distributes
    // (/auth/config app_version, already loaded by _loadConfig).
    if (_latestVersion != null) _releaseSource = 'server';
  }

  /// Called after the user picks a server — resets any session and rebuilds
  /// the client against the new base URL.
  Future<void> serverChanged() async {
    _token = null;
    _refreshToken = null;
    _role = null;
    _userId = null;
    _client = null;
    _signupEnabled = true;
    _licenseEnabled = false;
    _freeAccount = false;
    _updateAvailable = false;
    _latestVersion = null;
    _installedVersion = null;
    _serverVersion = null;
    _releaseReachable = false;
    _releaseSource = null;
    await _tokens.clear();
    await _loadConfig();
    _loadVersionInfo();
    notifyListeners();
  }

  Future<void> refreshProfile() async {
    if (_client == null) return;
    try {
      final data = await _client!.get('/auth/me') as Map<String, dynamic>;
      _role = data['role'] as String?;
      _userId = data['id'] as String?;
      _freeAccount = data['free_account'] == true;
      await _tokens.write(token: _token!, refreshToken: _refreshToken, role: _role ?? 'user');
      notifyListeners();
    } catch (_) {}
  }

  Future<LoginOutcome> login(String email, String password) async {
    try {
      final data = await _anonymous().post(
        '/auth/login',
        {'email': email, 'password': password},
      ) as Map<String, dynamic>;
      if (data['mfa_setup_required'] == true && data['mfa_token'] != null) {
        _mfaToken = data['mfa_token'] as String;
        return LoginOutcome.mfaSetupRequired;
      }
      if (data['mfa_required'] == true && data['mfa_token'] != null) {
        _mfaToken = data['mfa_token'] as String;
        return LoginOutcome.mfaRequired;
      }
      await _persist(data);
      return LoginOutcome.ok;
    } catch (_) {
      return LoginOutcome.failed;
    }
  }

  /// Verifies the second factor and completes a login in progress.
  Future<bool> verifyMfa(String mfaToken, String code) async {
    try {
      final data = await _anonymous().post(
        '/auth/mfa/verify',
        {'mfa_token': mfaToken, 'code': code},
      ) as Map<String, dynamic>;
      await _persist(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Starts MFA enrolment during a login in progress (enforced-MFA flow).
  Future<Map<String, dynamic>?> startMfaSetup(String mfaToken) async {
    try {
      return await _anonymous().post(
        '/auth/mfa/setup-session',
        {'mfa_token': mfaToken},
      ) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Completes MFA enrolment, returning true once the session is established.
  Future<bool> completeMfaSetup(String mfaToken, String code) async {
    try {
      final data = await _anonymous().post(
        '/auth/mfa/complete-setup',
        {'mfa_token': mfaToken, 'code': code},
      ) as Map<String, dynamic>;
      await _persist(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Requests a password-reset email (always succeeds; server hides existence).
  Future<void> requestPasswordReset(String email) async {
    await _anonymous().post(
      '/auth/password-reset/request',
      {'email': email},
    );
  }

  /// Registers a Free-tier account (hosted instance). Only display name + email
  /// are collected; the server emails a setup link to choose a password and
  /// enable MFA. No auto-login. Returns null on success, or an error message.
  Future<String?> signup({
    required String email,
    required String displayName,
  }) async {
    try {
      await _anonymous().post(
        '/auth/signup',
        {'email': email, 'display_name': displayName},
      );
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not create your account. Please try again.';
    }
  }

  /// Confirms a password reset with the emailed token.
  Future<bool> confirmPasswordReset(String token, String newPassword) async {
    try {
      await _anonymous().post(
        '/auth/password-reset/confirm',
        {'token': token, 'new_password': newPassword},
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> logout() async {
    final refreshToken = _refreshToken;
    _token = null;
    _refreshToken = null;
    _role = null;
    _userId = null;
    _client = null;
    _freeAccount = false;
    await _tokens.clear();
    if (refreshToken != null) {
      // Best effort, non-blocking: the server bumps the account's
      // token_version, killing every outstanding token.
      _anonymous().post('/auth/logout', {'refresh_token': refreshToken}).ignore();
    }
    notifyListeners();
  }

  ApiClient _anonymous() => ApiClient(null);

  /// Exchanges the refresh token for a fresh pair when an access token expires.
  /// Returns the new access token, or null (forces re-login) on failure.
  Future<String?> _refreshAccess() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) return null;
    try {
      final data = await _anonymous().post(
        '/auth/refresh',
        {'refresh_token': refreshToken},
      ) as Map<String, dynamic>;
      final access = data['access_token'] as String?;
      if (access == null) return null;
      _token = access;
      _refreshToken = data['refresh_token'] as String?;
      await _tokens.write(
        token: access,
        refreshToken: _refreshToken,
        role: _role ?? 'user',
      );
      notifyListeners();
      return access;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist(Map<String, dynamic> map) async {
    final tokenPair = map['token_pair'];
    if (tokenPair is Map<String, dynamic>) {
      map = tokenPair;
    }
    _token = map['access_token'] as String?;
    _refreshToken = map['refresh_token'] as String?;
    _role = ((map['user'] as Map<String, dynamic>?) ?? {})['role'] as String?;
    _userId = ((map['user'] as Map<String, dynamic>?) ?? {})['id'] as String?;
    _client = ApiClient(_token!, onRefresh: _refreshAccess);
    await _tokens.write(token: _token!, refreshToken: _refreshToken, role: _role ?? 'user');
    notifyListeners();
  }
}
