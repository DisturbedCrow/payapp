// Feature I1 — parity between the on-device port and sklearn.
//
// Both JSON files are read straight from disk (flutter test runs with
// cwd = mobile/), so this checks the exact bytes that ship in the APK.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/ml/edge_risk_model.dart';

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  late EdgeRiskModel model;
  late Map<String, dynamic> parity;

  setUpAll(() {
    model = EdgeRiskModel.fromJson(_readJson('assets/ml/risk_model.json'));
    parity = _readJson('assets/ml/parity_vectors.json');
  });

  test('loads the full exported ensemble', () {
    expect(model.treeCount, 100);
    expect(model.tiers.first, [0.9, 0.0]);
    expect(model.tiers.last, [0.0, 5000.0]);
  });

  test('every parity vector matches sklearn to 1e-6 and lands in its tier', () {
    final vectors = (parity['vectors'] as List).cast<Map<String, dynamic>>();
    final tolerance = (parity['tolerance'] as num).toDouble();
    expect(vectors.length, greaterThanOrEqualTo(71));

    var maxDiff = 0.0;
    var worst = '';
    for (final v in vectors) {
      final features =
          RiskFeatures.fromJson(Map<String, dynamic>.from(v['features'] as Map));
      final expected = (v['expected_score'] as num).toDouble();
      final got = model.score(features);
      final diff = (got - expected).abs();
      if (diff > maxDiff) {
        maxDiff = diff;
        worst = v['name'] as String;
      }

      expect(diff, lessThanOrEqualTo(tolerance), reason: v['name'] as String);
      expect(diff, lessThanOrEqualTo(1e-6),
          reason: '${v['name']}: got $got, sklearn $expected');
      expect(
        EdgeRiskModel.limitForScore(got, model.tiers),
        (v['expected_limit'] as num).toDouble(),
        reason: v['name'] as String,
      );
    }
    // ignore: avoid_print
    print('edge parity: ${vectors.length} vectors, max |diff| = '
        '${maxDiff.toStringAsExponential(2)} ($worst)');
  });

  test('the stage sender scores ~0.0004 -> ₹5,000', () {
    const ashmita = RiskFeatures(
      transactionCount: 214,
      avgTransactionAmount: 340,
      kycTier: 3,
      deviceTrustScore: 0.95,
      daysSinceRegistration: 420,
      fraudFlags: 0,
      totalSpent: 72760,
    );
    final p = model.score(ashmita);
    expect(p, closeTo(0.00041769087284378626, 1e-9));
    expect(model.limitFor(p), 5000.0);
  });

  test('limitForScore respects tier boundaries top-down', () {
    final t = model.tiers;
    expect(EdgeRiskModel.limitForScore(0.0, t), 5000.0);
    expect(EdgeRiskModel.limitForScore(0.2 - 1e-9, t), 5000.0);
    expect(EdgeRiskModel.limitForScore(0.2, t), 3000.0);
    expect(EdgeRiskModel.limitForScore(0.4, t), 1500.0);
    expect(EdgeRiskModel.limitForScore(0.6, t), 500.0);
    expect(EdgeRiskModel.limitForScore(0.8, t), 100.0);
    expect(EdgeRiskModel.limitForScore(0.9, t), 0.0);
    expect(EdgeRiskModel.limitForScore(1.0, t), 0.0);
  });

  test('RiskFeatures round-trips and orders its vector like the model', () {
    final f = RiskFeatures.fromJson({
      'transaction_count': 214,
      'avg_transaction_amount': 340.0,
      'kyc_tier': 3,
      'device_trust_score': 0.95,
      'days_since_registration': 420,
      'fraud_flags': 0,
      'total_spent': 72760,
    });
    expect(RiskFeatures.fromJson(jsonDecode(jsonEncode(f.toJson()))), f);
    expect(f.toVector(), [214.0, 340.0, 3.0, 0.95, 420.0, 0.0, 72760.0]);
    expect(RiskFeatures.tryParse({'transaction_count': 1}), isNull);
    expect(RiskFeatures.tryParse(null), isNull);
  });

  test('rejects a model whose feature order changed', () {
    final json = _readJson('assets/ml/risk_model.json');
    json['feature_names'] = (json['feature_names'] as List).reversed.toList();
    expect(() => EdgeRiskModel.fromJson(json), throwsFormatException);
  });
}
