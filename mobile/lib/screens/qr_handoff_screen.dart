import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config/theme.dart';
import '../models/payment_blob.dart';
import '../services/qr_transfer.dart';

/// Case 3b — SENDER side of the signed-blob QR handoff.
///
/// Both phones are offline. The sender has already signed the blob with its
/// device key and deducted its own offline limit; this screen simply puts the
/// signed blob on the glass so the receiver's camera can take it. Nothing
/// here touches the network.
///
/// NOTE ON BRIGHTNESS: forcing the screen to maximum brightness needs a
/// platform plugin (e.g. `screen_brightness`), which is not a dependency of
/// this app. The next best thing for camera contrast is a pure-white
/// scaffold behind a pure-black-on-white QR — which is what this screen
/// does. If a demo phone is set very dim, raise the brightness by hand
/// before scanning.
class QrHandoffScreen extends StatelessWidget {
  final PaymentBlob blob;
  final String signature;
  final String senderPublicKey;
  final String alg;

  const QrHandoffScreen({
    super.key,
    required this.blob,
    required this.signature,
    required this.senderPublicKey,
    this.alg = SignatureAlg.ecdsaP256,
  });

  @override
  Widget build(BuildContext context) {
    final payload = QrTransferService.encodeBlobHandoff(
      blob: blob,
      signature: signature,
      senderPublicKey: senderPublicKey,
      alg: alg,
    );

    final media = MediaQuery.of(context);
    // As wide as the screen allows, but never taller than the space we have.
    // 56 = 16px page padding + 12px quiet-zone padding, on each side. The
    // payload is ~650 chars (QR version ~18, 89x89 modules), so every pixel
    // of module size counts for a phone-to-phone scan.
    final qrSize = (media.size.width - 56)
        .clamp(200.0, media.size.height * 0.55)
        .toDouble();

    return Scaffold(
      // Pure white, not the app's tinted surface: every extra bit of
      // contrast helps the other phone's camera lock on.
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: AppTheme.primaryColor,
        title: const Text('Hand off payment'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ask receiver to scan • ₹${blob.amount.toStringAsFixed(0)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.primaryColor,
                ),
              ),
              const SizedBox(height: 20),

              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrImageView(
                    data: payload,
                    version: QrVersions.auto,
                    // The Container above already supplies the quiet zone;
                    // QrImageView's default 10px padding would only shrink
                    // the modules.
                    padding: EdgeInsets.zero,
                    // M tolerates ~15% damage — the sweet spot between
                    // module density (scan distance) and robustness to a
                    // fingerprint or a glare patch on the sender's screen.
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    size: qrSize,
                    backgroundColor: Colors.white,
                    // Plain black square modules on purpose: styled eyes and
                    // circular modules look nicer but scan measurably worse
                    // phone-to-phone.
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              const Text(
                'Works fully offline — the receiver verifies the signature '
                'on their phone.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 12),

              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.lightBlue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 14, color: AppTheme.primaryColor),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Signed on this device · ${_shortId(blob.id)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Done',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _shortId(String id) =>
      id.length <= 8 ? id : '${id.substring(0, 8)}…';
}
