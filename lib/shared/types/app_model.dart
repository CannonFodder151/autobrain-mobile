/// Shared data models for the AutoBrain frontend.
///
/// Cross-feature types live here so feature modules never need to import from
/// each other (AUT-3814).
library;

import 'package:flutter/foundation.dart';

/// Base class for all shared domain models.
@immutable
abstract class AppModel {
  const AppModel();
}
