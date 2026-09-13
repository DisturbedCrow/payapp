import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/services/qr_transfer.dart';

void main() {
  group('QrTransferService.explainNotHandoff', () {
    test("names the person when a receive QR is scanned by mistake", () {
      final raw = QrTransferService.generateReceiveQR(
        receiverId: 'u-jyati',
        receiverName: 'Jyati Kirana',
      );
      // The receive QR is exactly what the hand-off decoder must refuse.
      expect(QrTransferService.decodeBlobHandoff(raw), isNull);

      final hint = QrTransferService.explainNotHandoff(raw);
      expect(hint, contains("Jyati Kirana's QR for receiving money"));
      expect(hint, contains('Pay screen'));
    });

    test('keeps the generic message for any other QR', () {
      final hint = QrTransferService.explainNotHandoff('https://example.com');
      expect(hint, startsWith('That QR is not a SetuPay payment.'));
    });
  });
}
