import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ml/edge_risk_model.dart';
import 'api_service.dart';

/// Manages the user's AI/ML-assigned offline credit limit.
///
/// The limit is fetched from the backend when online and cached in
/// SharedPreferences. It expires after 24 hours — if expired and the
/// device is offline, the available limit becomes ₹0.
///
/// After each offline payment the remaining limit is decremented locally.
/// When the user syncs, the backend recalculates and pushes a new limit.
///
/// Feature I: alongside the limit it caches the seven risk-model inputs the
/// server scored (`risk_features_cache`) and when the device last heard from
/// the server (`last_sync_at`), so the on-device model can reprice the limit
/// while offline.
class OfflineLimitService {
  static final OfflineLimitService _instance = OfflineLimitService._internal();
  factory OfflineLimitService() => _instance;
  OfflineLimitService._internal();

  // SharedPreferences keys
  static const String _keyLimit = 'offline_limit';
  static const String _keyRemaining = 'offline_limit_remaining';
  static const String _keyExpiry = 'offline_limit_expiry';
  static const String keyRiskFeatures = 'risk_features_cache';
  static const String keyLastSyncAt = 'last_sync_at';

  static const Duration _limitTtl = Duration(hours: 24);

  final ApiService _api = ApiService();

  /// When the server last issued a limit or accepted a sync. Drives the
  /// dashboard's "from server · Ns ago" label.
  final ValueNotifier<DateTime?> lastSyncAt = ValueNotifier<DateTime?>(null);

  /// Bumped on every write to the cached limit or its remaining balance, so
  /// screens can repaint without polling. A sync saves the server's limit
  /// AFTER the edge engine has already repriced, so listening to the engine
  /// alone left the dashboard showing the offline number once back online.
  final ValueNotifier<int> limitChanged = ValueNotifier<int>(0);

  // ── Public API ────────────────────────────────────────────────

  /// Returns the currently available offline limit.
  /// Returns ₹0 if the cached limit has expired or was never fetched.
  Future<double> getAvailableLimit() async {
    final prefs = await SharedPreferences.getInstance();
    if (_isExpired(prefs)) return 0.0;
    return prefs.getDouble(_keyRemaining) ?? 0.0;
  }

  /// Returns the total limit (not decremented by usage).
  /// Returns ₹0 if expired.
  Future<double> getTotalLimit() async {
    final prefs = await SharedPreferences.getInstance();
    if (_isExpired(prefs)) return 0.0;
    return prefs.getDouble(_keyLimit) ?? 0.0;
  }

  /// Whether the cached limit is still valid (not expired).
  Future<bool> isLimitValid() async {
    final prefs = await SharedPreferences.getInstance();
    return !_isExpired(prefs);
  }

