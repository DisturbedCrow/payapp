import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/payment_blob.dart';
import '../services/limit_explanation_service.dart';
import '../services/offline_limit_service.dart';
import '../services/offline_queue_service.dart';
import 'edge_explainer.dart';
import 'edge_limit_math.dart';
import 'edge_risk_model.dart';

/// One on-device repricing of the offline limit — a row of the edge model
/// feed.
class EdgeReprice {
  /// Remaining offline limit before and after this run.
  final double oldLimit;
  final double newLimit;

  /// Tier limit of the edge score, and the server-issued ceiling.
  final double edgeLimit;
  final double serverLimit;

  final double score;
  final double baselineScore;
  final double exposure;

  final String topFactor;
  final String topFactorHi;

  /// What triggered the run: `payment`, `dashboard`, `sync`, ...
  final String reason;
  final DateTime at;

  // Inputs, kept so the offline explanation can be rebuilt in either language.
  final int pendingSentCount;
  final double hoursSinceLastSync;
  final double offlineAmountLastHour;
  final RiskFeatures features;

  const EdgeReprice({
    required this.oldLimit,
    required this.newLimit,
    required this.edgeLimit,
    required this.serverLimit,
    required this.score,
    required this.baselineScore,
    required this.exposure,
    required this.topFactor,
    required this.topFactorHi,
    required this.reason,
    required this.at,
    required this.pendingSentCount,
    required this.hoursSinceLastSync,
    required this.offlineAmountLastHour,
    required this.features,
  });

  /// `min(serverLimit, edgeLimit)` — the limit the edge engine allows now.
  double get cap => math.min(serverLimit, edgeLimit);

  String topFactorFor(String lang) => lang == 'hi' ? topFactorHi : topFactor;

  Map<String, dynamic> toJson() => {
        'type': 'edge_reprice',
        'old_limit': oldLimit,
        'new_limit': newLimit,
        'edge_limit': edgeLimit,
        'server_limit': serverLimit,
        'score': score,
        'baseline_score': baselineScore,
        'exposure': exposure,
        'top_factor': topFactor,
        'top_factor_hi': topFactorHi,
        'reason': reason,
        'at': at.toUtc().toIso8601String(),
        'pending_sent_count': pendingSentCount,
        'hours_since_last_sync': hoursSinceLastSync,
        'offline_amount_last_hour': offlineAmountLastHour,
        'features': features.toJson(),
        'model': EdgeLimitConfig.modelName,
      };

