/// Runtime permissions the phone-side auto-trip path needs (AUT-367).
///
/// On Android 12+ (targetSdk 36) the app must HOLD these at runtime or the
/// whole path silently no-ops: without `BLUETOOTH_CONNECT` the system drops
/// the car-kit ACL broadcasts (the trip trigger), without
/// `ACCESS_FINE_LOCATION` the GPS speed guard never streams, and without
/// `POST_NOTIFICATIONS` the foreground-service notification is hidden. The
/// 2026-08-12 drive test exposed exactly this — T1/T3/T4 failing while T2
/// "passed" trivially because nothing ever fired. Web/desktop: no-op.
library;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class CarPermissions {
  /// Requests the permissions the phone path needs; true when all granted.
  /// Tolerant: partial grants degrade the path gracefully rather than crash.
  static Future<bool> ensure() async {
    if (!supported) return true;
    final statuses = await <Permission>[
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
