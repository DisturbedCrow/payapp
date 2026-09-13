import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Feature I1 — the backend's GradientBoosting risk model, running on the
/// phone.
///
/// `assets/ml/risk_model.json` is written by `backend/scripts/export_model.py`
/// straight from the trained sklearn ensemble. This is an exact port of that
/// format (not a distilled approximation): walking the same 100 trees with
/// the same float32 comparisons gives the same probability sklearn does,
/// which `test/edge_risk_model_test.dart` checks against 71 parity vectors.
///
// PROD-TODO: replace the hand-port with an ONNX Runtime Mobile export.

/// Asset path of the exported model.
const String kRiskModelAsset = 'assets/ml/risk_model.json';

/// The seven inputs of the risk model, in the exact order the ensemble was
/// trained on.
class RiskFeatures {
  final double transactionCount;
  final double avgTransactionAmount;
  final double kycTier;
  final double deviceTrustScore;
  final double daysSinceRegistration;
  final double fraudFlags;
  final double totalSpent;

  const RiskFeatures({
    required this.transactionCount,
    required this.avgTransactionAmount,
    required this.kycTier,
    required this.deviceTrustScore,
    required this.daysSinceRegistration,
    required this.fraudFlags,
    required this.totalSpent,
  });

  /// Model feature order. `EdgeRiskModel.fromJson` refuses a model whose
  /// `feature_names` disagree, so a re-export can never silently shuffle it.
  static const List<String> names = [
    'transaction_count',
    'avg_transaction_amount',
    'kyc_tier',
    'device_trust_score',
    'days_since_registration',
    'fraud_flags',
    'total_spent',
  ];

  /// Parses the backend's `features` map. Throws [FormatException] when a key
  /// is missing or not numeric — use [tryParse] for untrusted payloads.
  factory RiskFeatures.fromJson(Map<String, dynamic> json) {
    double read(String key) {
      final v = json[key];
      if (v is num) return v.toDouble();
      if (v is String) {
        final parsed = double.tryParse(v);
        if (parsed != null) return parsed;
      }
      throw FormatException('risk feature "$key" missing or not numeric: $v');
    }

    return RiskFeatures(
      transactionCount: read('transaction_count'),
      avgTransactionAmount: read('avg_transaction_amount'),
      kycTier: read('kyc_tier'),
      deviceTrustScore: read('device_trust_score'),
      daysSinceRegistration: read('days_since_registration'),
      fraudFlags: read('fraud_flags'),
      totalSpent: read('total_spent'),
    );
  }

  /// `null` for anything that is not a complete feature map (an older
  /// backend that sends no `features`, a corrupt cache entry, ...).
  static RiskFeatures? tryParse(Object? raw) {
    if (raw is! Map) return null;
    try {
      return RiskFeatures.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'transaction_count': transactionCount,
        'avg_transaction_amount': avgTransactionAmount,
        'kyc_tier': kycTier,
        'device_trust_score': deviceTrustScore,
        'days_since_registration': daysSinceRegistration,
        'fraud_flags': fraudFlags,
        'total_spent': totalSpent,
      };

  /// The feature vector in model order.
  List<double> toVector() => [
        transactionCount,
        avgTransactionAmount,
        kycTier,
        deviceTrustScore,
        daysSinceRegistration,
        fraudFlags,
        totalSpent,
      ];

  @override
  bool operator ==(Object other) =>
      other is RiskFeatures && listEquals(other.toVector(), toVector());

  @override
  int get hashCode => Object.hashAll(toVector());
}

/// One regression tree of the ensemble, stored in flat typed arrays.
class _Tree {
  final Int32List left;
  final Int32List right;
  final Int32List feature;
  final Float64List threshold;
  final Float64List value;

  _Tree(this.left, this.right, this.feature, this.threshold, this.value);

