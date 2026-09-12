import 'package:uuid/uuid.dart';

/// Status values for a PaymentBlob
class BlobStatus {
  static const String pendingSync = 'pending_sync';
  static const String synced = 'synced';
  static const String rejected = 'rejected';
}

/// How a blob was handed to the counterparty while offline.
class HandoffMethod {
  static const String qr = 'qr';
  static const String ble = 'ble';
}

/// Which side of the payment this device is on.
class BlobDirection {
  static const String sent = 'sent';
  static const String received = 'received';
}

/// The canonical string that gets signed by the sending device.
///
/// THIS IS THE SINGLE SOURCE OF TRUTH ON THE CLIENT and must stay
/// byte-for-byte identical to the server's
/// `backend/app/services/signing.py::canonical_payload`. Any divergence and
/// every signed blob from a real phone is rejected as `invalid_signature`.
///
///     {id}|{sender_id}|{receiver_id}|{amount}|{timestamp}|{nonce}
///
///   amount     fixed 2-decimal, dot separator      (250.00)
///   timestamp  UTC ISO-8601, Dart's millisecond
///              precision with a trailing Z         (2026-09-13T10:00:00.000Z)
///
/// Covered by the cross-language test vector in
/// mobile/test/canonical_payload_test.dart.
String canonicalPayload(PaymentBlob b) {
  return '${b.id}|${b.senderId}|${b.receiverId}|'
      '${b.amount.toStringAsFixed(2)}|'
      '${b.timestamp.toUtc().toIso8601String()}|${b.nonce}';
}

/// A PaymentBlob represents a single offline payment capture.
/// It is decoupled from settlement — the blob is stored locally and
/// submitted to the backend when connectivity is restored.
///
/// This lives alongside the existing token-based OfflineTransaction.
/// Tokens gate how much can be spent offline; blobs record what was spent.
class PaymentBlob {
  final String id;
  final String senderId;
  final String receiverId;
  final double amount;
  final DateTime timestamp;
  final String nonce;
  final String deviceSignature; // base64 DER ECDSA P-256, or the placeholder
  String status; // BlobStatus constants
  final bool isOffline;
  final double offlineLimitAtTime; // limit cached in SharedPrefs at payment time

  /// Base64 compressed P-256 public key of the SENDING device. The backend
  /// reads this as `sender_public_key` to verify the signature when the
  /// device has not yet registered its key.
  final String? senderPublicKey;

  /// 'qr' | 'ble' | null — how the blob reached the counterparty offline.
  /// Mutable: the blob is enqueued before the handoff actually happens.
  String? handoffMethod;

  /// 'sent' | 'received' — which side of the payment this device is on.
  /// A received blob was never deducted from THIS device's offline limit.
  final String direction;

