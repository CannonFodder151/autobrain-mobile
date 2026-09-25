/// Shared service layer for the AutoBrain frontend.
///
/// Cross-feature services (API client, offline cache, auth) live here so
/// feature modules never need to import from each other (AUT-3814).
library;

export 'package:autobrain/core/api_client.dart';
export 'package:autobrain/core/auth_state.dart';
export 'package:autobrain/core/offline_cache.dart';
export 'package:autobrain/core/connectivity_service.dart';
export 'package:autobrain/core/token_store.dart';
