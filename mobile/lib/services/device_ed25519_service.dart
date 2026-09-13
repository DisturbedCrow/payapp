import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_service.dart';

/// Feature B — the device's Ed25519 signing key.
///
/// This is the trust root for offline payments: the backend verifies every
/// blob's signature against the public key registered here, so a blob can only
/// have come from this handset. It sits alongside the older ECDSA P-256
/// `DeviceKeyService` in `services/security/`, which still signs the legacy
/// field and drives the BLE session handshake — the two are independent, and
/// the backend prefers Ed25519 whenever a blob carries it.
///
/// Named `DeviceEd25519Service` rather than the spec's `DeviceKeyService`
/// purely to avoid two same-named classes in one project; every method the
/// spec asks for is here under the specified name.
class DeviceEd25519Service {
  static final DeviceEd25519Service _instance =
      DeviceEd25519Service._internal();
  factory DeviceEd25519Service() => _instance;
  DeviceEd25519Service._internal();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Storage keys are exactly as the spec names them.
  static const String _skKey = 'device_ed25519_sk';
  static const String _pkKey = 'device_ed25519_pk';
  static const String _registeredKey = 'device_ed25519_registered_for';

  static final Ed25519 _algorithm = Ed25519();

  SimpleKeyPair? _cached;
  String? _cachedPublicKeyB64;

  /// Test seam: lets unit tests exercise signing without secure storage.
  @visibleForTesting
  static Future<Map<String, String>> Function()? storageOverride;

  @visibleForTesting
  static Future<void> Function(String sk, String pk)? persistOverride;

  /// Test seam for the two backend calls. A null [body] means GET.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
    String endpoint,
    Map<String, dynamic>? body,
  )? apiOverride;

  // ── Public API ────────────────────────────────────────────────

  /// Generate the keypair on first call; idempotent afterwards.
  Future<void> ensureKeypair() async {
    if (_cached != null) return;

    final stored = await _read();
    final sk = stored[_skKey];
    final pk = stored[_pkKey];
    if (sk != null && sk.isNotEmpty && pk != null && pk.isNotEmpty) {
      _cached = SimpleKeyPairData(
        base64Decode(sk),
        publicKey: SimplePublicKey(base64Decode(pk), type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
      _cachedPublicKeyB64 = pk;
      return;
    }

    final pair = await _algorithm.newKeyPair();
    final privateBytes = await pair.extractPrivateKeyBytes();
    final publicKey = await pair.extractPublicKey();
    final skB64 = base64Encode(privateBytes);
    final pkB64 = base64Encode(publicKey.bytes);

    await _persist(skB64, pkB64);
    _cached = pair;
    _cachedPublicKeyB64 = pkB64;
  }

  /// Base64 of the 32-byte raw public key, for registration with the backend.
  Future<String> publicKeyB64() async {
    await ensureKeypair();
    return _cachedPublicKeyB64 ?? '';
  }

  /// Base64 of the 64-byte detached signature over [canonicalPayload].
  Future<String> sign(String canonicalPayload) async {
    await ensureKeypair();
    final pair = _cached;
    if (pair == null) {
      throw StateError('Ed25519 keypair unavailable');
    }
    final signature = await _algorithm.sign(
      utf8.encode(canonicalPayload),
      keyPair: pair,
    );
    return base64Encode(signature.bytes);
  }

  /// Verify a signature offline — used by the QR receiver (Case 3b) to check
  /// a blob against the public key the QR carries, with no network.
  Future<bool> verify(
    String canonicalPayload,
    String signatureB64,
    String publicKeyB64_,
  ) async {
    try {
      return await _algorithm.verify(
        utf8.encode(canonicalPayload),
        signature: Signature(
          base64Decode(signatureB64),
          publicKey: SimplePublicKey(
            base64Decode(publicKeyB64_),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Register the public key with the backend. Fire-and-forget: returns false
  /// when offline so the caller can retry on the next sync, and never throws.
  ///
  /// Re-registers whenever the logged-in user changes or the stored key
  /// changes, so a reseeded backend or a fresh install self-heals instead of
  /// silently signing blobs the server cannot verify.
  Future<bool> registerWithBackend(String userId) async {
    try {
      await ensureKeypair();
      final pk = await publicKeyB64();
      if (pk.isEmpty) return false;

      // The local marker alone is not proof: a free-tier backend that slept
      // comes back with a fresh, reseeded database — same user id, no key —
      // and every blob this phone signs would then be refused as
      // `unsigned_device`. So confirm the server still holds this exact key.
      // Offline, the GET throws and we fall through to `false`.
      final stored = await _read();
      if (stored[_registeredKey] == '$userId:$pk') {
        final held = await _call('/api/auth/device-key', null);
        if (held['registered'] == true && held['public_key_b64'] == pk) {
          return true;
        }
      }

      final response =
          await _call('/api/auth/device-key', {'public_key_b64': pk});
      final status = response['status'];
      if (status == 'registered' || status == 'rotated') {
        await _remember('$userId:$pk');
        return true;
      }
      return false;
    } catch (_) {
      return false; // offline — the sync engine retries
    }
  }

  /// Drop the "already registered" marker so the next attempt re-registers.
  Future<void> invalidateRegistration() async {
    try {
      await _storage.delete(key: _registeredKey);
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _call(
    String endpoint,
    Map<String, dynamic>? body,
  ) {
    final override = apiOverride;
    if (override != null) return override(endpoint, body);
    return body == null
        ? ApiService().get(endpoint)
        : ApiService().post(endpoint, body);
  }

  // ── Storage ───────────────────────────────────────────────────

  Future<Map<String, String>> _read() async {
    final override = storageOverride;
    if (override != null) return override();
    try {
      return {
        _skKey: await _storage.read(key: _skKey) ?? '',
        _pkKey: await _storage.read(key: _pkKey) ?? '',
        _registeredKey: await _storage.read(key: _registeredKey) ?? '',
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _persist(String sk, String pk) async {
    final override = persistOverride;
    if (override != null) return override(sk, pk);
    try {
      await _storage.write(key: _skKey, value: sk);
      await _storage.write(key: _pkKey, value: pk);
    } catch (_) {
      // In-memory key still works for this session; the next launch regenerates.
    }
  }

  Future<void> _remember(String marker) async {
    try {
      await _storage.write(key: _registeredKey, value: marker);
    } catch (_) {}
  }
}
