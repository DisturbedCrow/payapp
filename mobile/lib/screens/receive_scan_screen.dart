import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../models/payment_blob.dart';
import '../providers/auth_provider.dart';
import '../services/offline_queue_service.dart';
import '../services/qr_transfer.dart';
import '../services/security/device_key_service.dart';
import '../services/device_ed25519_service.dart';

/// Case 3b — RECEIVER side of the signed-blob QR handoff.
///
/// The sender's phone shows a QR containing the signed payment blob; this
/// screen scans it, verifies the signature offline, and parks the blob in the
/// local queue so it reaches the backend whenever either phone next gets
/// signal.
class ReceiveScanScreen extends StatefulWidget {
  const ReceiveScanScreen({super.key});

  @override
  State<ReceiveScanScreen> createState() => _ReceiveScanScreenState();
}

enum _ReceiveStage { scanning, accepted, duplicate, failed }

class _ReceiveScanScreenState extends State<ReceiveScanScreen> {
  MobileScannerController? _scannerCtrl;
  final _queueService = OfflineQueueService();
  final _deviceKeys = DeviceKeyService();

  _ReceiveStage _stage = _ReceiveStage.scanning;
  String? _message;
  PaymentBlob? _receivedBlob;

  /// Guards against mobile_scanner firing onDetect repeatedly while the
  /// async verify/persist work is still in flight.
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scannerCtrl?.dispose();
    super.dispose();
  }

  void _startScan() {
    _scannerCtrl?.dispose();
    _scannerCtrl = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
    setState(() {
      _stage = _ReceiveStage.scanning;
      _message = null;
      _receivedBlob = null;
      _handling = false;
    });
  }

  void _stopScan() {
    _scannerCtrl?.dispose();
    _scannerCtrl = null;
  }

  void _fail(String message) {
    _stopScan();
    if (!mounted) return;
    setState(() {
      _stage = _ReceiveStage.failed;
      _message = message;
      _handling = false;
    });
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    _handling = true;

    // 1. Decode + schema check (v == 1, t == 'spay.blob'). Returns null,
    //    never throws, for every other QR the camera might land on.
    final handoff = QrTransferService.decodeBlobHandoff(raw);
    if (handoff == null) {
      _fail(QrTransferService.explainNotHandoff(raw));
      return;
    }

    final blob = handoff.blob;

    // 2. Verify the signature locally — no network, no server.
    //
    // Offline, the receiver verifies the blob is internally consistent and
    // signed by the key it carries — self-attestation. Final truth is
    // established at sync, when the backend verifies the signature against
    // the sender's registered key and checks limits/dedup. The receiver's
    // offline view is provisional by design; the AI credit limit caps
    // systemic exposure.
    // Each scheme signs a different canonical string, so the QR says which
    // one it used and we verify against the matching pair. Getting this wrong
    // would reject every genuine payment.
    final bool signatureValid;
    if (handoff.alg == SignatureAlg.ed25519) {
      signatureValid = await DeviceEd25519Service().verify(
        canonicalPayloadV1(blob),
        handoff.signature,
        handoff.senderPublicKey,
      );
    } else {
      signatureValid = _deviceKeys.verifySignatureBase64(
        canonicalPayload(blob),
        handoff.signature,
        handoff.senderPublicKey,
      );
    }
    if (!signatureValid) {
      _fail(
        'Signature check failed.\n'
        'This payment was not signed by the device that is showing it — '
        'do not accept it.',
      );
      return;
    }

    // 3. Is this payment even addressed to me?
    if (!mounted) return;
    final myUserId = context.read<AuthProvider>().user?.id ?? '';
    if (myUserId.isEmpty) {
      _fail('You are signed out. Sign in before receiving a payment.');
      return;
    }
    if (blob.receiverId != myUserId) {
      _fail(
        'This payment is addressed to a different account.\n'
        'Ask the sender to scan your QR and pay again.',
      );
      return;
    }

    // 4. Local dedup — the same QR scanned twice is not two payments.
    final existing = await _queueService.findByNonce(blob.nonce);
    if (existing != null) {
      _stopScan();
      if (!mounted) return;
      setState(() {
        _stage = _ReceiveStage.duplicate;
        _receivedBlob = existing;
        _message = 'Already received — ₹${existing.amount.toStringAsFixed(2)} '
            'from this QR is already in your queue.';
        _handling = false;
      });
      return;
    }

    // 5. Persist. Marked as RECEIVED so the limit/risk arithmetic on this
    //    device (which only ever deducted for money it sent) leaves it alone.
    // Keep the signature in the field that matches its scheme, so the copy we
    // upload verifies server-side exactly as the sender's own copy would.
    // copyWith treats null as "leave unchanged", so build the scheme-specific
    // overrides explicitly rather than passing nulls.
    final isEd25519 = handoff.alg == SignatureAlg.ed25519;
    final toStore = isEd25519
        ? blob.copyWith(
            status: BlobStatus.pendingSync,
            direction: BlobDirection.received,
            handoffMethod: HandoffMethod.qr,
            deviceSignatureEd25519: handoff.signature,
            senderEd25519Pk: handoff.senderPublicKey,
          )
        : blob.copyWith(
            status: BlobStatus.pendingSync,
            direction: BlobDirection.received,
            handoffMethod: HandoffMethod.qr,
            deviceSignature: handoff.signature,
            senderPublicKey: handoff.senderPublicKey,
          );
    try {
      await _queueService.enqueue(toStore);
    } catch (e) {
      _fail('Could not save the payment locally: $e');
      return;
    }

    _stopScan();
    if (!mounted) return;
    setState(() {
      _stage = _ReceiveStage.accepted;
      _receivedBlob = toStore;
      _message = null;
      _handling = false;
    });
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surfaceColor,
      appBar: AppBar(
        title: const Text('Receive (scan)'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: switch (_stage) {
            _ReceiveStage.scanning => _buildScanning(),
            _ReceiveStage.accepted => _buildAccepted(),
            _ReceiveStage.duplicate => _buildDuplicate(),
            _ReceiveStage.failed => _buildFailed(),
          },
        ),
      ),
    );
  }

  Widget _buildScanning() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.qr_code_scanner,
                      color: AppTheme.primaryColor, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Scan the sender\'s payment QR',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.offlineColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Offline',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.offlineColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 300,
                  child: _scannerCtrl != null
                      ? MobileScanner(
                          controller: _scannerCtrl!,
                          onDetect: _onDetect,
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'The signature is checked on this phone. No internet needed.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAccepted() {
    final blob = _receivedBlob!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.verified, color: AppTheme.successColor, size: 72),
        const SizedBox(height: 16),
        Text(
          '₹${blob.amount.toStringAsFixed(2)} received (offline)',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: AppTheme.primaryColor,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Signature verified on this device.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.black54),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.warningColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: AppTheme.warningColor.withValues(alpha: 0.35)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.schedule, size: 18, color: AppTheme.warningColor),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'pending settlement — the money moves when either phone is '
                  'back online and the bank confirms it.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF8A5300),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _detailCard(blob),
        const SizedBox(height: 24),
        _primaryButton('Scan another', _startScan),
        const SizedBox(height: 10),
        _secondaryButton('Done', () => Navigator.of(context).pop()),
      ],
    );
  }

  Widget _buildDuplicate() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.done_all, color: AppTheme.primaryColor, size: 64),
        const SizedBox(height: 16),
        const Text(
          'Already received',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppTheme.primaryColor,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _message ?? 'This payment is already in your queue.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        const Text(
          'pending settlement',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.warningColor,
          ),
        ),
        const SizedBox(height: 24),
        _primaryButton('Scan another', _startScan),
        const SizedBox(height: 10),
        _secondaryButton('Done', () => Navigator.of(context).pop()),
      ],
    );
  }

  Widget _buildFailed() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.gpp_bad, color: AppTheme.errorColor, size: 64),
        const SizedBox(height: 16),
        const Text(
          'Payment not accepted',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppTheme.errorColor,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _message ?? 'Could not read that QR.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 24),
        _primaryButton('Try again', _startScan),
        const SizedBox(height: 10),
        _secondaryButton('Cancel', () => Navigator.of(context).pop()),
      ],
    );
  }

  Widget _detailCard(PaymentBlob blob) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          _detailRow('Amount', '₹${blob.amount.toStringAsFixed(2)}'),
          _detailRow('Received via', 'QR handoff (offline)'),
          _detailRow('Payment ID',
              blob.id.length > 8 ? '${blob.id.substring(0, 8)}…' : blob.id),
          _detailRow('Status', 'Pending settlement'),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 13, color: Colors.black54)),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppTheme.primaryColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback onTap) {
    return SizedBox(
      height: 50,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primaryColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _secondaryButton(String label, VoidCallback onTap) {
    return SizedBox(
      height: 48,
      child: TextButton(
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppTheme.primaryColor,
          ),
        ),
      ),
    );
  }
}
