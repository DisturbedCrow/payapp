import 'dart:convert';
import '../models/payment_blob.dart';
import '../models/payment_token.dart';
import '../models/transaction.dart';

/// Signature schemes a handoff QR can carry.
class SignatureAlg {
  /// Feature B — signature over `canonicalPayloadV1(blob)`.
  static const String ed25519 = 'ed25519';

  /// Legacy — DER signature over `canonicalPayload(blob)`.
  static const String ecdsaP256 = 'ecdsa-p256';
}

/// A signed payment blob handed sender → receiver through a QR code
/// ("Case 3b": both phones offline, no BLE).
///
/// The receiver can verify this entirely offline: [signature] was made by the
/// private key matching [senderPublicKey], over the canonical payload that
/// [alg] selects.
class BlobHandoff {
  final PaymentBlob blob;

  /// Base64 signature, in the scheme named by [alg].
  final String signature;

  /// Base64 public key of the sending device, in the scheme named by [alg].
  final String senderPublicKey;

  /// Which scheme [signature] and [senderPublicKey] use. QRs produced before
  /// Feature B carry no `alg` and default to ECDSA P-256.
  final String alg;

  const BlobHandoff({
    required this.blob,
    required this.signature,
    required this.senderPublicKey,
    this.alg = SignatureAlg.ecdsaP256,
  });
}

/// Payload embedded in a receiver's static QR code (merchant / user display).
/// The sender scans this QR to know who to pay.
class ReceiverQRData {
  final String receiverId;
  final String receiverName;
  /// Optional BLE UUID — populated for Case 3 (both offline).
  final String? bleUuid;

  const ReceiverQRData({
    required this.receiverId,
    required this.receiverName,
    this.bleUuid,
  });
}

class QrTransferService {
  // ── Receiver QR (static — displayed by merchant/receiver) ────────

  /// Generate a static QR that the receiver displays.
  /// Sender scans this to initiate a payment (online or offline).
  /// [bleUuid] is only set when the receiver is also advertising over BLE (Case 3).
  static String generateReceiveQR({
    required String receiverId,
    required String receiverName,
    String? bleUuid,
  }) {
    final payload = <String, dynamic>{
      'type': 'receive_payment',
      'version': 1,
      'receiver_id': receiverId,
      'receiver_name': receiverName,
      if (bleUuid != null) 'ble_uuid': bleUuid,
    };
    return jsonEncode(payload);
  }

