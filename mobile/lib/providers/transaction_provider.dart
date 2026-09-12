import 'package:flutter/material.dart';
import '../models/transaction.dart';
import '../models/payment_blob.dart';
import '../services/offline_storage.dart';
import '../services/offline_queue_service.dart';
import '../services/sync_service.dart';
import '../services/api_service.dart';
import '../services/offline_limit_service.dart';

class TransactionProvider extends ChangeNotifier {
  final OfflineStorage _storage = OfflineStorage();
  final OfflineQueueService _blobQueue = OfflineQueueService();
  final SyncService _syncService = SyncService();
  final ApiService _api = ApiService();
  final OfflineLimitService _limitService = OfflineLimitService();

  List<OfflineTransaction> _transactions = [];
  List<OfflineTransaction> _serverTransactions = [];
  List<OfflineTransaction> _blobTransactions = [];
  int _pendingCount = 0;
  double _pendingAmount = 0;
  bool _isSyncing = false;
  String? _lastSyncError;

  List<OfflineTransaction> get transactions => _transactions;
  List<OfflineTransaction> get serverTransactions => _serverTransactions;
  List<OfflineTransaction> get allTransactions {
    // Merge token-based local, blob-based local, and server transactions, dedup by nonce.
    final seen = <String>{};
    final merged = <OfflineTransaction>[];
    for (final tx in [..._transactions, ..._blobTransactions]) {
      if (seen.add(tx.nonce)) merged.add(tx);
    }
    for (final tx in _serverTransactions) {
      if (seen.add(tx.nonce)) merged.add(tx);
    }
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged;
  }

  int get pendingCount => _pendingCount;
  double get pendingAmount => _pendingAmount;
  bool get isSyncing => _isSyncing;
  String? get lastSyncError => _lastSyncError;

  /// Load transactions from local storage (token-based + blob-based + cached server).
  Future<void> loadLocalTransactions({String? userId}) async {
    if (userId != null) {
      _transactions = await _storage.getTransactionsForUser(userId);
      // Load blobs where this user is the sender (outgoing offline payments)
      final sentBlobs = await _blobQueue.getBlobsForSender(userId);
      // Load blobs where this user is the receiver (BLE/offline payments received)
      final receivedBlobs = await _blobQueue.getBlobsForReceiver(userId);
      _blobTransactions = [
        ...sentBlobs.map((b) => _blobToTransaction(b, isOutgoing: true)),
        ...receivedBlobs.map((b) => _blobToTransaction(b, isOutgoing: false)),
      ];
      // Load cached server transactions so history shows even when offline
      _serverTransactions = await _storage.getCachedServerTransactions(userId);
    } else {
      _transactions = await _storage.getAllTransactions();
      _blobTransactions = [];
    }
    _pendingCount = await _storage.getPendingCount() +
        await _blobQueue.getPendingSentCount();
    _pendingAmount = await _storage.getTotalPending() +
        await _blobQueue.getPendingSentTotal();
    notifyListeners();
  }

  /// Convert a PaymentBlob to an OfflineTransaction for display in the history UI.
  OfflineTransaction _blobToTransaction(PaymentBlob blob, {bool isOutgoing = true}) {
    final displayId = isOutgoing ? blob.receiverId : blob.senderId;
    final shortId = displayId.length > 8 ? displayId.substring(0, 8) : displayId;
    return OfflineTransaction(
      id: blob.id,
      tokenId: blob.nonce,
      senderId: blob.senderId,
      receiverId: blob.receiverId,
      receiverName: isOutgoing ? shortId : 'From $shortId',
      amount: blob.amount,
      nonce: blob.nonce,
      signature: blob.deviceSignature,
      status: _mapBlobStatus(blob.status),
      createdAt: blob.timestamp.toIso8601String(),
    );
  }

  String _mapBlobStatus(String blobStatus) {
    switch (blobStatus) {
      case BlobStatus.synced:
        return 'settled';
      case BlobStatus.rejected:
        return 'failed';
      default:
        return 'pending_offline';
    }
  }

  /// Store a new offline transaction
  Future<void> addTransaction(OfflineTransaction tx) async {
    await _storage.insertTransaction(tx);
    _transactions.insert(0, tx);
    _pendingCount++;
    _pendingAmount += tx.amount;
    notifyListeners();
  }

  /// Sync pending transactions with backend
  Future<Map<String, int>> syncTransactions() async {
    _isSyncing = true;
    _lastSyncError = null;
    notifyListeners();

    try {
      final result = await _syncService.syncPendingTransactions();
      // Reload local transactions to get updated statuses
      _transactions = await _storage.getAllTransactions();
      _pendingCount = await _storage.getPendingCount() +
          await _blobQueue.getPendingSentCount();
      _pendingAmount = await _storage.getTotalPending() +
          await _blobQueue.getPendingSentTotal();
      _isSyncing = false;
      notifyListeners();
      // Fetch recalculated offline limit from backend after sync
      await _limitService.fetchAndCacheLimit();
      return result;
    } catch (e) {
      _lastSyncError = e.toString();
      _isSyncing = false;
      notifyListeners();
      return {'settled': 0, 'failed': 0};
    }
  }

  /// Fetch transaction history from server and persist to SQLite cache.
  Future<void> fetchServerTransactions({bool isUser = true, String? userId}) async {
    try {
      final endpoint = isUser ? '/api/dashboard/user' : '/api/dashboard/merchant';
      final response = await _api.get(endpoint);
      final txList = response['recent_transactions'] as List? ?? [];
      final fetched = txList.map((t) {
        final serverId = t['id']?.toString() ?? '';
        return OfflineTransaction(
          id: serverId,
          tokenId: t['token_id'] ?? '',
          senderId: '',
          receiverName: t['counterparty_name'],
          amount: (t['amount'] ?? 0).toDouble(),
          nonce: 'server_$serverId',
          signature: '',
          status: t['status'] ?? 'settled',
          createdAt: t['created_at'] ?? DateTime.now().toIso8601String(),
          settledAt: t['settled_at']?.toString(),
        );
      }).toList();

      // Persist to SQLite so they're visible offline
      if (userId != null && fetched.isNotEmpty) {
        await _storage.cacheServerTransactions(fetched, userId);
      }

      _serverTransactions = fetched;
      notifyListeners();
    } catch (e) {
      // Fetching failed (offline) — cached rows already loaded by loadLocalTransactions
    }
  }

  /// Start background sync monitoring
  void startSync() {
    _syncService.onSyncCompleted = (settled, failed) async {
      await loadLocalTransactions();
      await _limitService.fetchAndCacheLimit();
    };
    _syncService.startMonitoring();
  }

  /// Stop background sync
  void stopSync() {
    _syncService.stopMonitoring();
  }
}
