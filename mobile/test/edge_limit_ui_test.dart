// Feature I3 — the badge sub-label and the edge model feed sheet.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:offline_pay/ml/edge_limit_engine.dart';
import 'package:offline_pay/ml/edge_risk_model.dart';
import 'package:offline_pay/widgets/edge_limit_source_label.dart';
import 'package:offline_pay/widgets/edge_model_feed_sheet.dart';

const _ashmita = RiskFeatures(
  transactionCount: 214,
  avgTransactionAmount: 340,
  kycTier: 3,
  deviceTrustScore: 0.95,
  daysSinceRegistration: 420,
  fraudFlags: 0,
  totalSpent: 72760,
);

EdgeReprice _reprice(DateTime at, {double from = 4800, double to = 3000}) =>
    EdgeReprice(
      oldLimit: from,
      newLimit: to,
      edgeLimit: 3000,
      serverLimit: 5000,
      score: 0.2274,
      baselineScore: 0.000418,
      exposure: 0.227,
      topFactor: '1 unsynced offline payment',
      topFactorHi: '1 offline payment sync baaki',
      reason: 'payment',
      at: at,
      pendingSentCount: 1,
      hoursSinceLastSync: 0.1,
      offlineAmountLastHour: 200,
      features: _ashmita,
    );

void main() {
  final t0 = DateTime.utc(2026, 9, 13, 10, 0, 0);

  group('describeLimitSource', () {
    test('edge run newer than the server -> computed on-device', () {
      expect(
        describeLimitSource(
          edgeAt: t0,
          serverAt: t0.subtract(const Duration(minutes: 5)),
          now: t0.add(const Duration(seconds: 2)),
        ),
        'computed on-device · 2s ago',
      );
    });

    test('server newer than the last edge run -> from server', () {
      expect(
        describeLimitSource(
          edgeAt: t0,
          serverAt: t0.add(const Duration(seconds: 10)),
          now: t0.add(const Duration(seconds: 17)),
        ),
        'from server · 7s ago',
      );
    });

    test('minutes, hours, days and nothing known', () {
      expect(formatAgo(const Duration(minutes: 4, seconds: 30)), '4m ago');
      expect(formatAgo(const Duration(hours: 3)), '3h ago');
      expect(formatAgo(const Duration(days: 2)), '2d ago');
      expect(formatAgo(const Duration(seconds: -3)), '0s ago');
      expect(describeLimitSource(now: t0), '');
    });
  });

  testWidgets('sub-label ticks and switches source', (tester) async {
    var now = t0;
    final edge = ValueNotifier<EdgeReprice?>(null);
    final server = ValueNotifier<DateTime?>(null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EdgeLimitSourceLabel(
          edge: edge,
          server: server,
          clock: () => now,
        ),
      ),
    ));
    expect(find.byType(Text), findsNothing);

    // Advance the clock BEFORE changing a notifier: the label computes its
    // text inside the listener, at the moment the value changes.
    now = t0.add(const Duration(seconds: 3));
    server.value = t0;
    await tester.pump();
    expect(find.text('from server · 3s ago'), findsOneWidget);

    now = t0.add(const Duration(seconds: 5));
    edge.value = _reprice(t0.add(const Duration(seconds: 5)));
    await tester.pump();
    expect(find.text('computed on-device · 0s ago'), findsOneWidget);

    // The 1 s ticker refreshes the relative time on its own.
    now = t0.add(const Duration(seconds: 7));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('computed on-device · 2s ago'), findsOneWidget);

    // Dispose so the periodic timer is cancelled before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('edge model feed lists reprices newest first', (tester) async {
    final feed = ValueNotifier<List<EdgeReprice>>([
      _reprice(t0.add(const Duration(minutes: 1)), from: 2750, to: 1500),
      _reprice(t0),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: EdgeModelFeedSheet(feed: feed)),
    ));

    expect(find.text('Edge model feed'), findsOneWidget);
    final rows = tester
        .widgetList<Text>(find.textContaining('→'))
        .map((t) => t.data)
        .toList();
    expect(rows, ['₹2,750 → ₹1,500', '₹4,800 → ₹3,000']);
    expect(find.text('1 unsynced offline payment'), findsNWidgets(2));
    expect(find.textContaining('score 0.227'), findsNWidgets(2));
  });

  testWidgets('empty feed explains how to fill it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EdgeModelFeedSheet(
          feed: ValueNotifier<List<EdgeReprice>>(const []),
          lang: 'hi',
        ),
      ),
    ));
    expect(find.textContaining('No on-device reprices yet'), findsOneWidget);
  });
}
