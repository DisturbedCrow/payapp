import 'dart:async';
import '../models/payment_blob.dart';
import 'api_service.dart';
import 'connectivity_service.dart';
import 'offline_limit_service.dart';
import 'offline_queue_service.dart';
import 'device_ed25519_service.dart';

/// The SyncEngine submits pending [PaymentBlob]s to the backend when
/// connectivity is restored and processes the server's response:
///
///   accepted  → mark blob as [BlobStatus.synced]
///   confirmed → the OTHER side of this payment already synced it and the
///               server has now seen both halves. Settled, not an error:
///               treat exactly like accepted (Case 3b — sender and receiver
///               both hold the same blob and both submit it).
///   duplicate → already processed — settle locally to stop re-submitting
///   adjusted  → mark blob as [BlobStatus.synced] at the adjusted amount
///   rejected  → mark blob as [BlobStatus.rejected], restore offline limit
///
/// Limit restoration only applies to blobs this device SENT. A received blob
/// never deducted anything from this device's offline limit, so restoring on
/// its rejection would mint limit out of thin air.
///
/// It also clears settled/rejected blobs older than 7 days.
class SyncEngine {
  static final SyncEngine _instance = SyncEngine._internal();
  factory SyncEngine() => _instance;
  SyncEngine._internal();

  final _api = ApiService();
  final _connectivity = ConnectivityService();
  final _queue = OfflineQueueService();
  final _limitService = OfflineLimitService();

  /// Set by HomeScreen after login so the engine can retry Ed25519 key
  /// registration once connectivity comes back.
  String? _currentUserId;
  set currentUserId(String? id) => _currentUserId = id;

  StreamSubscription<bool>? _connectivitySub;
  Timer? _periodicTimer;
  bool _isSyncing = false;

  // Callbacks the UI can subscribe to
  Function(int synced, int rejected)? onSyncCompleted;
  Function(String error)? onSyncError;

  // ── Lifecycle ────────────────────────────────────────────────

  /// Start the engine. Listens for connectivity events and also
  /// runs a periodic sync every 30 seconds when online.
  void start() {
    _connectivity.startListening();
    _connectivitySub?.cancel();
    _connectivitySub = _connectivity.statusStream.listen((isOnline) {
      if (isOnline) _runSync();
    });

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(const Duration(seconds: 30), (_) => _runSync());
  }

  void stop() {
    _connectivitySub?.cancel();
    _periodicTimer?.cancel();
    _connectivitySub = null;
    _periodicTimer = null;
  }

  // ── Public API ───────────────────────────────────────────────

  /// Trigger a manual sync. Returns {synced, rejected}.
  Future<Map<String, int>> syncNow() => _runSync();

  bool get isSyncing => _isSyncing;

  // ── Core sync logic ──────────────────────────────────────────

  Future<Map<String, int>> _runSync() async {
    if (_isSyncing) return {'synced': 0, 'rejected': 0};
    _isSyncing = true;

    try {
      final isOnline = await _connectivity.checkNow();
      if (!isOnline) {
        _isSyncing = false;
        return {'synced': 0, 'rejected': 0};
      }

      final pending = await _queue.getPendingBlobs();
      if (pending.isEmpty) {
        _isSyncing = false;
        await _queue.clearSettledOlderThan(7);
        return {'synced': 0, 'rejected': 0};
      }

      // Submit the batch
      final response = await _api.post('/api/offline/sync', {
        'blobs': pending.map((b) => b.toJson()).toList(),
      });

      int synced = 0;
      int rejected = 0;
      double limitToRestore = 0.0;

      final results = (response['results'] as List?) ?? [];
      for (final r in results) {
        final id = r['id'] as String?;
        final serverStatus = r['status'] as String? ?? 'rejected';

        if (id == null) continue;

        switch (serverStatus) {
          case 'accepted':
          case 'adjusted':
          // The counterparty synced this same blob first and the server has
          // now matched both halves. Settled — never an error, never a limit
          // restore.
          case 'confirmed':
          case 'duplicate': // already processed — treat as settled to stop re-submitting
            await _queue.updateStatus(id, BlobStatus.synced);
            synced++;
            break;
          case 'rejected':
            await _queue.updateStatus(id, BlobStatus.rejected);
            rejected++;
            // Restore the offline limit for the rejected blob
            final blob = pending.firstWhere(
              (b) => b.id == id,
              orElse: () => PaymentBlob(
                senderId: '', receiverId: '', amount: 0,
                isOffline: true, offlineLimitAtTime: 0,
              ),
            );
            // Only the SENDER deducted a limit for this blob. A received
            // blob (Case 3b) cost this device nothing, so there is nothing
            // to give back.
            if (blob.amount > 0 && !blob.isReceived) {
              limitToRestore += blob.amount;
            }
            break;
        }
      }

      // Restore limit for rejected blobs
      if (limitToRestore > 0) {
        final current = await _limitService.getAvailableLimit();
        final total = await _limitService.getTotalLimit();
        final restored = (current + limitToRestore).clamp(0.0, total);
        // Only restore the remaining balance — do NOT reset total or expiry
        await _limitService.updateRemainingOnly(restored);
      }

      // Feature B retry hook: if the key could not be registered at login
      // (airplane mode, backend asleep), catch up now that we are demonstrably
      // online. Cheap and idempotent — it short-circuits once registered.
      if (_currentUserId != null) {
        await DeviceEd25519Service().registerWithBackend(_currentUserId!);
      }

      // Fetch fresh limit from backend after sync
      await _limitService.fetchAndCacheLimit();

      // Clean up old settled blobs
      await _queue.clearSettledOlderThan(7);

      onSyncCompleted?.call(synced, rejected);
      _isSyncing = false;
      return {'synced': synced, 'rejected': rejected};
    } catch (e) {
      onSyncError?.call(e.toString());
      _isSyncing = false;
      return {'synced': 0, 'rejected': 0};
    }
  }
}