  /// Deducts [amount] from the locally cached remaining limit.
  /// Called immediately after each offline payment, before sync.
  Future<void> deductFromLimit(double amount) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getDouble(_keyRemaining) ?? 0.0;
    final updated = (current - amount).clamp(0.0, double.infinity);
    await prefs.setDouble(_keyRemaining, updated);
    limitChanged.value++;
  }

  /// Fetches the limit from the backend and caches it locally.
  /// Should be called whenever the device comes online.
  /// Returns the new limit, or null on failure.
  Future<double?> fetchAndCacheLimit() async {
    try {
      final response = await _api.get('/api/user/offline-limit');
      final limit = (response['limit'] ?? 0).toDouble();
      final expiryStr = response['expiry'] as String?;

      final expiry = expiryStr != null
          ? DateTime.parse(expiryStr)
          : DateTime.now().add(_limitTtl);

      await _saveLimit(limit, expiry);
      // An older backend sends no `features`: drop any stale copy so the edge
      // engine falls back to the flat penalty instead of scoring old inputs.
      await cacheRiskFeatures(response['features'], clearIfMissing: true);
      return limit;
    } catch (_) {
      return null;
    }
  }

  /// Saves a new limit (called after a successful sync when the backend
  /// pushes a recalculated limit). Updates total, remaining, and expiry.
  /// [features] is the server's risk-model input map, when it sent one.
  Future<void> updateLimitFromSync(
    double newLimit, {
    Map<String, dynamic>? features,
  }) async {
    final expiry = DateTime.now().add(_limitTtl);
    await _saveLimit(newLimit, expiry);
    if (features != null) await cacheRiskFeatures(features);
  }

  /// Updates only the remaining limit without touching the total or expiry.
  /// Used during sync to restore rejected-blob amounts locally before the
  /// fresh limit fetch overwrites everything.
  Future<void> updateRemainingOnly(double remaining) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyRemaining, remaining);
    limitChanged.value++;
  }

  /// Applies a local risk penalty to the remaining limit based on how many
  /// offline payments are already pending (unsynced). Each pending payment
  /// reduces the effective limit by 10%, floored at 30% of total.
  ///
  /// Feature I: superseded by `EdgeLimitEngine.repriceOffline`, which calls
  /// this as its fallback when no server features are cached.
  Future<void> applyLocalRiskPenalty(int pendingBlobCount) async {
    if (pendingBlobCount <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final total = prefs.getDouble(_keyLimit) ?? 0.0;
    final remaining = prefs.getDouble(_keyRemaining) ?? 0.0;

    // 10% reduction per pending payment, floored at 30% of total
    final penaltyFactor =
        (1.0 - pendingBlobCount * 0.1).clamp(0.3, 1.0);
    final penalizedCap = total * penaltyFactor;

    // Only reduce, never increase the remaining limit
    final adjusted = remaining.clamp(0.0, penalizedCap);
    await prefs.setDouble(_keyRemaining, adjusted);
    limitChanged.value++;
  }

  /// Resets remaining limit back to total (e.g. after all blobs are settled).
  Future<void> resetRemainingToTotal() async {
    final prefs = await SharedPreferences.getInstance();
    final total = prefs.getDouble(_keyLimit) ?? 0.0;
    await prefs.setDouble(_keyRemaining, total);
    limitChanged.value++;
  }

  // ── Feature I: edge-model context ─────────────────────────────

  /// Caches the server's risk-model inputs. Anything that is not a complete
  /// seven-feature map is ignored — or, with [clearIfMissing], removes the
  /// cached copy. Returns whether a feature set was stored.
  Future<bool> cacheRiskFeatures(Object? raw,
      {bool clearIfMissing = false}) async {
    final features = RiskFeatures.tryParse(raw);
    final prefs = await SharedPreferences.getInstance();
    if (features == null) {
      if (clearIfMissing) await prefs.remove(keyRiskFeatures);
      return false;
    }
    await prefs.setString(keyRiskFeatures, jsonEncode(features.toJson()));
    return true;
  }

  /// Fetches and caches only the risk-model inputs, leaving the limit and
  /// its remaining balance untouched. Login issues the limit through token
  /// issuance, which carries no features — without this the edge engine has
  /// nothing to score until the first sync, and a phone that logs in and goes
  /// straight to airplane mode silently falls back to the flat penalty.
  /// Never throws; returns whether features were stored.
  Future<bool> refreshRiskFeatures() async {
    try {
      final response = await _api.get('/api/user/offline-limit');
      return await cacheRiskFeatures(response['features'],
          clearIfMissing: true);
    } catch (_) {
      return false;
    }
  }

  /// The last risk-model inputs the server sent, or null (never fetched,
  /// older backend, corrupt entry).
  Future<RiskFeatures?> getCachedRiskFeatures() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyRiskFeatures);
      if (raw == null || raw.isEmpty) return null;
      return RiskFeatures.tryParse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// Records a successful round-trip with the server (limit issued or sync
  /// accepted).
  Future<void> markSynced([DateTime? at]) async {
    final when = at ?? DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyLastSyncAt, when.toUtc().toIso8601String());
    lastSyncAt.value = when;
  }

  /// When the server last issued a limit or accepted a sync, or null.
  Future<DateTime?> getLastSyncAt() async {
    DateTime? parsed;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyLastSyncAt);
      parsed = raw == null ? null : DateTime.tryParse(raw);
    } catch (_) {
      parsed = null;
    }
    if (parsed != lastSyncAt.value) lastSyncAt.value = parsed;
    return parsed;
  }

  // ── Private helpers ───────────────────────────────────────────

  bool _isExpired(SharedPreferences prefs) {
    final expiryStr = prefs.getString(_keyExpiry);
    if (expiryStr == null) return true;
    try {
      final expiry = DateTime.parse(expiryStr);
      return DateTime.now().isAfter(expiry);
    } catch (_) {
      return true;
    }
  }

  Future<void> _saveLimit(double limit, DateTime expiry) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyLimit, limit);
    await prefs.setDouble(_keyRemaining, limit);
    limitChanged.value++;
    await prefs.setString(_keyExpiry, expiry.toIso8601String());
    await markSynced();
  }
}
