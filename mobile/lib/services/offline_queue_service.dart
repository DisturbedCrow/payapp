import 'package:sqflite/sqflite.dart';
import '../models/payment_blob.dart';
import 'offline_storage.dart';

/// Manages the SQLite queue of [PaymentBlob] objects.
///
/// Works alongside [OfflineStorage] (which owns the token/transaction tables).
/// The `payment_blobs` table was added in DB v2 via [OfflineStorage._onUpgrade].
/// All operations are async.
class OfflineQueueService {
  static final OfflineQueueService _instance = OfflineQueueService._internal();
  factory OfflineQueueService() => _instance;
  OfflineQueueService._internal();

  // Reuse the same DB instance — OfflineStorage owns the connection
  Future<Database> get _db => OfflineStorage().database;

  // ── Write ────────────────────────────────────────────────────

  /// Enqueue a new blob. Ignored silently if the nonce already exists.
  Future<void> enqueue(PaymentBlob blob) async {
    final db = await _db;
    await db.insert(
      'payment_blobs',
      blob.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Update the status of a blob identified by its [id].
  Future<void> updateStatus(String id, String status) async {
    final db = await _db;
    await db.update(
      'payment_blobs',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Record how the blob actually reached the counterparty ('qr' | 'ble').
  ///
  /// The blob is enqueued the moment the limit is deducted, which is *before*
  /// the handoff happens, so the route is written back afterwards. The
  /// backend reads `handoff_method` off the synced blob for the ops dashboard.
  Future<void> updateHandoffMethod(String id, String method) async {
    final db = await _db;
    await db.update(
      'payment_blobs',
      {'handoff_method': method},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── Read ─────────────────────────────────────────────────────

  /// All blobs with status `pending_sync`, oldest first.
  Future<List<PaymentBlob>> getPendingBlobs() async {
    final db = await _db;
    final rows = await db.query(
      'payment_blobs',
      where: 'status = ?',
      whereArgs: [BlobStatus.pendingSync],
      orderBy: 'timestamp ASC',
    );
    return rows.map(PaymentBlob.fromDbMap).toList();
  }

  /// All blobs for a given sender, newest first.
  Future<List<PaymentBlob>> getBlobsForSender(String senderId) async {
    final db = await _db;
    final rows = await db.query(
      'payment_blobs',
      where: 'sender_id = ?',
      whereArgs: [senderId],
      orderBy: 'timestamp DESC',
    );
    return rows.map(PaymentBlob.fromDbMap).toList();
  }

  /// All blobs for a given receiver, newest first.
  Future<List<PaymentBlob>> getBlobsForReceiver(String receiverId) async {
    final db = await _db;
    final rows = await db.query(
      'payment_blobs',
      where: 'receiver_id = ?',
      whereArgs: [receiverId],
      orderBy: 'timestamp DESC',
    );
    return rows.map(PaymentBlob.fromDbMap).toList();
  }

  /// Look up a blob by its nonce. Used by the QR receive flow to detect a
  /// blob that was already scanned ("Already received") before touching the
  /// queue — `enqueue` ignores the duplicate silently, which is safe but
  /// indistinguishable from a fresh insert.
  Future<PaymentBlob?> findByNonce(String nonce) async {
    final db = await _db;
    final rows = await db.query(
      'payment_blobs',
      where: 'nonce = ?',
      whereArgs: [nonce],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PaymentBlob.fromDbMap(rows.first);
  }

  /// Blobs this device is on the hook for — i.e. money it SENT. Received
  /// blobs live in the same table but were never deducted from this
  /// device's offline limit, so they must not feed limit/risk arithmetic.
  Future<List<PaymentBlob>> getPendingSentBlobs() async {
    final pending = await getPendingBlobs();
    return pending.where((b) => !b.isReceived).toList();
  }

  /// Count of blobs currently pending sync.
  Future<int> getPendingCount() async {
    final db = await _db;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM payment_blobs WHERE status = 'pending_sync'",
    );
    return result.first['cnt'] as int? ?? 0;
  }

  /// Sum of amounts for *outgoing* blobs pending sync. Money the user has
  /// been paid but not yet settled is not something they owe, so it must not
  /// appear in their "pending" total or count against their risk penalty.
  Future<double> getPendingSentTotal() async {
    final db = await _db;
    final result = await db.rawQuery(
      "SELECT COALESCE(SUM(amount), 0) as total FROM payment_blobs "
      "WHERE status = 'pending_sync' AND COALESCE(direction, 'sent') = 'sent'",
    );
    return (result.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  /// Count of *outgoing* blobs pending sync.
  Future<int> getPendingSentCount() async {
    final db = await _db;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM payment_blobs "
      "WHERE status = 'pending_sync' AND COALESCE(direction, 'sent') = 'sent'",
    );
    return result.first['cnt'] as int? ?? 0;
  }

  /// Sum of amounts for blobs pending sync.
  Future<double> getPendingTotal() async {
    final db = await _db;
    final result = await db.rawQuery(
      "SELECT COALESCE(SUM(amount), 0) as total FROM payment_blobs WHERE status = 'pending_sync'",
    );
    return (result.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  // ── Maintenance ──────────────────────────────────────────────

  /// Remove blobs that were synced or rejected more than [days] days ago.
  /// Called by the SyncEngine to keep the queue from growing unbounded.
  Future<void> clearSettledOlderThan(int days) async {
    final db = await _db;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .toIso8601String();
    await db.delete(
      'payment_blobs',
      where: "status != ? AND timestamp < ?",
      whereArgs: [BlobStatus.pendingSync, cutoff],
    );
  }
}