  factory _Tree.fromJson(Map<String, dynamic> json) {
    Int32List ints(String k) =>
        Int32List.fromList((json[k] as List).map((e) => (e as num).toInt()).toList());
    Float64List doubles(String k) => Float64List.fromList(
        (json[k] as List).map((e) => (e as num).toDouble()).toList());

    final tree = _Tree(ints('left'), ints('right'), ints('feature'),
        doubles('threshold'), doubles('value'));
    final n = tree.left.length;
    if (tree.right.length != n ||
        tree.feature.length != n ||
        tree.threshold.length != n ||
        tree.value.length != n) {
      throw const FormatException('tree arrays have different lengths');
    }
    return tree;
  }
}

/// The exported sklearn `GradientBoostingClassifier` (binary, log-loss).
class EdgeRiskModel {
  final double learningRate;
  final double initRaw;
  final List<_Tree> _trees;

  /// `[threshold, limit]` pairs, checked top-down: the first tier whose
  /// threshold the score reaches gives the offline limit.
  final List<List<double>> tiers;

  /// sklearn `feature_importances_`, keyed by feature name.
  final Map<String, double> featureImportances;

  EdgeRiskModel._(this.learningRate, this.initRaw, this._trees, this.tiers,
      this.featureImportances);

  int get treeCount => _trees.length;

  factory EdgeRiskModel.fromJson(Map<String, dynamic> json) {
    final format = json['format'];
    if (format != 'sklearn-gbm-binary/v1') {
      throw FormatException('unsupported risk model format: $format');
    }
    final names = (json['feature_names'] as List).cast<String>();
    if (!listEquals(names, RiskFeatures.names)) {
      throw FormatException('risk model feature order changed: $names');
    }
    final trees = (json['trees'] as List)
        .map((t) => _Tree.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList(growable: false);
    final tiers = (json['tiers'] as List)
        .map((t) => (t as List).map((e) => (e as num).toDouble()).toList())
        .toList(growable: false);
    final importances = <String, double>{};
    final rawImp = json['feature_importances'];
    if (rawImp is Map) {
      rawImp.forEach((k, v) {
        if (v is num) importances[k.toString()] = v.toDouble();
      });
    }
    return EdgeRiskModel._(
      (json['learning_rate'] as num).toDouble(),
      (json['init_raw'] as num).toDouble(),
      trees,
      tiers,
      importances,
    );
  }

  static Future<EdgeRiskModel>? _loading;

  /// Loads (once) and caches the bundled model.
  static Future<EdgeRiskModel> load() {
    return _loading ??= _loadFromBundle().catchError((Object e) {
      _loading = null; // let a later call retry instead of caching a failure
      throw e;
    });
  }

  static Future<EdgeRiskModel> _loadFromBundle() async {
    final raw = await rootBundle.loadString(kRiskModelAsset);
    return EdgeRiskModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Test seam: makes [load] resolve to [model] (or reload from the bundle
  /// again when null).
  @visibleForTesting
  static void setForTesting(EdgeRiskModel? model) {
    _loading = model == null ? null : Future.value(model);
  }

  // Reused scratch cell for the float32 cast of each feature.
  final Float32List _f32 = Float32List(1);

  /// Probability of the "risky" class, exactly as sklearn's `predict_proba`.
  double score(RiskFeatures features) {
    final x = features.toVector();
    // sklearn's trees see X as float32 and compare it against float64
    // thresholds. Casting x here is what makes a value like 0.95 fall on the
    // same side of a split as it does on the server.
    final xf = Float64List(x.length);
    for (var i = 0; i < x.length; i++) {
      _f32[0] = x[i];
      xf[i] = _f32[0];
    }

    var raw = initRaw;
    for (final tree in _trees) {
      var node = 0;
      while (tree.left[node] != -1) {
        node = xf[tree.feature[node]] <= tree.threshold[node]
            ? tree.left[node]
            : tree.right[node];
      }
      raw += learningRate * tree.value[node];
    }
    return 1.0 / (1.0 + math.exp(-raw));
  }

  /// This model's tier table applied to [score].
  double limitFor(double score) => limitForScore(score, tiers);

  /// Maps a risk score to an offline limit with a `[[threshold, limit], ...]`
  /// table ordered from the highest threshold down. Mirrors the backend's
  /// `compute_offline_limit`.
  static double limitForScore(double score, List<List<double>> tiers) {
    for (final tier in tiers) {
      if (score >= tier[0]) return tier[1];
    }
    return tiers.isEmpty ? 0.0 : tiers.last[1];
  }
}
