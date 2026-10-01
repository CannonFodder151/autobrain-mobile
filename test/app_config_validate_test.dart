// AUT-4811 — AppConfig.validate() was referenced by main.dart, app.dart and
// MisconfiguredBackendScreen but never implemented, leaving `flutter analyze`
// red on main and the boot error-handling path dead code.
import 'dart:convert';
import 'dart:io';

import 'package:autobrain/core/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final apiBaseBefore = AppConfig.apiBase;
  tearDown(() {
    AppConfig.serverConfigured = false;
    AppConfig.apiBase = apiBaseBefore;
    AppConfig.lastValidationOk = null;
    AppConfig.lastValidationError = null;
  });

  test('validate() is inconclusive when no server has been chosen', () async {
    // A fresh install still points at the compiled default (localhost); probing
    // it would report a false failure and wrongly block boot.
    AppConfig.serverConfigured = false;
    await AppConfig.validate();
    expect(AppConfig.lastValidationOk, isNull);
    expect(AppConfig.lastValidationError, isNull);
  });

  test('validate() records ok against a live /health endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'status': 'ok', 'version': '0.3.275'}));
      req.response.close();
    });
    addTearDown(() => server.close(force: true));

    AppConfig.serverConfigured = true;
    AppConfig.apiBase = 'http://127.0.0.1:${server.port}/api/v1';

    await AppConfig.validate();
    expect(AppConfig.lastValidationOk, isTrue);
    expect(AppConfig.lastValidationError, isNull);
  });

  test('validate() fails closed on an unreachable host', () async {
    // Bind then immediately release to get a port nothing is listening on.
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close(force: true);

    AppConfig.serverConfigured = true;
    AppConfig.apiBase = 'http://127.0.0.1:$deadPort/api/v1';

    await AppConfig.validate();
    expect(AppConfig.lastValidationOk, isFalse);
    expect(AppConfig.lastValidationError, isNotNull);
  });

  test('validate() treats 5xx as unhealthy, 4xx as reachable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var code = 401;
    server.listen((req) {
      req.response.statusCode = code;
      req.response.close();
    });
    addTearDown(() => server.close(force: true));

    AppConfig.serverConfigured = true;
    AppConfig.apiBase = 'http://127.0.0.1:${server.port}/api/v1';

    await AppConfig.validate();
    expect(AppConfig.lastValidationOk, isTrue,
        reason: 'an HTTP 401 proves the host is up');

    code = 503;
    await AppConfig.validate();
    expect(AppConfig.lastValidationOk, isFalse);
    expect(AppConfig.lastValidationError, contains('503'));
  });

  test('validate() never throws on a malformed apiBase', () async {
    AppConfig.serverConfigured = true;
    AppConfig.apiBase = 'not a url::';
    await expectLater(AppConfig.validate(), completes);
    expect(AppConfig.lastValidationOk, isFalse);
  });
}
