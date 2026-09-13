import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../secure_storage.dart';
import '../api_service.dart';
import 'device_key_service.dart';
import 'device_integrity_service.dart';

/// Registers the device's ECDSA public key with the backend,
/// creating a device binding that enables signed offline transactions.
///
/// Called once after key generation and on each app startup to ensure
/// the binding is current.
class DeviceRegistrationService {
  static final DeviceRegistrationService _instance =
      DeviceRegistrationService._internal();
  factory DeviceRegistrationService() => _instance;
  DeviceRegistrationService._internal();

  final _deviceKeys = DeviceKeyService();
  final _integrity = DeviceIntegrityService();
  final _api = ApiService();
  static const FlutterSecureStorage _storage = appSecureStorage;
  static const String _registeredKey = 'device_registered';

  /// Ensure device is registered with backend. Idempotent.
  ///
  /// The local `device_registered` flag alone is not enough: the server can
  /// legitimately forget us (database reseeded between demo rehearsals, the
  /// binding revoked, or evicted by the 2-device cap). If the phone trusted
  /// the local flag it would never re-register, and with
  /// SIGNATURE_ENFORCEMENT=enforce every blob it signs would be rejected as
  /// `unsigned_device`. So when we are online we confirm with the server and
  /// re-register if our key is missing.
  Future<bool> ensureRegistered() async {
    try {
      final isGenerated = await _deviceKeys.isKeyGenerated;
      if (!isGenerated) {
        // Force key generation
        await _deviceKeys.getPublicKeyBase64();
      }

      final alreadyRegistered = await _storage.read(key: _registeredKey);
      if (alreadyRegistered != 'true') {
        return await registerDevice();
      }

      // Believed-registered: verify the server agrees. Offline, we keep
      // trusting the local flag — nothing else we can do, and the blob is
      // still signed and will verify once the key is known.
      final serverKnowsUs = await _serverHasOurDevice();
      if (serverKnowsUs == false) {
        debugPrint('Device binding missing server-side — re-registering.');
        await _storage.delete(key: _registeredKey);
        return await registerDevice();
      }
      return true;
    } catch (e) {
      debugPrint('Device registration check failed: $e');
      return false;
    }
  }

  /// true / false when we could reach the server, null when offline.
  Future<bool?> _serverHasOurDevice() async {
    final deviceId = _deviceKeys.deviceId;
    if (deviceId == null) return false;
    try {
      final response = await _api.get('/api/device/list');
      final devices = (response['devices'] as List?) ?? const [];
      return devices.any((d) =>
          d is Map && d['device_id'] == deviceId && d['is_active'] == true);
    } catch (_) {
      return null; // offline or server down — do not churn the binding
    }
  }

  /// Register this device with the backend.
  Future<bool> registerDevice() async {
    try {
      final pubKeyBase64 = await _deviceKeys.getPublicKeyBase64();
      final pubKeyPem = await _deviceKeys.getPublicKeyPem();
      final deviceId = _deviceKeys.deviceId;

      if (pubKeyBase64 == null || deviceId == null) return false;

      // Run integrity check
      final integrityResult = await _integrity.checkIntegrity();

      String platform = 'unknown';
      String osVersion = '';
      if (!kIsWeb) {
        platform = Platform.isAndroid ? 'android' : Platform.isIOS ? 'ios' : 'other';
        osVersion = Platform.operatingSystemVersion;
      }

      final response = await _api.post('/api/device/register', {
        'device_id': deviceId,
        'public_key_pem': pubKeyPem ?? '',
        'public_key_base64': pubKeyBase64,
        'platform': platform,
        'os_version': osVersion,
        'integrity_score': integrityResult.isSecure ? 1.0 : integrityResult.riskScore,
      });

      if (response['status'] == 'bound' || response['status'] == 'updated') {
        await _storage.write(key: _registeredKey, value: 'true');
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('Device registration failed: $e');
      return false;
    }
  }

  /// Force re-registration (e.g., after key rotation).
  Future<bool> forceReRegister() async {
    await _storage.delete(key: _registeredKey);
    return registerDevice();
  }

  /// Check if device is registered.
  Future<bool> get isRegistered async {
    final val = await _storage.read(key: _registeredKey);
    return val == 'true';
  }
}
