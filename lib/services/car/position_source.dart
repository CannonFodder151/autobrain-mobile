/// GPS position source for the phone-side auto trip path (AUT-395).
///
/// Streams lat/lon fixes (WGS84) from the platform geolocator while the phone
/// is recording a drive; web/desktop get a no-op via the conditional import,
/// so the web build never links the geolocator channel.
library;

import 'position_source_stub.dart'
    if (dart.library.io) 'position_source_io.dart' as impl;
import 'car_kit_trip_monitor.dart';

class PositionSourceFactory {
  static PositionSource create() => impl.PositionSourceImpl.create();
}
