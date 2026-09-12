import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../providers/auth_provider.dart';
import '../../providers/wallet_provider.dart';
import '../../providers/transaction_provider.dart';
import '../../models/transaction.dart';
import '../../models/payment_blob.dart';
import '../../services/qr_transfer.dart';
import '../../services/offline_limit_service.dart';
import '../../services/offline_queue_service.dart';
import '../../services/connectivity_service.dart';
import '../../services/api_service.dart';
import '../../services/ble_service.dart';
import '../../services/voice_intent_parser.dart';
import '../../services/voice_intent_remote.dart';
import '../../services/voice_service.dart';
import '../../services/security/device_key_service.dart';
import '../../services/device_ed25519_service.dart';
import '../../config/constants.dart';
import '../../config/theme.dart';
import '../payment_receipt_screen.dart';
import 'voice_confirm_screen.dart';
import 'voice_pay_sheet.dart';
import '../qr_handoff_screen.dart';

class PayScreen extends StatefulWidget {
  const PayScreen({super.key});

  /// Set by the dashboard's mic FAB just before it switches to the Pay tab,
  /// so voice capture opens immediately instead of making the presenter tap
  /// twice on stage. Consumed (and cleared) once by [_PayScreenState].
  static bool autoStartVoice = false;

  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  final _amountCtrl = TextEditingController();
  final _scanAmountCtrl = TextEditingController();

  String? _qrData;
  bool _isProcessing = false;
  String? _error;

  MobileScannerController? _scannerCtrl;
  bool _isScanning = false;
  bool _isBLETransferring = false;
  ReceiverQRData? _scannedReceiver;

  final _limitService = OfflineLimitService();
  final _queueService = OfflineQueueService();
  final _connectivityService = ConnectivityService();
  final _bleService = BLEService();

