// Registration of the Ed25519 trust root must survive a backend that lost its
// database (Render free tier: an instance that slept wakes up reseeded). The
// local "already registered" marker is not enough on its own — these tests pin
// that the phone re-checks the server and re-registers when the key is gone.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/services/device_ed25519_service.dart';

const _userId = 'a7996138-97cf-5b93-a039-eb2ed11e7f3c';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String pk;
  late Map<String, String> storage;
  late List<String> calls;

  setUpAll(() async {
    final pair = await Ed25519().newKeyPair();
    final sk = base64Encode(await pair.extractPrivateKeyBytes());
    pk = base64Encode((await pair.extractPublicKey()).bytes);
    storage = {
      'device_ed25519_sk': sk,
      'device_ed25519_pk': pk,
      // Registered on an earlier launch, against the database that is gone.
      'device_ed25519_registered_for': '$_userId:',
    };
    DeviceEd25519Service.storageOverride = () async => storage;
    DeviceEd25519Service.persistOverride = (_, __) async {};
  });

  setUp(() {
    calls = [];
    storage['device_ed25519_registered_for'] = '$_userId:$pk';
  });

  tearDownAll(() {
    DeviceEd25519Service.storageOverride = null;
    DeviceEd25519Service.persistOverride = null;
    DeviceEd25519Service.apiOverride = null;
  });

  test('marker set and server still holds the key: no re-registration',
      () async {
    DeviceEd25519Service.apiOverride = (endpoint, body) async {
      calls.add(body == null ? 'GET' : 'POST');
      return {'registered': true, 'public_key_b64': pk};
    };

    expect(await DeviceEd25519Service().registerWithBackend(_userId), isTrue);
    expect(calls, ['GET']);
  });

  test('marker set but backend was reseeded: re-registers the same key',
      () async {
    DeviceEd25519Service.apiOverride = (endpoint, body) async {
      calls.add(body == null ? 'GET' : 'POST');
      expect(endpoint, '/api/auth/device-key');
      if (body == null) return {'registered': false, 'public_key_b64': null};
      expect(body['public_key_b64'], pk);
      return {'status': 'registered', 'public_key_b64': pk};
    };

    expect(await DeviceEd25519Service().registerWithBackend(_userId), isTrue);
    expect(calls, ['GET', 'POST']);
  });

  test('server holds a different key: re-registers this one', () async {
    DeviceEd25519Service.apiOverride = (endpoint, body) async {
      calls.add(body == null ? 'GET' : 'POST');
      if (body == null) {
        return {'registered': true, 'public_key_b64': 'c29tZW9uZSBlbHNl'};
      }
      return {'status': 'rotated', 'public_key_b64': pk};
    };

    expect(await DeviceEd25519Service().registerWithBackend(_userId), isTrue);
    expect(calls, ['GET', 'POST']);
  });

  test('offline: returns false without throwing, and does not POST', () async {
    DeviceEd25519Service.apiOverride = (endpoint, body) async {
      calls.add(body == null ? 'GET' : 'POST');
      throw Exception('Could not reach SetuPay');
    };

    expect(await DeviceEd25519Service().registerWithBackend(_userId), isFalse);
    expect(calls, ['GET']);
  });

  test('never registered: POSTs straight away', () async {
    storage['device_ed25519_registered_for'] = '';
    DeviceEd25519Service.apiOverride = (endpoint, body) async {
      calls.add(body == null ? 'GET' : 'POST');
      return {'status': 'registered', 'public_key_b64': pk};
    };

    expect(await DeviceEd25519Service().registerWithBackend(_userId), isTrue);
    expect(calls, ['POST']);
  });
}
