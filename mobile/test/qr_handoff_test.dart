import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/models/payment_blob.dart';
import 'package:offline_pay/services/qr_transfer.dart';

/// Case 3b — the signed blob travels sender → receiver inside a QR code.
/// The receiver must be able to rebuild the EXACT canonical payload the
/// sender signed, or offline verification is impossible.
void main() {
  const fakeSig = 'MEUCIQCfakefakefakefakefakefakefakefakefakefakefakefake==';
  const fakeSpk = 'AqZ2fakefakefakefakefakefakefakefakefakefakeQ=';

  PaymentBlob sampleBlob() => PaymentBlob(
        id: '11111111-2222-3333-4444-555555555555',
        senderId: 'a7f6c445-d25b-5ae0-b382-e2a6144d9549',
        receiverId: 'f30ca7a5-cc00-5efb-a792-e136e834a7aa',
        amount: 1234.5,
        timestamp: DateTime.utc(2026, 9, 13, 10, 30, 15, 250),
        nonce: 'nonce-abcdef-0001',
        deviceSignature: fakeSig,
        isOffline: true,
        offlineLimitAtTime: 5000.0,
        senderPublicKey: fakeSpk,
      );

  String encodeSample() => QrTransferService.encodeBlobHandoff(
        blob: sampleBlob(),
        signature: fakeSig,
        senderPublicKey: fakeSpk,
      );

  group('encodeBlobHandoff / decodeBlobHandoff round-trip', () {
    test('every field survives the round-trip', () {
      final original = sampleBlob();
      final decoded = QrTransferService.decodeBlobHandoff(encodeSample());

      expect(decoded, isNotNull);
      final blob = decoded!.blob;

      expect(blob.id, original.id);
      expect(blob.senderId, original.senderId);
      expect(blob.receiverId, original.receiverId);
      expect(blob.amount, original.amount);
      expect(blob.nonce, original.nonce);
      expect(blob.isOffline, original.isOffline);
      expect(blob.offlineLimitAtTime, original.offlineLimitAtTime);
      expect(blob.timestamp.toUtc(), original.timestamp.toUtc());
      expect(blob.timestamp.isAtSameMomentAs(original.timestamp), isTrue);

      expect(decoded.signature, fakeSig);
      expect(decoded.senderPublicKey, fakeSpk);
      expect(blob.deviceSignature, fakeSig);
      expect(blob.senderPublicKey, fakeSpk);
      expect(blob.handoffMethod, HandoffMethod.qr);
    });

    test('the canonical payload is byte-identical after the round-trip', () {
      // This is the whole point: the receiver verifies the signature over
      // the canonical payload it rebuilds from the QR.
      final original = sampleBlob();
      final decoded = QrTransferService.decodeBlobHandoff(encodeSample());
      expect(canonicalPayload(decoded!.blob), canonicalPayload(original));
    });

    test('a local-timezone timestamp still round-trips to the same instant', () {
      final blob = PaymentBlob(
        id: 'id-1',
        senderId: 's-1',
        receiverId: 'r-1',
        amount: 99.99,
        timestamp: DateTime.utc(2026, 9, 13, 10, 0, 0).toLocal(),
        nonce: 'n-1',
        isOffline: true,
        offlineLimitAtTime: 100,
      );
      final encoded = QrTransferService.encodeBlobHandoff(
        blob: blob,
        signature: fakeSig,
        senderPublicKey: fakeSpk,
      );
      final decoded = QrTransferService.decodeBlobHandoff(encoded);
      expect(decoded, isNotNull);
      expect(canonicalPayload(decoded!.blob), canonicalPayload(blob));
    });

    test('payload stays comfortably under the ~1200 char QR budget', () {
      expect(encodeSample().length, lessThan(1200));
    });

    test('encoded payload is base64url — no JSON braces, no +/ chars', () {
      final encoded = encodeSample();
      expect(encoded.contains('{'), isFalse);
      expect(encoded.contains('+'), isFalse);
      expect(encoded.contains('/'), isFalse);
    });
  });

  group('decodeBlobHandoff rejects non-handoff input (never throws)', () {
    test('(a) garbage', () {
      expect(QrTransferService.decodeBlobHandoff('garbage'), isNull);
      expect(QrTransferService.decodeBlobHandoff('hello world !!'), isNull);
      expect(QrTransferService.decodeBlobHandoff(''), isNull);
      expect(QrTransferService.decodeBlobHandoff('   '), isNull);
      expect(
        QrTransferService.decodeBlobHandoff('https://example.com/pay?x=1'),
        isNull,
      );
    });

    test('(b) an existing receive_payment QR', () {
      final receiveQr = QrTransferService.generateReceiveQR(
        receiverId: 'f30ca7a5-cc00-5efb-a792-e136e834a7aa',
        receiverName: 'Ramesh Kirana',
        bleUuid: '0000abcd-0000-1000-8000-00805f9b34fb',
      );
      expect(QrTransferService.decodeBlobHandoff(receiveQr), isNull);
      // ...and the reverse: the receive parser must not swallow a handoff QR.
      expect(QrTransferService.parseReceiveQR(encodeSample()), isNull);
    });

    test('(c) truncated base64', () {
      final encoded = encodeSample();
      for (final cut in [4, 20, encoded.length ~/ 2, encoded.length - 3]) {
        expect(
          QrTransferService.decodeBlobHandoff(encoded.substring(0, cut)),
          isNull,
          reason: 'truncated at $cut should not decode',
        );
      }
    });

    test('valid base64url JSON but the wrong type or version', () {
      String b64(Map<String, dynamic> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m)));

      final good = {
        'v': 1,
        't': 'spay.blob',
        'blob': {
          'id': 'i',
          'sender_id': 's',
          'receiver_id': 'r',
          'amount': 10,
          'timestamp': '2026-09-13T10:00:00.000Z',
          'nonce': 'n',
          'is_offline': true,
          'offline_limit_at_time': 100,
        },
        'sig': fakeSig,
        'spk': fakeSpk,
      };
      // Sanity: the control payload does decode.
      expect(QrTransferService.decodeBlobHandoff(b64(good)), isNotNull);

      expect(
        QrTransferService.decodeBlobHandoff(b64({...good, 't': 'spay.other'})),
        isNull,
      );
      expect(QrTransferService.decodeBlobHandoff(b64({...good, 'v': 2})), isNull);
      expect(
        QrTransferService.decodeBlobHandoff(b64({...good, 'sig': ''})),
        isNull,
      );
      expect(
        QrTransferService.decodeBlobHandoff(b64({...good, 'spk': ''})),
        isNull,
      );
      expect(
        QrTransferService.decodeBlobHandoff(
            b64({...good, 'blob': 'not-a-map'})),
        isNull,
      );
      expect(
        QrTransferService.decodeBlobHandoff(b64({
          ...good,
          'blob': {...(good['blob'] as Map), 'amount': 0},
        })),
        isNull,
      );
      expect(
        QrTransferService.decodeBlobHandoff(b64({
          ...good,
          'blob': {...(good['blob'] as Map), 'timestamp': 'not-a-date'},
        })),
        isNull,
      );
      expect(
        QrTransferService.decodeBlobHandoff(b64({
          ...good,
          'blob': {...(good['blob'] as Map), 'receiver_id': ''},
        })),
        isNull,
      );
      // base64url of a JSON array, and of plain non-JSON text
      expect(
        QrTransferService.decodeBlobHandoff(
            base64Url.encode(utf8.encode('[1,2,3]'))),
        isNull,
      );
      expect(
        QrTransferService.decodeBlobHandoff(
            base64Url.encode(utf8.encode('just some text'))),
        isNull,
      );
    });
  });
}