  @override
  void initState() {
    super.initState();
    if (AppConstants.voicePayEnabled && PayScreen.autoStartVoice) {
      PayScreen.autoStartVoice = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => startVoicePay());
    }
  }

  // ── Voice payments (Feature G) ───────────────────────────────
  //
  // Voice is an INPUT LAYER on top of the existing flow: it only ever fills in
  // (receiver, amount) and then calls the same _processOfflinePayment /
  // _processOnlinePayment the manual path uses. There is deliberately no
  // parallel payment path to keep the demo and the audit surface honest.

  /// Mic → listen → parse → resolve → confirm → the existing pay flow.
  Future<void> startVoicePay() async {
    if (!AppConstants.voicePayEnabled) return;

    final localIntent = await showVoicePaySheet(context);
    if (!mounted || localIntent == null) return; // cancelled, or "Type instead"

    // LLM garnish (spec G6): only when the deterministic parser was unsure
    // AND we are online. Returns null on any timeout, error or offline, so
    // the airplane-mode demo path never depends on it.
    final intent = await VoiceIntentRemote.refine(localIntent) ?? localIntent;
    if (!mounted) return;

    final recent = await VoiceService().loadRecentPayees();
    final matches = intent.recipientQuery == null
        ? const <ResolvedRecipient>[]
        : resolveRecipient(intent.recipientQuery!, recent: recent);
    final limit = await _limitService.getAvailableLimit();
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => VoiceConfirmScreen(
          intent: intent,
          matches: matches,
          availableLimit: limit,
          recentPayees: recent
              .map((p) => ResolvedRecipient(id: p.id, name: p.name, score: 0))
              .toList(),
          onConfirm: (recipient, amount) {
            Navigator.of(ctx).pop();
            _payResolvedRecipient(recipient, amount);
          },
          onRerecord: () {
            Navigator.of(ctx).pop();
            startVoicePay();
          },
          onEdit: (amount, recipientQuery) {
            Navigator.of(ctx).pop();
            // Drop the user into the normal flow with what we understood.
            if (amount != null) _scanAmountCtrl.text = amount.toStringAsFixed(0);
            setState(() => _error =
                'Scan the receiver\'s QR to finish paying'
                '${recipientQuery != null ? ' $recipientQuery' : ''}.');
          },
        ),
      ),
    );
  }

  /// Hands a voice-resolved payee to the SAME code path the QR scanner uses.
  Future<void> _payResolvedRecipient(
    ResolvedRecipient recipient,
    double amount,
  ) async {
    final receiver = ReceiverQRData(
      receiverId: recipient.id,
      receiverName: recipient.name,
    );
    _scanAmountCtrl.text = amount.toStringAsFixed(
      amount == amount.roundToDouble() ? 0 : 2,
    );
    setState(() => _scannedReceiver = receiver);
    await _processOfflinePayment(receiver);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _scanAmountCtrl.dispose();
    _scannerCtrl?.dispose();
    super.dispose();
  }

  // ── Scan helpers ─────────────────────────────────────────────

  void _startScan() {
    _scannerCtrl = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
    setState(() {
      _isScanning = true;
      _scannedReceiver = null;
      _error = null;
    });
  }

  void _stopScan() {
    _scannerCtrl?.dispose();
    _scannerCtrl = null;
    setState(() => _isScanning = false);
  }

  Future<void> _scanFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final ctrl = MobileScannerController();
    final completer = Completer<BarcodeCapture?>();
    final sub = ctrl.barcodes.listen((c) {
      if (!completer.isCompleted) completer.complete(c);
    });

    final found = await ctrl.analyzeImage(picked.path);
    BarcodeCapture? capture;
    if (found) {
      capture = await completer.future
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
    }
    await sub.cancel();
    ctrl.dispose();

    if (!found || capture == null) {
      setState(() => _error = 'No QR code found in that image.');
      return;
    }

    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) {
      setState(() => _error = 'Could not read QR code.');
      return;
    }

    final receiver = QrTransferService.parseReceiveQR(raw);
    setState(() {
      _scannedReceiver = receiver;
      _error = receiver == null ? 'Invalid QR — ask the recipient to show their receive QR.' : null;
    });
    if (receiver != null) _showAmountDialog(receiver);
  }

  void _onQRDetected(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    _stopScan();

    final receiver = QrTransferService.parseReceiveQR(raw);
    if (receiver == null) {
      setState(() => _error = 'Invalid QR — ask the recipient to show their receive QR.');
      return;
    }
    setState(() => _scannedReceiver = receiver);
    _showAmountDialog(receiver);
  }

  Future<void> _showAmountDialog(ReceiverQRData receiver) async {
    _scanAmountCtrl.clear();
    final wallet = context.read<WalletProvider>();
    final isOnline = wallet.isOnline;
    final limit = await _limitService.getAvailableLimit();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 32,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Recipient
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: AppTheme.primaryColor.withOpacity(0.1),
                  child: Text(
                    receiver.receiverName.isNotEmpty
                        ? receiver.receiverName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: AppTheme.primaryColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Paying to',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Text(
                      receiver.receiverName,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isOnline
                        ? AppTheme.successColor.withOpacity(0.1)
                        : AppTheme.offlineColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isOnline ? Icons.wifi : Icons.wifi_off,
                        size: 12,
                        color: isOnline ? AppTheme.successColor : AppTheme.offlineColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isOnline ? 'Online' : '₹${limit.toStringAsFixed(0)} limit',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isOnline ? AppTheme.successColor : AppTheme.offlineColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Amount input
            TextFormField(
              controller: _scanAmountCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: AppTheme.primaryColor,
              ),
              decoration: InputDecoration(
                prefixText: '₹ ',
                prefixStyle: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.primaryColor,
                ),
                hintText: '0',
                hintStyle: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade300,
                ),
                filled: true,
                fillColor: AppTheme.lightBlue,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              ),
            ),

            // Quick amounts
            const SizedBox(height: 12),
            Row(
              children: [100, 200, 500, 1000].map((v) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => _scanAmountCtrl.text = v.toString(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.lightBlue,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: AppTheme.primaryColor.withOpacity(0.2)),
                      ),
                      child: Text(
                        '₹$v',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),

            SizedBox(
              height: 54,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _processOfflinePayment(receiver);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Pay Now',
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
    );
  }

  // ── Payment logic ────────────────────────────────────────────

  Future<void> _processOfflinePayment(ReceiverQRData receiver) async {
    final amountStr = _scanAmountCtrl.text.trim();
    final amount = double.tryParse(amountStr);

    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }

    setState(() {
      _isProcessing = true;
      _error = null;
    });

    final auth = context.read<AuthProvider>();
    final senderId = auth.user?.id ?? '';
    final isOnline = await _connectivityService.checkNow();

    if (isOnline) {
      await _processOnlinePayment(senderId, receiver, amount);
      return;
    }

    // Offline path
    final availableLimit = await _limitService.getAvailableLimit();
    if (amount > availableLimit) {
      setState(() {
        _error =
            'Offline limit insufficient.\nAvailable: ₹${availableLimit.toStringAsFixed(2)}  ·  Requested: ₹${amount.toStringAsFixed(2)}';
        _isProcessing = false;
      });
      return;
    }

    final unsignedBlob = PaymentBlob(
      senderId: senderId,
      receiverId: receiver.receiverId,
      amount: amount,
      isOffline: true,
      offlineLimitAtTime: availableLimit,
    );

    // ── Sign with the device's ECDSA P-256 key BEFORE persisting ──
    // The signature is what lets the receiver trust this blob offline and
    // what the backend verifies at settlement. id / timestamp / nonce are
    // inputs to the canonical payload, so the signed copy must preserve
    // them verbatim — copyWith does exactly that.
    final signed = await _signBlob(unsignedBlob);
    final blob = signed.blob;

    await _queueService.enqueue(blob);
    await _limitService.deductFromLimit(amount);

    // Only blobs this device SENT represent offline exposure. Received
    // blobs (Case 3b) live in the same table but cost this device nothing.
    final pendingSent = await _queueService.getPendingSentBlobs();
    await _limitService.applyLocalRiskPenalty(pendingSent.length);

    // Refresh WalletProvider so displayed limit updates immediately
    if (mounted) await context.read<WalletProvider>().loadCachedTokens();

    // ── Handoff: BLE first when the receiver advertises it ────────
    bool? bleSuccess;
    if (receiver.bleUuid != null) {
      setState(() => _isBLETransferring = true);
      bleSuccess = await _runBLEWithProgress(blob, receiver.bleUuid!);
      setState(() => _isBLETransferring = false);
      if (bleSuccess == true) {
        blob.handoffMethod = HandoffMethod.ble;
        await _queueService.updateHandoffMethod(blob.id, HandoffMethod.ble);
      }
    }

    setState(() {
      _isProcessing = false;
      _scannedReceiver = null;
    });

    // ── Case 3b: hand the signed blob over by QR ──────────────────
    // Available whether or not the receiver advertises BLE; skipped only
    // when BLE already delivered the blob.
    // `senderPublicKey` is empty only when signing fell back to the
    // placeholder — a QR the receiver could not possibly verify, so skip
    // straight to the receipt rather than showing an un-scannable handoff.
    if (AppConstants.qrHandoffEnabled &&
        bleSuccess != true &&
        signed.senderPublicKey.isNotEmpty) {
      blob.handoffMethod = HandoffMethod.qr;
      await _queueService.updateHandoffMethod(blob.id, HandoffMethod.qr);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => QrHandoffScreen(
            blob: blob,
            signature: signed.signature,
            senderPublicKey: signed.senderPublicKey,
            alg: signed.isEd25519
                ? SignatureAlg.ed25519
                : SignatureAlg.ecdsaP256,
          ),
        ),
      );
    }

    final receiptStatus = bleSuccess == true
        ? ReceiptStatus.sentViaBluetooth
        : ReceiptStatus.pendingSync;

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PaymentReceiptScreen(
            amount: amount,
            recipientName: receiver.receiverName,
            paymentId: blob.id,
            status: receiptStatus,
            isOnline: false,
            timestamp: DateTime.now(),
          ),
        ),
      );
    }
  }

  /// Sign [blob] with the device key and attach the public key the backend
  /// needs to verify it.
  ///
  /// PROD-TODO: in production an unsigned blob must be refused — an
  /// unsigned payment cannot be attributed to a device and is exactly the
  /// forgery path the signature exists to close. For the demo we degrade to
  /// the placeholder so a keystore hiccup can never block a payment on
  /// stage; the backend already flags these as `unsigned_blob`.
  Future<_SignedBlob> _signBlob(PaymentBlob blob) async {
    var signed = blob;
    var ecdsaSignature = blob.deviceSignature;
    var ecdsaPublicKey = '';
    var ed25519Signature = '';
    var ed25519PublicKey = '';

    // Ed25519 (Feature B) — the trust root the backend verifies against the
    // key registered via POST /api/auth/device-key.
    try {
      final ed = DeviceEd25519Service();
      ed25519Signature = await ed.sign(canonicalPayloadV1(blob));
      ed25519PublicKey = await ed.publicKeyB64();
      signed = signed.copyWith(
        deviceSignatureEd25519: ed25519Signature,
        senderEd25519Pk: ed25519PublicKey.isEmpty ? null : ed25519PublicKey,
      );
    } catch (e) {
      debugPrint('Ed25519 signing failed: $e');
    }

    // ECDSA P-256 — kept so older backends and the BLE handshake keep working.
    try {
      final keys = DeviceKeyService();
      ecdsaSignature = await keys.signTransaction(canonicalPayload(blob));
      ecdsaPublicKey = await keys.getPublicKeyBase64() ?? '';
      signed = signed.copyWith(
        deviceSignature: ecdsaSignature,
        senderPublicKey: ecdsaPublicKey.isEmpty ? null : ecdsaPublicKey,
      );
    } catch (e) {
      debugPrint('ECDSA signing failed, keeping placeholder: $e');
    }

    if (ed25519Signature.isEmpty && ecdsaPublicKey.isEmpty) {
      debugPrint('WARNING: blob ${blob.id} is unsigned by both schemes');
    }

    return _SignedBlob(
      blob: signed,
      signature: ed25519Signature.isNotEmpty ? ed25519Signature : ecdsaSignature,
      senderPublicKey:
          ed25519Signature.isNotEmpty ? ed25519PublicKey : ecdsaPublicKey,
      isEd25519: ed25519Signature.isNotEmpty,
    );
  }

  /// Shows a dialog with live BLE transfer steps and returns the result.
  Future<bool> _runBLEWithProgress(PaymentBlob blob, String bleUuid) async {
    String _step = 'Initialising Bluetooth…';
    StateSetter? _dialogSetState;

    // Show progress dialog immediately
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          _dialogSetState = setS;
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.bluetooth_searching, color: AppTheme.primaryColor),
                SizedBox(width: 10),
                Text('Sending via Bluetooth'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  _step,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          );
        },
      ),
    );

    final result = await _bleService.sendBlobViaBLE(
      blob,
      bleUuid,
      onStatus: (s) {
        _step = s;
        _dialogSetState?.call(() {});
      },
    );

    // Give the user a moment to read the final status
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted && Navigator.canPop(context)) Navigator.pop(context);

    return result;
  }

  Future<void> _processOnlinePayment(
    String senderId,
    ReceiverQRData receiver,
    double amount,
  ) async {
    try {
      final blob = PaymentBlob(
        senderId: senderId,
        receiverId: receiver.receiverId,
        amount: amount,
        isOffline: false,
        offlineLimitAtTime: 0,
        status: BlobStatus.synced,
      );

      await Future.wait([
        _queueService.enqueue(blob),
        _callOnlinePaymentApi(
          receiverId: receiver.receiverId,
          receiverName: receiver.receiverName,
          amount: amount,
          nonce: blob.nonce,
        ),
      ]);

      if (mounted) await context.read<AuthProvider>().refreshUser();

      setState(() {
        _isProcessing = false;
        _scannedReceiver = null;
      });

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PaymentReceiptScreen(
              amount: amount,
              recipientName: receiver.receiverName,
              paymentId: blob.id,
              status: ReceiptStatus.settled,
              isOnline: true,
              timestamp: DateTime.now(),
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isProcessing = false;
      });
    }
  }

  Future<void> _callOnlinePaymentApi({
    required String receiverId,
    required String receiverName,
    required double amount,
    required String nonce,
  }) async {
    final api = ApiService();
    await api.post('/api/payments/online', {
      'receiver_id': receiverId,
      'receiver_name': receiverName,
      'amount': amount,
      'nonce': nonce,
    });
  }

  // ── Token QR generation (legacy flow) ───────────────────────

  Future<void> _generateTokenQR() async {
    setState(() {
      _error = null;
      _qrData = null;
    });

    final amountStr = _amountCtrl.text.trim();
    if (amountStr.isEmpty) {
      setState(() => _error = 'Please enter an amount');
      return;
    }

    final amount = double.tryParse(amountStr);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }

    if (amount > 5000) {
      setState(() => _error = 'Maximum offline payment is ₹5,000');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final wallet = context.read<WalletProvider>();
      final auth = context.read<AuthProvider>();

      final token = await wallet.findTokenForPayment(amount);
      if (token == null) {
        setState(() {
          _error =
              'No tokens available for ₹${amount.toStringAsFixed(0)}. Connect to internet to get tokens.';
          _isProcessing = false;
        });
        return;
      }

      final qrPayload = QrTransferService.generatePaymentQR(
        token: token,
        paymentAmount: amount,
        senderName: auth.user?.fullName ?? 'User',
      );

      setState(() {
        _qrData = qrPayload;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _confirmTokenPayment() async {
    if (_qrData == null) return;

    final wallet = context.read<WalletProvider>();
    final txProvider = context.read<TransactionProvider>();
    final auth = context.read<AuthProvider>();

    final paymentData = QrTransferService.parsePaymentQR(_qrData!);
    if (paymentData == null) return;

    await wallet.consumeToken(paymentData['token_id']);

    final tx = OfflineTransaction(
      tokenId: paymentData['token_id'],
      senderId: auth.user?.id ?? '',
      receiverName: 'Merchant',
      amount: (paymentData['amount'] as num).toDouble(),
      nonce: paymentData['nonce'],
      signature: paymentData['signature'],
      status: 'pending_offline',
    );
    await txProvider.addTransaction(tx);

    setState(() {
      _qrData = null;
      _amountCtrl.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Payment recorded (offline)'),
          backgroundColor: AppTheme.successColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletProvider>();

    return Scaffold(
      backgroundColor: AppTheme.surfaceColor,
      appBar: AppBar(
        title: const Text('Pay'),
        automaticallyImplyLeading: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: wallet.isOnline
                      ? AppTheme.successColor.withOpacity(0.1)
                      : AppTheme.offlineColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      wallet.isOnline ? Icons.wifi : Icons.wifi_off,
                      size: 13,
                      color: wallet.isOnline
                          ? AppTheme.successColor
                          : AppTheme.offlineColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      wallet.isOnline ? 'Online' : 'Offline',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: wallet.isOnline
                            ? AppTheme.successColor
                            : AppTheme.offlineColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Offline limit card ───────────────────────────
            _OfflineLimitCard(
              isOnline: wallet.isOnline,
              remaining: wallet.offlineLimitRemaining,
              total: wallet.offlineLimit,
            ),
            const SizedBox(height: 16),

            // ── Scan & Pay ───────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
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
                      const Text(
                        'Scan & Pay',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.lightBlue,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          wallet.isOnline
                              ? 'Instant settle'
                              : 'Uses offline limit',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primaryColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Pay by voice — the stage centrepiece ────────
                  if (AppConstants.voicePayEnabled && !_isScanning) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: _isProcessing ? null : startVoicePay,
                        icon: const Icon(Icons.mic, size: 22),
                        // FittedBox: the Devanagari + English label is wider
                        // than a 1080p phone at 15sp and was being clipped
                        // mid-word ("Pay by").
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'बोलकर भेजें  •  Pay by Voice',
                            maxLines: 1,
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.saffron,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        'Works in airplane mode',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Scanner view
                  if (_isScanning) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        height: 260,
                        child: _scannerCtrl != null
                            ? MobileScanner(
                                controller: _scannerCtrl!,
                                onDetect: _onQRDetected,
                              )
                            : const Center(child: CircularProgressIndicator()),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _stopScan,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primaryColor,
                        side: const BorderSide(color: AppTheme.primaryColor),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Cancel Scan'),
                    ),
                  ] else ...[
                    // Scanned receiver chip
                    if (_scannedReceiver != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppTheme.lightBlue,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle,
                                color: AppTheme.successColor, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              'Paying: ${_scannedReceiver!.receiverName}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppTheme.primaryColor,
                                fontSize: 13,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _scannedReceiver = null),
                              child: const Icon(Icons.close,
                                  size: 16, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // BLE progress
                    if (_isBLETransferring) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppTheme.primaryColor.withOpacity(0.2)),
                        ),
                        child: const Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.primaryColor),
                            ),
                            SizedBox(width: 10),
                            Text(
                              'Connecting via Bluetooth…',
                              style: TextStyle(
                                  fontSize: 13, color: AppTheme.primaryColor),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else if (_isProcessing) ...[
                      const Center(
                          child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: CircularProgressIndicator(),
                      )),
                    ],

                    // Scan buttons
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: _isProcessing ? null : _startScan,
                              icon: const Icon(Icons.qr_code_scanner, size: 18),
                              label: const Text('Scan QR to Pay'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            onPressed: _isProcessing ? null : _scanFromGallery,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primaryColor,
                              side: const BorderSide(
                                  color: AppTheme.primaryColor),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                            ),
                            child: const Icon(Icons.photo_library, size: 18),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Error
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppTheme.errorColor.withOpacity(0.2)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline,
                        color: AppTheme.errorColor, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                            color: AppTheme.errorColor, fontSize: 13),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _error = null),
                      child: const Icon(Icons.close,
                          size: 16, color: AppTheme.errorColor),
                    ),
                  ],
                ),
              ),
            ],

            // ── Token QR (legacy / merchant-facing) ──────────
            const SizedBox(height: 16),
            _TokenQRSection(
              amountCtrl: _amountCtrl,
              qrData: _qrData,
              isProcessing: _isProcessing,
              onGenerate: _generateTokenQR,
              onConfirm: _confirmTokenPayment,
              onCancel: () => setState(() {
                _qrData = null;
                _amountCtrl.clear();
              }),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ── Offline limit card ─────────────────────────────────────────────────────

class _OfflineLimitCard extends StatelessWidget {
  final bool isOnline;
  final double remaining;
  final double total;

  const _OfflineLimitCard({
    required this.isOnline,
    required this.remaining,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = total > 0 ? (remaining / total).clamp(0.0, 1.0) : 0.0;
    final barColor = fraction > 0.5
        ? AppTheme.successColor
        : fraction > 0.2
            ? AppTheme.warningColor
            : AppTheme.errorColor;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isOnline ? Icons.wifi : Icons.wifi_off,
                size: 16,
                color: isOnline ? AppTheme.successColor : AppTheme.offlineColor,
              ),
              const SizedBox(width: 6),
              Text(
                isOnline ? 'Online — bank payments enabled' : 'Offline Mode',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isOnline ? AppTheme.successColor : AppTheme.offlineColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Offline Credit Limit',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 2),
                  RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '₹${remaining.toStringAsFixed(0)}',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.primaryColor,
                          ),
                        ),
                        TextSpan(
                          text: ' / ₹${total.toStringAsFixed(0)}',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${(fraction * 100).round()}%',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: barColor,
                    ),
                  ),
                  const Text('remaining',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: Colors.grey.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Token QR section ──────────────────────────────────────────────────────

class _TokenQRSection extends StatelessWidget {
  final TextEditingController amountCtrl;
  final String? qrData;
  final bool isProcessing;
  final VoidCallback onGenerate;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _TokenQRSection({
    required this.amountCtrl,
    required this.qrData,
    required this.isProcessing,
    required this.onGenerate,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Icon(Icons.qr_code, color: AppTheme.primaryColor, size: 20),
              const SizedBox(width: 8),
              const Flexible(
                child: Text(
                  'Generate Token QR',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Flexible, not Spacer + fixed Container: at 1080p the badge
              // overflowed the row by 19px and Flutter painted the yellow
              // "RIGHT OVERFLOWED" stripes right where judges are looking.
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.lightBlue,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Merchant scans you',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Show this QR to a merchant — they scan it to accept your payment.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 16),

          if (qrData == null) ...[
            TextFormField(
              controller: amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
              decoration: const InputDecoration(
                prefixText: '₹ ',
                prefixStyle: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w700),
                hintText: '0',
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [50, 100, 200, 500].map((v) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => amountCtrl.text = v.toString(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppTheme.lightBlue,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text('₹$v',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryColor)),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: isProcessing ? null : onGenerate,
                icon: isProcessing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.qr_code, size: 18),
                label: Text(isProcessing ? 'Generating…' : 'Generate QR'),
              ),
            ),
          ] else ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.lightBlue,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: qrData!,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.circle,
                    color: AppTheme.primaryColor,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.circle,
                    color: AppTheme.primaryColor,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Show this to the merchant to scan',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primaryColor,
                      side: const BorderSide(color: AppTheme.primaryColor),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: onConfirm,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Merchant Scanned'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.successColor,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A blob plus the signature material the QR handoff needs to carry.
/// `senderPublicKey` is empty only on the signing-failure fallback path.
class _SignedBlob {
  final PaymentBlob blob;

  /// The signature the QR handoff should carry — Ed25519 when we produced
  /// one, otherwise the legacy ECDSA signature.
  final String signature;
  final String senderPublicKey;

  /// True when [signature] is Ed25519, so the receiver knows which canonical
  /// payload to verify it against.
  final bool isEd25519;

  const _SignedBlob({
    required this.blob,
    required this.signature,
    required this.senderPublicKey,
    this.isEd25519 = false,
  });
}