  PaymentBlob({
    String? id,
    required this.senderId,
    required this.receiverId,
    required this.amount,
    DateTime? timestamp,
    String? nonce,
    this.deviceSignature = 'DEVICE_SIG_PLACEHOLDER',
    this.status = BlobStatus.pendingSync,
    required this.isOffline,
    required this.offlineLimitAtTime,
    this.senderPublicKey,
    this.handoffMethod,
    this.direction = BlobDirection.sent,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now(),
        nonce = nonce ?? const Uuid().v4();

  /// Copy with overrides. `deviceSignature` is final, so this is how a blob
  /// becomes a *signed* blob without losing its id/timestamp/nonce — all
  /// three are inputs to [canonicalPayload] and must survive verbatim.
  PaymentBlob copyWith({
    String? deviceSignature,
    String? status,
    String? senderPublicKey,
    String? handoffMethod,
    String? direction,
  }) {
    return PaymentBlob(
      id: id,
      senderId: senderId,
      receiverId: receiverId,
      amount: amount,
      timestamp: timestamp,
      nonce: nonce,
      deviceSignature: deviceSignature ?? this.deviceSignature,
      status: status ?? this.status,
      isOffline: isOffline,
      offlineLimitAtTime: offlineLimitAtTime,
      senderPublicKey: senderPublicKey ?? this.senderPublicKey,
      handoffMethod: handoffMethod ?? this.handoffMethod,
      direction: direction ?? this.direction,
    );
  }

  bool get isReceived => direction == BlobDirection.received;

  // ── Serialization ────────────────────────────────────────────

  factory PaymentBlob.fromJson(Map<String, dynamic> json) {
    return PaymentBlob(
      id: json['id'] ?? const Uuid().v4(),
      senderId: json['sender_id'] ?? '',
      receiverId: json['receiver_id'] ?? '',
      amount: (json['amount'] ?? 0).toDouble(),
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'])
          : DateTime.now(),
      nonce: json['nonce'] ?? const Uuid().v4(),
      deviceSignature: json['device_signature'] ?? 'DEVICE_SIG_PLACEHOLDER',
      status: json['status'] ?? BlobStatus.pendingSync,
      isOffline: json['is_offline'] ?? true,
      offlineLimitAtTime: (json['offline_limit_at_time'] ?? 0).toDouble(),
      senderPublicKey: json['sender_public_key'] as String?,
      handoffMethod: json['handoff_method'] as String?,
      direction: json['direction'] ?? BlobDirection.sent,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'receiver_id': receiverId,
      'amount': amount,
      // MUST be the UTC form: this is the string the server feeds back into
      // canonical_payload() to verify the signature we produced over
      // timestamp.toUtc(). A naive local-time string here reconstructs a
      // different canonical payload and every signature fails.
      'timestamp': timestamp.toUtc().toIso8601String(),
      'nonce': nonce,
      'device_signature': deviceSignature,
      'status': status,
      'is_offline': isOffline,
      'offline_limit_at_time': offlineLimitAtTime,
      if (senderPublicKey != null) 'sender_public_key': senderPublicKey,
      if (handoffMethod != null) 'handoff_method': handoffMethod,
      'direction': direction,
    };
  }

  // ── SQLite helpers ───────────────────────────────────────────

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'sender_id': senderId,
      'receiver_id': receiverId,
      'amount': amount,
      'timestamp': timestamp.toIso8601String(),
      'nonce': nonce,
      'device_signature': deviceSignature,
      'status': status,
      'is_offline': isOffline ? 1 : 0,
      'offline_limit_at_time': offlineLimitAtTime,
      'sender_public_key': senderPublicKey,
      'handoff_method': handoffMethod,
      'direction': direction,
    };
  }

  factory PaymentBlob.fromDbMap(Map<String, dynamic> map) {
    return PaymentBlob(
      id: map['id'] ?? const Uuid().v4(),
      senderId: map['sender_id'] ?? '',
      receiverId: map['receiver_id'] ?? '',
      amount: (map['amount'] ?? 0).toDouble(),
      timestamp: map['timestamp'] != null
          ? DateTime.parse(map['timestamp'])
          : DateTime.now(),
      nonce: map['nonce'] ?? const Uuid().v4(),
      deviceSignature: map['device_signature'] ?? 'DEVICE_SIG_PLACEHOLDER',
      status: map['status'] ?? BlobStatus.pendingSync,
      isOffline: (map['is_offline'] ?? 1) == 1,
      offlineLimitAtTime: (map['offline_limit_at_time'] ?? 0).toDouble(),
      senderPublicKey: map['sender_public_key'] as String?,
      handoffMethod: map['handoff_method'] as String?,
      direction: (map['direction'] as String?) ?? BlobDirection.sent,
    );
  }

  // ── Convenience getters ──────────────────────────────────────

  bool get isPendingSync => status == BlobStatus.pendingSync;
  bool get isSynced => status == BlobStatus.synced;
  bool get isRejected => status == BlobStatus.rejected;

  String get statusDisplay {
    switch (status) {
      case BlobStatus.pendingSync:
        return 'Pending Sync';
      case BlobStatus.synced:
        return 'Synced';
      case BlobStatus.rejected:
        return 'Rejected';
      default:
        return status;
    }
  }
}
