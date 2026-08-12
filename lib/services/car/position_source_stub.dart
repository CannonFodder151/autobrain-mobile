/// No-op GPS position source for platforms without a geolocation stream
/// (web/desktop). See [position_source_io.dart] for Android/iOS.
library;

import 'dart:async';

import 'car_kit_trip_monitor.dart';

class PositionSourceImpl {
  static PositionSource create() => const _NoopPosition();

  static const String channelName = 'autobrain/position';
}

class _NoopPosition implements PositionSource {
  const _NoopPosition();

  @override
  Stream<GpsFix> get fixes => const Stream.empty();
}
