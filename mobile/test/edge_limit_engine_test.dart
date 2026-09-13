// Feature I2 — on-device repricing of the offline limit.
//
// The model is read from disk; the sqflite queue and the clock are replaced
// through the engine's test seams, and SharedPreferences is the mock store.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:offline_pay/ml/edge_explainer.dart';
import 'package:offline_pay/ml/edge_limit_engine.dart';
import 'package:offline_pay/ml/edge_limit_math.dart';
import 'package:offline_pay/ml/edge_risk_model.dart';
import 'package:offline_pay/models/payment_blob.dart';
import 'package:offline_pay/services/offline_limit_service.dart';

/// The stage sender, exactly as seeded.
const ashmita = RiskFeatures(
  transactionCount: 214,
  avgTransactionAmount: 340,
  kycTier: 3,
  deviceTrustScore: 0.95,
  daysSinceRegistration: 420,
  fraudFlags: 0,
  totalSpent: 72760,
);

final _now = DateTime.utc(2026, 9, 13, 10, 0, 0);

PaymentBlob _sent(double amount, {int minutesAgo = 2, bool received = false}) =>
    PaymentBlob(
      senderId: 'ashmita',
      receiverId: 'jyati',
      amount: amount,
      isOffline: true,
      offlineLimitAtTime: 5000,
      timestamp: _now.subtract(Duration(minutes: minutesAgo)),
      direction: received ? BlobDirection.received : BlobDirection.sent,
    );

/// A valid ₹[limit] server limit, synced 6 minutes (0.1 h) before [_now].
Map<String, Object> _prefs({
  double limit = 5000,
  double? remaining,
  bool withFeatures = true,
}) =>
    {
      'offline_limit': limit,
      'offline_limit_remaining': remaining ?? limit,
      'offline_limit_expiry':
          DateTime.now().add(const Duration(hours: 20)).toIso8601String(),
      if (withFeatures)
        OfflineLimitService.keyRiskFeatures: jsonEncode(ashmita.toJson()),
      OfflineLimitService.keyLastSyncAt:
          _now.subtract(const Duration(minutes: 6)).toIso8601String(),
    };

