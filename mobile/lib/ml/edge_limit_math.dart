import 'dart:math' as math;

import 'edge_risk_model.dart';

/// Feature I2 — offline exposure on top of the trust model.
///
/// The GBM has no inputs for offline context (and is saturated for a trusted
/// user: the stage sender scores 0.0004), so live deltas fed into its seven
/// features would change nothing. Instead the edge engine adds an explicit
/// exposure term for what only the phone can see:
///
///   edgeScore = clamp(gbm(cachedFeatures) + offlineExposure, 0, 1)
///   offlineExposure = 0.22 * pendingUnsyncedSent
///                   + min(0.03 * hoursSinceLastSync, 0.15)
///                   + min(offlineAmountLastHour / 5000 * 0.1, 0.1)
///   cap       = min(serverTotalLimit, limitForScore(edgeScore))
///   remaining = min(currentRemaining, cap)
///
/// The server-issued limit is the ceiling: on-device repricing only ever
/// moves the limit DOWN.
class EdgeLimitConfig {
  static const double exposurePerPendingPayment = 0.22;
  static const double exposurePerHourOffline = 0.03;
  static const double maxSyncAgeExposure = 0.15;
  static const double amountScaleRupees = 5000.0;
  static const double amountExposureWeight = 0.1;
  static const double maxAmountExposure = 0.1;

  /// Below this, exposure is "~0" and the trust model baseline is the story.
  static const double negligibleExposure = 0.01;

  /// Only the last N reprices are kept in the edge model feed.
  static const int feedSize = 20;

  /// Label of the model the engine runs, matching the backend's `model`.
  static const String modelName = 'gbm-v1';
}

/// Everything the edge computation needs, gathered from the device.
class EdgeLimitInputs {
  final RiskFeatures features;
  final int pendingSentCount;
  final double offlineAmountLastHour;
  final double hoursSinceLastSync;
  final double serverTotalLimit;
  final double currentRemaining;

  const EdgeLimitInputs({
    required this.features,
    required this.pendingSentCount,
    required this.offlineAmountLastHour,
    required this.hoursSinceLastSync,
    required this.serverTotalLimit,
    required this.currentRemaining,
  });
}

/// The three offline-exposure contributions.
class OfflineExposure {
  final double pending;
  final double syncAge;
  final double amount;

  const OfflineExposure({
    required this.pending,
    required this.syncAge,
    required this.amount,
  });

  factory OfflineExposure.of({
    required int pendingSentCount,
    required double hoursSinceLastSync,
    required double offlineAmountLastHour,
  }) {
    final hours = math.max(0.0, hoursSinceLastSync);
    final amount = math.max(0.0, offlineAmountLastHour);
    return OfflineExposure(
      pending: EdgeLimitConfig.exposurePerPendingPayment *
          math.max(0, pendingSentCount),
      syncAge: math.min(EdgeLimitConfig.exposurePerHourOffline * hours,
          EdgeLimitConfig.maxSyncAgeExposure),
      amount: math.min(
          amount /
              EdgeLimitConfig.amountScaleRupees *
              EdgeLimitConfig.amountExposureWeight,
          EdgeLimitConfig.maxAmountExposure),
    );
  }

  double get total => pending + syncAge + amount;
}

/// Result of one edge computation.
class EdgeLimitResult {
  final double baselineScore;
  final OfflineExposure exposure;
  final double score;

  /// The tier limit for [score], before the server ceiling.
  final double edgeLimit;

  /// `min(serverTotalLimit, edgeLimit)`.
  final double cap;

  /// `min(currentRemaining, cap)` — the value written back.
  final double remaining;

  const EdgeLimitResult({
    required this.baselineScore,
    required this.exposure,
    required this.score,
    required this.edgeLimit,
    required this.cap,
    required this.remaining,
  });
}

/// Pure edge repricing: no IO, no clock.
EdgeLimitResult computeEdgeLimit(EdgeRiskModel model, EdgeLimitInputs inputs) {
  final baseline = model.score(inputs.features);
  final exposure = OfflineExposure.of(
    pendingSentCount: inputs.pendingSentCount,
    hoursSinceLastSync: inputs.hoursSinceLastSync,
    offlineAmountLastHour: inputs.offlineAmountLastHour,
  );
  final score = (baseline + exposure.total).clamp(0.0, 1.0).toDouble();
  final edgeLimit = model.limitFor(score);
  final cap = math.min(math.max(0.0, inputs.serverTotalLimit), edgeLimit);
  final remaining = math.max(0.0, math.min(inputs.currentRemaining, cap));
  return EdgeLimitResult(
    baselineScore: baseline,
    exposure: exposure,
    score: score,
    edgeLimit: edgeLimit,
    cap: cap,
    remaining: remaining,
  );
}
