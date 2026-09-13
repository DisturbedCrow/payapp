import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The ONE secure-storage configuration for the whole app.
///
/// flutter_secure_storage 9.x re-initialises on every call, and any call made
/// with `encryptedSharedPreferences: true` MOVES every plain-mode entry into
/// EncryptedSharedPreferences and deletes the original. With mixed options the
/// security services (encrypted) silently migrated `auth_token` away from
/// ApiService (plain), so every cold start — including one in airplane mode —
/// landed on the login screen. The token only survived within a session
/// because ApiService caches it in memory.
///
/// Always use this constant; never construct FlutterSecureStorage elsewhere
/// (test/secure_storage_consistency_test.dart enforces it).
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
);