void main() {
  late EdgeRiskModel model;
  var pending = <PaymentBlob>[];

  setUpAll(() {
    model = EdgeRiskModel.fromJson(
      jsonDecode(File('assets/ml/risk_model.json').readAsStringSync())
          as Map<String, dynamic>,
    );
  });

  setUp(() {
    pending = [];
    EdgeRiskModel.setForTesting(model);
    EdgeLimitEngine.nowOverride = () => _now;
    EdgeLimitEngine.pendingBlobsOverride = () async => pending;
    EdgeLimitEngine().resetForTesting();
    SharedPreferences.setMockInitialValues(_prefs());
  });

  tearDown(() {
    EdgeLimitEngine.nowOverride = null;
    EdgeLimitEngine.pendingBlobsOverride = null;
    EdgeRiskModel.setForTesting(null);
    EdgeLimitEngine().resetForTesting();
  });

  EdgeLimitResult compute({
    int pendingCount = 0,
    double amount = 0,
    double hours = 0.1,
    double server = 5000,
    double remaining = 5000,
  }) =>
      computeEdgeLimit(
        model,
        EdgeLimitInputs(
          features: ashmita,
          pendingSentCount: pendingCount,
          offlineAmountLastHour: amount,
          hoursSinceLastSync: hours,
          serverTotalLimit: server,
          currentRemaining: remaining,
        ),
      );

  group('exposure tiers for the stage sender (pure)', () {
    test('0 pending -> ₹5,000', () {
      final r = compute();
      expect(r.baselineScore, closeTo(0.000418, 1e-6));
      expect(r.edgeLimit, 5000.0);
      expect(r.remaining, 5000.0);
    });

    test('1 pending, ₹200 in the last hour, 0.1 h since sync -> ₹3,000', () {
      final r = compute(pendingCount: 1, amount: 200);
      expect(r.exposure.total, closeTo(0.22 + 0.003 + 0.004, 1e-9));
      expect(r.score, closeTo(0.2274, 1e-3));
      expect(r.edgeLimit, 3000.0);
      expect(r.remaining, 3000.0);
    });

    test('2 pending, ₹450 -> ₹1,500', () {
      final r = compute(pendingCount: 2, amount: 450);
      expect(r.score, closeTo(0.4524, 1e-3));
      expect(r.edgeLimit, 1500.0);
      expect(r.remaining, 1500.0);
    });

    test('sync-age and amount terms are capped', () {
      final e = OfflineExposure.of(
          pendingSentCount: 0, hoursSinceLastSync: 100, offlineAmountLastHour: 1e6);
      expect(e.syncAge, 0.15);
      expect(e.amount, 0.1);
      expect(OfflineExposure.of(
              pendingSentCount: 0, hoursSinceLastSync: -5, offlineAmountLastHour: 0)
          .total, 0.0);
    });

    test('score is clamped to 1 and maps to ₹0', () {
      final r = compute(pendingCount: 6, amount: 5000, hours: 10);
      expect(r.score, 1.0);
      expect(r.remaining, 0.0);
    });
  });

  group('server limit is the ceiling', () {
    test('never above the server-issued limit', () {
      final r = compute(server: 1000, remaining: 5000);
      expect(r.edgeLimit, 5000.0);
      expect(r.cap, 1000.0);
      expect(r.remaining, 1000.0);
    });

    test('never raises the remaining limit', () {
      final r = compute(remaining: 800);
      expect(r.remaining, 800.0);
    });

    test('engine with a ₹1,000 server limit stays at or below it', () async {
      SharedPreferences.setMockInitialValues(_prefs(limit: 1000));
      final r = await EdgeLimitEngine().repriceOffline(reason: 'dashboard');
      expect(r, isNotNull);
      expect(r!.newLimit, lessThanOrEqualTo(1000.0));
      expect(r.cap, 1000.0);
      expect(await OfflineLimitService().getAvailableLimit(), 1000.0);
    });
  });

  group('EdgeLimitEngine.repriceOffline', () {
    test('stage sequence: ₹5,000 -> pay ₹200 -> ₹3,000 -> pay ₹250 -> ₹1,500',
        () async {
      final engine = EdgeLimitEngine();
      final limits = OfflineLimitService();

      final r0 = await engine.repriceOffline(reason: 'dashboard');
      expect(r0!.newLimit, 5000.0);
      expect(r0.topFactor, 'trust model baseline (KYC 3, 214 txns)');

      pending = [_sent(200)];
      await limits.deductFromLimit(200);
      final r1 = await engine.repriceOffline(reason: 'payment');
      expect(r1!.oldLimit, 4800.0);
      expect(r1.edgeLimit, 3000.0);
      expect(r1.newLimit, 3000.0);
      expect(r1.offlineAmountLastHour, 200.0);
      expect(r1.hoursSinceLastSync, closeTo(0.1, 1e-9));
      expect(r1.topFactor, '1 unsynced offline payment');
      expect(await limits.getAvailableLimit(), 3000.0);

      // A received blob and an old sent one: the received blob is not
      // exposure; the old one counts as pending but not as last-hour spend.
      pending = [
        _sent(200),
        _sent(250, minutesAgo: 1),
        _sent(1000, received: true),
      ];
      await limits.deductFromLimit(250);
      final r2 = await engine.repriceOffline(reason: 'payment');
      expect(r2!.pendingSentCount, 2);
      expect(r2.offlineAmountLastHour, 450.0);
      expect(r2.oldLimit, 2750.0);
      expect(r2.newLimit, 1500.0);
      expect(r2.topFactor, '2 unsynced offline payments');
      expect(r2.topFactorHi, '2 offline payments sync baaki');
      expect(await limits.getAvailableLimit(), 1500.0);
      // The server total is untouched: sync restores it.
      expect(await limits.getTotalLimit(), 5000.0);

      expect(engine.feed.value.map((r) => r.newLimit), [1500.0, 3000.0, 5000.0]);
      expect(engine.latest.value, same(r2));
      expect(engine.lastRunAt, _now);
    });

    test('spend older than an hour is not last-hour exposure', () async {
      pending = [_sent(900, minutesAgo: 90)];
      final r = await EdgeLimitEngine().repriceOffline(reason: 'payment');
      expect(r!.offlineAmountLastHour, 0.0);
      expect(r.pendingSentCount, 1);
    });

    test('no cached features -> null and the old flat penalty', () async {
      SharedPreferences.setMockInitialValues(_prefs(withFeatures: false));
      pending = [_sent(200)];

      final r = await EdgeLimitEngine().repriceOffline(reason: 'payment');

      expect(r, isNull);
      // applyLocalRiskPenalty(1): capped at 90% of ₹5,000.
      expect(await OfflineLimitService().getAvailableLimit(), 4500.0);
      expect(EdgeLimitEngine().feed.value, isEmpty);
    });

    test('an expired limit is left alone', () async {
      SharedPreferences.setMockInitialValues({
        ..._prefs(),
        'offline_limit_expiry':
            DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
      });
      expect(await EdgeLimitEngine().repriceOffline(reason: 'payment'), isNull);
    });

    test('a queue read failure never throws', () async {
      EdgeLimitEngine.pendingBlobsOverride = () async => throw StateError('db');
      expect(await EdgeLimitEngine().repriceOffline(reason: 'payment'), isNull);
    });

    test('feed keeps the newest 20 and survives a restart', () async {
      final engine = EdgeLimitEngine();
      for (var i = 0; i < 23; i++) {
        await engine.repriceOffline(reason: 'run$i');
      }
      expect(engine.feed.value.length, EdgeLimitConfig.feedSize);
      expect(engine.feed.value.first.reason, 'run22');

      engine.resetForTesting();
      expect(engine.feed.value, isEmpty);
      await engine.ensureLoaded();
      expect(engine.feed.value.length, 20);
      expect(engine.feed.value.first.reason, 'run22');
      expect(engine.latest.value!.reason, 'run22');
      expect(engine.latest.value!.features, ashmita);
    });
  });

  group('OfflineLimitService feature cache', () {
    test('updateLimitFromSync stores features and last_sync_at', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = OfflineLimitService();
      final before = DateTime.now().subtract(const Duration(seconds: 1));

      await svc.updateLimitFromSync(3000, features: ashmita.toJson());

      expect(await svc.getTotalLimit(), 3000.0);
      expect(await svc.getCachedRiskFeatures(), ashmita);
      final at = await svc.getLastSyncAt();
      expect(at, isNotNull);
      expect(at!.isAfter(before), isTrue);
      expect(svc.lastSyncAt.value, at);
    });

    test('markSynced round-trips through prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = OfflineLimitService();
      await svc.markSynced(_now);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(OfflineLimitService.keyLastSyncAt),
          '2026-09-13T10:00:00.000Z');
      expect(await svc.getLastSyncAt(), _now);
    });

    test('an incomplete feature map is ignored, or clears when asked',
        () async {
      final svc = OfflineLimitService();
      expect(await svc.cacheRiskFeatures({'kyc_tier': 3}), isFalse);
      expect(await svc.getCachedRiskFeatures(), ashmita); // untouched

      expect(await svc.cacheRiskFeatures(null, clearIfMissing: true), isFalse);
      expect(await svc.getCachedRiskFeatures(), isNull);
    });

    test('a corrupt cache entry reads as no features', () async {
      SharedPreferences.setMockInitialValues(
          {OfflineLimitService.keyRiskFeatures: '{not json'});
      expect(await OfflineLimitService().getCachedRiskFeatures(), isNull);
    });
  });

  group('topFactor', () {
    String factor(int pendingCount, double hours, double amount,
            [String lang = 'en']) =>
        edgeTopFactor(
          exposure: OfflineExposure.of(
            pendingSentCount: pendingCount,
            hoursSinceLastSync: hours,
            offlineAmountLastHour: amount,
          ),
          pendingSentCount: pendingCount,
          hoursSinceLastSync: hours,
          offlineAmountLastHour: amount,
          features: ashmita,
          lang: lang,
        );

    test('unsynced payments', () {
      expect(factor(2, 0.1, 450), '2 unsynced offline payments');
      expect(factor(1, 0.1, 200), '1 unsynced offline payment');
      expect(factor(2, 0.1, 450, 'hi'), '2 offline payments sync baaki');
      expect(factor(1, 0.1, 200, 'hi'), '1 offline payment sync baaki');
    });

    test('hours since last sync', () {
      expect(factor(0, 3, 0), '3 h since last sync');
      expect(factor(0, 3, 0, 'hi'), '3 ghante se sync nahi');
      expect(factor(0, 0.5, 0), '30 min since last sync');
    });

    test('offline spend in the last hour', () {
      expect(factor(0, 0, 4500), '₹4,500 spent offline in the last hour');
      expect(factor(0, 0, 4500, 'hi'), 'pichle ghante ₹4,500 offline kharch');
    });

    test('exposure ~0 -> trust model baseline', () {
      expect(factor(0, 0.1, 0), 'trust model baseline (KYC 3, 214 txns)');
      expect(factor(0, 0.1, 0, 'hi'),
          'trust model baseline (KYC 3, 214 payments)');
    });
  });

  group('offline explanation (MockExplainer port)', () {
    test('rupees() uses Indian digit grouping', () {
      expect(rupees(500), '₹500');
      expect(rupees(5000), '₹5,000');
      expect(rupees(72760), '₹72,760');
      expect(rupees(100000), '₹1,00,000');
      expect(rupees(12345678), '₹1,23,45,678');
    });

    test('EN names the strongest positive and the offline negative', () {
      final t = explainEdgeLimit(
        limit: 3000,
        features: ashmita,
        pendingSentCount: 1,
        hoursSinceLastSync: 0.1,
        offlineAmountLastHour: 200,
        importances: model.featureImportances,
      );
      expect(t.headline, 'Your offline limit: ₹3,000');
      expect(t.body, contains('₹3,000'));
      expect(t.body, contains('no payment has ever been flagged'));
      expect(t.body, contains('1 payment is still waiting to sync'));
      expect(t.tip, contains('syncing your pending payments'));
    });

    test('HI (Hinglish) variant', () {
      final t = explainEdgeLimit(
        limit: 1500,
        features: ashmita,
        pendingSentCount: 2,
        hoursSinceLastSync: 0.1,
        offlineAmountLastHour: 450,
        importances: model.featureImportances,
        lang: 'hi',
      );
      expect(t.headline, 'Aapki offline limit: ₹1,500');
      expect(t.body, contains('aaj tak koi payment flag nahi hui'));
      expect(t.body, contains('2 payments abhi sync hone ka wait kar rahi hain'));
      expect(t.tip, contains('pending payments sync'));
    });

    test('nothing against the user reads like the server template', () {
      final t = explainEdgeLimit(
        limit: 5000,
        features: ashmita,
        pendingSentCount: 0,
        hoursSinceLastSync: 0.1,
        offlineAmountLastHour: 0,
        importances: model.featureImportances,
      );
      expect(t.body, contains('nothing is currently working against you'));
    });

    test('₹0 is framed as paused', () {
      final t = explainEdgeLimit(
        limit: 0,
        features: ashmita,
        pendingSentCount: 5,
        hoursSinceLastSync: 1,
        offlineAmountLastHour: 1000,
      );
      expect(t.headline, 'Offline pay is paused for now');
      expect(t.body, contains('5 payments are still waiting to sync'));
    });

    test('engine builds it from the newest reprice until the server speaks',
        () async {
      pending = [_sent(200)];
      await EdgeLimitEngine().repriceOffline(reason: 'payment');

      final e = await EdgeLimitEngine().offlineExplanation('en');
      expect(e, isNotNull);
      expect(e!.isOnDevice, isTrue);
      expect(e.headline, 'Your offline limit: ₹3,000');

      await OfflineLimitService().markSynced(_now.add(const Duration(minutes: 1)));
      expect(await EdgeLimitEngine().offlineExplanation('en'), isNull);
    });
  });
}
