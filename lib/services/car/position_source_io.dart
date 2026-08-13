/// Geolocator-backed GPS position source for the phone-side auto trip path
/// (AUT-395). Streams lat/lon fixes from the platform position stream.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'car_kit_trip_monitor.dart';

class PositionSourceImpl {
  static PositionSource create() => _GeolocatorPositionSource();

  static const int distanceFilterMeters = 0;
  static const Duration interval = Duration(seconds: 1);
}

class _GeolocatorPositionSource implements PositionSource {
  @override
  Stream<GpsFix> get fixes {
    final stream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: PositionSourceImpl.distanceFilterMeters,
        timeLimit: null,
      ),
    );
    return stream.map((p) => GpsFix(p.latitude, p.longitude));
  }
}