  /// Parse a scanned QR and return [ReceiverQRData] if it is a receive_payment QR.
  /// Returns null for any other QR format.
  static ReceiverQRData? parseReceiveQR(String qrData) {
    try {
      final data = jsonDecode(qrData) as Map<String, dynamic>;
      if (data['type'] != 'receive_payment') return null;
      final receiverId = data['receiver_id'] as String?;
      if (receiverId == null || receiverId.isEmpty) return null;
      return ReceiverQRData(
        receiverId: receiverId,
        receiverName: data['receiver_name'] as String? ?? 'Unknown',
        bleUuid: data['ble_uuid'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// What to tell a receiver whose scan was not a payment hand-off. Call only
  /// after [decodeBlobHandoff] returned null. The usual mistake is scanning
  /// the other person's "My QR Code", which is for getting paid, not a payment.
  static String explainNotHandoff(String raw) {
    final receive = parseReceiveQR(raw);
    if (receive != null) {
      final name = receive.receiverName;
      return "That is $name's QR for receiving money — not a payment.\n"
          'To pay $name, scan it from the Pay screen instead. '
          'To receive here, scan the QR the sender shows after paying.';
    }
    if (parsePaymentQR(raw) != null) {
      return 'That is an older SetuPay payment QR this screen cannot accept.\n'
          'Ask the sender to pay again and show the new hand-off QR.';
    }
    return 'That QR is not a SetuPay payment.\n'
        'Ask the sender to open "Hand off via QR" on their phone.';
  }

  // ── Signed-blob handoff QR (Case 3b — both phones offline) ──────

  /// Wire format version for [encodeBlobHandoff] / [decodeBlobHandoff].
  static const int blobHandoffVersion = 1;

  /// Discriminator that tells a scanned QR apart from every other QR the
  /// app produces (`receive_payment`, `offline_payment`).
  static const String blobHandoffType = 'spay.blob';

  /// Encode a SIGNED blob for display in a QR code.
  ///
  /// Shape (base64url of the UTF-8 JSON below, ~550 chars in practice):
  ///
  ///     {"v":1,"t":"spay.blob","blob":{...},"sig":"<b64>","spk":"<b64>"}
  ///
  /// The blob object carries only the fields the receiver needs to rebuild
  /// the exact canonical payload that was signed, plus the two offline
  /// bookkeeping flags. `timestamp` is the UTC form on purpose — the
  /// canonical payload is built from `timestamp.toUtc()`, so anything else
  /// would make the signature unverifiable after a timezone round-trip.
  static String encodeBlobHandoff({
    required PaymentBlob blob,
    required String signature,
    required String senderPublicKey,
    String alg = SignatureAlg.ecdsaP256,
  }) {
    final payload = <String, dynamic>{
      'v': blobHandoffVersion,
      't': blobHandoffType,
      'blob': <String, dynamic>{
        'id': blob.id,
        'sender_id': blob.senderId,
        'receiver_id': blob.receiverId,
        'amount': blob.amount,
        'timestamp': blob.timestamp.toUtc().toIso8601String(),
        'nonce': blob.nonce,
        'is_offline': blob.isOffline,
        'offline_limit_at_time': blob.offlineLimitAtTime,
      },
      'sig': signature,
      'spk': senderPublicKey,
      'alg': alg,
    };
    return base64Url.encode(utf8.encode(jsonEncode(payload)));
  }

  /// Decode a scanned QR string into a [BlobHandoff].
  ///
  /// Returns null — never throws — for anything that is not a well-formed
  /// `spay.blob` payload. This is fed arbitrary camera input, including the
  /// app's own plain-JSON `receive_payment` QRs and partial scans.
  static BlobHandoff? decodeBlobHandoff(String raw) {
    try {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      // Fast reject: our other QRs are bare JSON, which is never base64url.
      if (trimmed.startsWith('{')) return null;

      final bytes = base64Url.decode(base64Url.normalize(trimmed));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;

      if (decoded['v'] != blobHandoffVersion) return null;
      if (decoded['t'] != blobHandoffType) return null;

      final blobMap = decoded['blob'];
      if (blobMap is! Map) return null;

      final sig = decoded['sig'];
      final spk = decoded['spk'];
      if (sig is! String || sig.isEmpty) return null;
      if (spk is! String || spk.isEmpty) return null;

      // Absent on QRs produced before Feature B — those are ECDSA.
      final rawAlg = decoded['alg'];
      final alg = rawAlg is String && rawAlg.isNotEmpty
          ? rawAlg
          : SignatureAlg.ecdsaP256;
      if (alg != SignatureAlg.ed25519 && alg != SignatureAlg.ecdsaP256) {
        return null; // a scheme this build cannot verify
      }

      final id = blobMap['id'];
      final senderId = blobMap['sender_id'];
      final receiverId = blobMap['receiver_id'];
      final nonce = blobMap['nonce'];
      final amount = blobMap['amount'];
      final timestamp = blobMap['timestamp'];
      if (id is! String || id.isEmpty) return null;
      if (senderId is! String || senderId.isEmpty) return null;
      if (receiverId is! String || receiverId.isEmpty) return null;
      if (nonce is! String || nonce.isEmpty) return null;
      if (amount is! num || amount <= 0) return null;
      if (timestamp is! String || timestamp.isEmpty) return null;

      final parsedTimestamp = DateTime.tryParse(timestamp);
      if (parsedTimestamp == null) return null;

      final blob = PaymentBlob(
        id: id,
        senderId: senderId,
        receiverId: receiverId,
        amount: amount.toDouble(),
        timestamp: parsedTimestamp,
        nonce: nonce,
        deviceSignature: sig,
        status: BlobStatus.pendingSync,
        isOffline: blobMap['is_offline'] as bool? ?? true,
        offlineLimitAtTime:
            (blobMap['offline_limit_at_time'] as num?)?.toDouble() ?? 0.0,
        senderPublicKey: spk,
        handoffMethod: HandoffMethod.qr,
      );

      return BlobHandoff(
        blob: blob,
        signature: sig,
        senderPublicKey: spk,
        alg: alg,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Sender payment QR (token-based — generated by sender) ───────

  /// Generate QR code data for a payment
  /// This encodes the signed token + payment amount into a JSON string
  static String generatePaymentQR({
    required PaymentToken token,
    required double paymentAmount,
    required String senderName,
  }) {
    final payload = {
      'type': 'offline_payment',
      'version': 1,
      'token_id': token.tokenId,
      'user_id': token.userId,
      'amount': paymentAmount,
      'token_amount': token.amount,
      'issued_at': token.issuedAt,
      'expires_at': token.expiresAt,
      'nonce': token.nonce,
      'signature': token.signature,
      'sender_name': senderName,
      'timestamp': DateTime.now().toIso8601String(),
    };

    return jsonEncode(payload);
  }

  /// Parse a scanned QR code and extract payment data
  static Map<String, dynamic>? parsePaymentQR(String qrData) {
    try {
      final data = jsonDecode(qrData);

      // Validate it's an offline payment QR
      if (data['type'] != 'offline_payment') return null;

      // Required fields check
      final requiredFields = [
        'token_id', 'user_id', 'amount', 'nonce', 'signature',
      ];
      for (final field in requiredFields) {
        if (data[field] == null) return null;
      }

      return data;
    } catch (_) {
      return null;
    }
  }

  /// Validate payment data locally (no network needed)
  static PaymentValidation validatePayment(Map<String, dynamic> paymentData) {
    // Check expiry
    final expiresAt = paymentData['expires_at'];
    if (expiresAt != null) {
      try {
        final expiry = DateTime.parse(expiresAt);
        if (DateTime.now().isAfter(expiry)) {
          return PaymentValidation(
            isValid: false,
            error: 'Payment token has expired',
          );
        }
      } catch (_) {
        return PaymentValidation(
          isValid: false,
          error: 'Invalid expiry date',
        );
      }
    }

    // Check amount
    final amount = (paymentData['amount'] as num?)?.toDouble() ?? 0;
    final tokenAmount = (paymentData['token_amount'] as num?)?.toDouble() ?? 0;
    if (amount <= 0) {
      return PaymentValidation(
        isValid: false,
        error: 'Invalid payment amount',
      );
    }
    if (amount > tokenAmount) {
      return PaymentValidation(
        isValid: false,
        error: 'Payment amount exceeds token limit',
      );
    }

    // Check signature exists
    if (paymentData['signature'] == null ||
        paymentData['signature'].toString().isEmpty) {
      return PaymentValidation(
        isValid: false,
        error: 'Missing payment signature',
      );
    }

    return PaymentValidation(
      isValid: true,
      amount: amount,
      senderName: paymentData['sender_name'] ?? 'Unknown',
      senderId: paymentData['user_id'] ?? '',
      tokenId: paymentData['token_id'] ?? '',
      nonce: paymentData['nonce'] ?? '',
      signature: paymentData['signature'] ?? '',
    );
  }

  /// Create a transaction record from validated payment data
  static OfflineTransaction createTransactionFromPayment(
    Map<String, dynamic> paymentData, {
    required String merchantId,
    required String merchantName,
  }) {
    final senderName = paymentData['sender_name'] as String? ?? 'User';
    return OfflineTransaction(
      tokenId: paymentData['token_id'],
      senderId: paymentData['user_id'],
      receiverId: merchantId,
      receiverName: senderName,
      amount: (paymentData['amount'] as num).toDouble(),
      nonce: paymentData['nonce'],
      signature: paymentData['signature'],
      status: 'pending_offline',
      createdAt: DateTime.now().toIso8601String(),
    );
  }
}

class PaymentValidation {
  final bool isValid;
  final String? error;
  final double? amount;
  final String? senderName;
  final String? senderId;
  final String? tokenId;
  final String? nonce;
  final String? signature;

  PaymentValidation({
    required this.isValid,
    this.error,
    this.amount,
    this.senderName,
    this.senderId,
    this.tokenId,
    this.nonce,
    this.signature,
  });
}