  /// null for anything unparseable, so one bad row never breaks the feed.
  static EdgeReprice? tryParse(Object? raw) {
    if (raw is! Map) return null;
    try {
      final j = Map<String, dynamic>.from(raw);
      double d(String k) => (j[k] as num).toDouble();
      final features = RiskFeatures.tryParse(j['features']);
      final at = DateTime.tryParse(j['at'] as String? ?? '');
      if (features == null || at == null) return null;
      return EdgeReprice(
        oldLimit: d('old_limit'),
        newLimit: d('new_limit'),
        edgeLimit: d('edge_limit'),
        serverLimit: d('server_limit'),
        score: d('score'),
        baselineScore: d('baseline_score'),
        exposure: d('exposure'),
        topFactor: j['top_factor'] as String? ?? '',
        topFactorHi: j['top_factor_hi'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        at: at,
        pendingSentCount: (j['pending_sent_count'] as num).toInt(),
        hoursSinceLastSync: d('hours_since_last_sync'),
        offlineAmountLastHour: d('offline_amount_last_hour'),
        features: features,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Feature I2 — "the AI runs where the network isn't".
///
/// Re-scores the offline limit on the phone: the bundled GBM on the last
/// features the server sent, plus an explicit offline-exposure term (see
/// [computeEdgeLimit]). The result can only lower the remaining limit; the
/// server-issued limit stays the ceiling.
class EdgeLimitEngine {
  static final EdgeLimitEngine _instance = EdgeLimitEngine._internal();
  factory EdgeLimitEngine() => _instance;
  EdgeLimitEngine._internal();

  static const String feedPrefsKey = 'edge_reprice_feed';

  /// Test seam: replaces the sqflite queue read.
  @visibleForTesting
  static Future<List<PaymentBlob>> Function()? pendingBlobsOverride;

  /// Test seam: replaces the clock.
  @visibleForTesting
  static DateTime Function()? nowOverride;

  final OfflineLimitService _limits = OfflineLimitService();

  /// The newest reprice (null until the engine has run on this device).
  final ValueNotifier<EdgeReprice?> latest = ValueNotifier<EdgeReprice?>(null);

  /// The last [EdgeLimitConfig.feedSize] reprices, newest first.
  final ValueNotifier<List<EdgeReprice>> feed =
      ValueNotifier<List<EdgeReprice>>(const []);

  DateTime? get lastRunAt => latest.value?.at;

  Future<void>? _loading;
  Future<void> _tail = Future<void>.value();

  DateTime _now() => (nowOverride ?? DateTime.now)();

  /// Loads the persisted feed once.
  Future<void> ensureLoaded() => _loading ??= _loadFeed();

  Future<void> _loadFeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(feedPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final rows = decoded
          .map(EdgeReprice.tryParse)
          .whereType<EdgeReprice>()
          .take(EdgeLimitConfig.feedSize)
          .toList(growable: false);
      // A run that finished while we were reading wins.
      if (feed.value.isEmpty && rows.isNotEmpty) {
        feed.value = rows;
        latest.value = rows.first;
      }
    } catch (_) {
      // A corrupt feed is just an empty feed.
    }
  }

  /// Reprices the offline limit on-device. Never throws; runs are serialised.
  ///
  /// Returns null when the engine could not run — no valid limit, no cached
  /// server features (older backend) or no model — in which case the flat
  /// `applyLocalRiskPenalty` is applied instead, exactly as before Feature I.
  Future<EdgeReprice?> repriceOffline({required String reason}) {
    final run = _tail.then((_) => _reprice(reason));
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<EdgeReprice?> _reprice(String reason) async {
    try {
      await ensureLoaded();

      final List<PaymentBlob> pending;
      try {
        pending = await (pendingBlobsOverride ??
            OfflineQueueService().getPendingBlobs)();
      } catch (_) {
        return null; // cannot see the queue: leave the limit alone
      }
      // Only money this device SENT is exposure; received blobs cost it
      // nothing.
      final sent = pending.where((b) => !b.isReceived).toList();

      if (!await _limits.isLimitValid()) return null;

      final features = await _limits.getCachedRiskFeatures();
      EdgeRiskModel? model;
      if (features != null) {
        try {
          model = await EdgeRiskModel.load();
        } catch (_) {
          model = null;
        }
      }
      if (features == null || model == null) {
        await _limits.applyLocalRiskPenalty(sent.length);
        return null;
      }

      final now = _now();
      final lastSync = await _limits.getLastSyncAt();
      final hours = lastSync == null
          ? 0.0
          : math.max(0.0, now.difference(lastSync).inMilliseconds / 3600000.0);
      final amountLastHour = sent
          .where((b) => now.difference(b.timestamp) <= const Duration(hours: 1))
          .fold<double>(0.0, (sum, b) => sum + b.amount);

      final serverTotal = await _limits.getTotalLimit();
      final current = await _limits.getAvailableLimit();

      final result = computeEdgeLimit(
        model,
        EdgeLimitInputs(
          features: features,
          pendingSentCount: sent.length,
          offlineAmountLastHour: amountLastHour,
          hoursSinceLastSync: hours,
          serverTotalLimit: serverTotal,
          currentRemaining: current,
        ),
      );
      await _limits.updateRemainingOnly(result.remaining);

      String factor(String lang) => edgeTopFactor(
            exposure: result.exposure,
            pendingSentCount: sent.length,
            hoursSinceLastSync: hours,
            offlineAmountLastHour: amountLastHour,
            features: features,
            lang: lang,
          );

      final entry = EdgeReprice(
        oldLimit: current,
        newLimit: result.remaining,
        edgeLimit: result.edgeLimit,
        serverLimit: serverTotal,
        score: result.score,
        baselineScore: result.baselineScore,
        exposure: result.exposure.total,
        topFactor: factor('en'),
        topFactorHi: factor('hi'),
        reason: reason,
        at: now,
        pendingSentCount: sent.length,
        hoursSinceLastSync: hours,
        offlineAmountLastHour: amountLastHour,
        features: features,
      );
      await _record(entry);
      return entry;
    } catch (e) {
      debugPrint('EdgeLimitEngine: reprice failed ($e)');
      return null;
    }
  }

  Future<void> _record(EdgeReprice entry) async {
    final rows = [entry, ...feed.value].take(EdgeLimitConfig.feedSize).toList(
          growable: false,
        );
    feed.value = rows;
    latest.value = entry;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        feedPrefsKey,
        jsonEncode(rows.map((r) => r.toJson()).toList()),
      );
    } catch (_) {
      // The in-memory feed still shows it.
    }
  }

  /// The offline "Why this limit?" copy built from the newest reprice, or
  /// null when the server has spoken since (its own explanation is then the
  /// fresher truth) or the engine has never run.
  Future<LimitExplanation?> offlineExplanation(String lang) async {
    try {
      await ensureLoaded();
      final r = latest.value;
      if (r == null) return null;
      final serverAt = await _limits.getLastSyncAt();
      if (serverAt != null && serverAt.isAfter(r.at)) return null;

      Map<String, double> importances = const {};
      try {
        importances = (await EdgeRiskModel.load()).featureImportances;
      } catch (_) {}

      final text = explainEdgeLimit(
        limit: r.cap,
        features: r.features,
        pendingSentCount: r.pendingSentCount,
        hoursSinceLastSync: r.hoursSinceLastSync,
        offlineAmountLastHour: r.offlineAmountLastHour,
        importances: importances,
        lang: lang,
      );
      return LimitExplanation(
        headline: text.headline,
        body: text.body,
        tip: text.tip,
        lang: lang == 'hi' ? 'hi' : 'en',
        generatedBy: LimitExplanation.onDevice,
        limit: r.cap,
        riskScore: r.score,
        generatedAt: r.at,
      );
    } catch (_) {
      return null;
    }
  }

  /// Clears memory (not prefs) so a test can reload from a fresh store.
  @visibleForTesting
  void resetForTesting() {
    _loading = null;
    _tail = Future<void>.value();
    feed.value = const [];
    latest.value = null;
  }
}
