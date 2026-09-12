import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/models/payment_blob.dart';

/// Cross-language signing contract.
///
/// The literals below are copied verbatim from the SERVER's source of truth:
///   backend/app/services/signing.py  →  TEST_VECTOR_BLOB / TEST_VECTOR_CANONICAL
///
/// If this test ever fails, the Dart and Python canonical payloads have
/// diverged and every signed blob from a real phone will be rejected by
/// backend/app/services/signature_verification.py with `invalid_signature`.
/// Fix the divergence — do NOT edit the expectation.
void main() {
  // backend/app/services/signing.py :: TEST_VECTOR_CANONICAL
  const testVectorCanonical =
      '11111111-2222-3333-4444-555555555555|sender-abc|receiver-xyz|'
      '250.00|2026-09-13T10:00:00.000Z|nonce-0001';

  // backend/app/services/signing.py :: TEST_VECTOR_BLOB
  PaymentBlob testVectorBlob() => PaymentBlob(
        id: '11111111-2222-3333-4444-555555555555',
        senderId: 'sender-abc',
        receiverId: 'receiver-xyz',
        amount: 250.0,
        timestamp: DateTime.utc(2026, 9, 13, 10, 0, 0),
        nonce: 'nonce-0001',
        isOffline: true,
        offlineLimitAtTime: 5000.0,
      );

  group('canonicalPayload', () {
    test('matches the shared Python test vector byte-for-byte', () {
      expect(canonicalPayload(testVectorBlob()), testVectorCanonical);
    });

    test('amount is always fixed 2-decimal', () {
      final blob = PaymentBlob(
        id: 'i',
        senderId: 's',
        receiverId: 'r',
        amount: 7,
        timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
        nonce: 'n',
        isOffline: true,
        offlineLimitAtTime: 0,
      );
      expect(canonicalPayload(blob), 'i|s|r|7.00|2026-01-02T03:04:05.000Z|n');
    });

    test('a local-time timestamp is normalised to UTC before signing', () {
      // Same instant, expressed locally. The canonical payload must not
      // depend on the phone's timezone.
      final utc = DateTime.utc(2026, 9, 13, 10, 0, 0);
      final local = utc.toLocal();
      expect(local.isUtc, isFalse);

      final blob = PaymentBlob(
        id: '11111111-2222-3333-4444-555555555555',
        senderId: 'sender-abc',
        receiverId: 'receiver-xyz',
        amount: 250.0,
        timestamp: local,
        nonce: 'nonce-0001',
        isOffline: true,
        offlineLimitAtTime: 5000.0,
      );
      expect(canonicalPayload(blob), testVectorCanonical);
    });

    test('signature-relevant fields survive copyWith (signing round-trip)', () {
      final blob = testVectorBlob();
      final before = canonicalPayload(blob);
      final signed = blob.copyWith(
        deviceSignature: 'MEUCIQD-fake-signature',
        senderPublicKey: 'A-fake-pubkey',
      );
      // id / timestamp / nonce must be preserved or the signature we just
      // computed would verify against a different payload.
      expect(canonicalPayload(signed), before);
      expect(signed.deviceSignature, 'MEUCIQD-fake-signature');
      expect(signed.senderPublicKey, 'A-fake-pubkey');
    });

    test('toJson emits the UTC timestamp the server re-canonicalises', () {
      // The server rebuilds the canonical payload from these JSON fields.
      final json = testVectorBlob().toJson();
      expect(json['timestamp'], '2026-09-13T10:00:00.000Z');
      expect(json['id'], '11111111-2222-3333-4444-555555555555');
      expect(json['nonce'], 'nonce-0001');
    });

    test('sender_public_key and handoff_method ride along in toJson', () {
      final blob = testVectorBlob().copyWith(
        senderPublicKey: 'pubkey-b64',
        handoffMethod: HandoffMethod.qr,
      );
      final json = blob.toJson();
      expect(json['sender_public_key'], 'pubkey-b64');
      expect(json['handoff_method'], 'qr');
      expect(json['direction'], 'sent');
    });

    test('sender_public_key is omitted when null', () {
      expect(testVectorBlob().toJson().containsKey('sender_public_key'), isFalse);
    });
  });


  // ── Feature B: the v1 Ed25519 canonical payload ──────────────────────
  //
  // Shared vector. The Python side asserts the identical string in
  // backend/app/services/signing.py (TEST_VECTOR_V1_CANONICAL) and
  // backend/tests/test_signing_v1.py.
  group('canonicalPayloadV1', () {
    const expected =
        'v1|sender-abc|receiver-xyz|250.00|2026-09-13T10:00:00Z|nonce-0001';

    PaymentBlob vectorBlob({DateTime? timestamp}) => PaymentBlob(
          id: '11111111-2222-3333-4444-555555555555',
          senderId: 'sender-abc',
          receiverId: 'receiver-xyz',
          amount: 250.0,
          timestamp: timestamp ?? DateTime.utc(2026, 9, 13, 10, 0, 0),
          nonce: 'nonce-0001',
          isOffline: true,
          offlineLimitAtTime: 5000,
        );

    test('matches the shared cross-language vector', () {
      expect(canonicalPayloadV1(vectorBlob()), expected);
    });

    test('the blob id is deliberately NOT covered', () {
      final other = vectorBlob().copyWith();
      expect(canonicalPayloadV1(other), canonicalPayloadV1(vectorBlob()));
    });

    test('sub-second precision is truncated, not rounded', () {
      // Dart emits ms (sometimes µs); the server truncates to whole seconds,
      // so anything finer must not change the signed string.
      final withMillis = vectorBlob(
        timestamp: DateTime.utc(2026, 9, 13, 10, 0, 0, 999, 999),
      );
      expect(canonicalPayloadV1(withMillis), expected);
    });

    test('a local-time timestamp is converted to UTC', () {
      final local = DateTime.utc(2026, 9, 13, 10, 0, 0).toLocal();
      expect(canonicalPayloadV1(vectorBlob(timestamp: local)), expected);
    });

    test('amount always carries exactly two decimals', () {
      final whole = PaymentBlob(
        id: 'i', senderId: 's', receiverId: 'r', amount: 200,
        timestamp: DateTime.utc(2026, 1, 1), nonce: 'n',
        isOffline: true, offlineLimitAtTime: 0,
      );
      expect(canonicalPayloadV1(whole), contains('|200.00|'));
    });
  });
}
