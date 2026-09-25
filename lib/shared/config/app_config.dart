/// Shared app configuration.
///
/// Thin re-export of `core/config.dart` so feature modules depend on the shared
/// package instead of reaching into `core/` directly (AUT-3814).
library;

export 'package:autobrain/core/config.dart';
