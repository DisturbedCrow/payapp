// Feature D — GenAI risk explainer (mobile side).
//
// Nothing here touches the network: LimitExplanationService.onlineCheckOverride
// forces the "offline" branch, so every case is deterministic and fast.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:offline_pay/config/constants.dart';
import 'package:offline_pay/services/limit_explanation_service.dart';
import 'package:offline_pay/widgets/limit_explanation_card.dart';

// ── Fixtures: real responses captured from the live backend ──────────────
//   TOK=$(curl -s -X POST http://127.0.0.1:8000/api/auth/login \
//     -H 'Content-Type: application/json' \
//     -d '{"email":"vivek@demo.com","password":"password123"}' | jq -r .access_token)
//   curl -s "http://127.0.0.1:8000/api/user/limit-explanation?lang=en" \
//     -H "Authorization: Bearer $TOK"
const String kRealEnResponse = r'''
{"headline":"Your offline limit: ₹5,000","body":"Right now you can spend ₹5,000 without a network. That is because no payment has ever been flagged while nothing is currently working against you.","tip":"Sync once a day and complete your KYC — those two lift the limit fastest.","limit":5000.0,"risk_score":0.0004,"lang":"en","generated_by":"template","cached":false,"generated_at":"2026-09-12T14:58:48.610868Z"}
''';

//   curl -s "http://127.0.0.1:8000/api/user/limit-explanation?lang=hi" ...
const String kRealHiResponse = r'''
{"headline":"Aapki offline limit: ₹5,000","body":"Bina network ke aap abhi ₹5,000 kharch kar sakte hain. Kyunki aaj tak koi payment flag nahi hui jabki aur koi risk signal nahi hai.","tip":"Din mein ek baar sync kariye aur KYC poora kariye — limit sabse tezi se inhi se badhti hai.","limit":5000.0,"risk_score":0.0004,"lang":"hi","generated_by":"template","cached":false,"generated_at":"2026-09-12T14:58:48.625319Z"}
''';

// Same shape, hand-edited to the LLM branch (the backend emits this once an
// API key is configured) so the "AI" badge path is covered.
const String kRealLlmResponse = r'''
{"headline":"Your offline limit: ₹5,000","body":"You can spend up to ₹5,000 with no network because your payment history is clean.","tip":"Finish KYC to unlock a higher ceiling.","limit":5000,"risk_score":0.0004,"lang":"en","generated_by":"llm","cached":true,"generated_at":"2026-09-12T14:58:48.610868Z"}
''';

const String kEnHeadline = 'Your offline limit: ₹5,000';
const String kHiHeadline = 'Aapki offline limit: ₹5,000';
const String kFetchedAt = '2026-09-12T14:58:48.610868Z';

Map<String, dynamic> _decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

/// The exact blob the service writes to SharedPreferences: a language-keyed
/// map of cache entries under [AppConstants.limitExplanationCacheKey].
String _cacheBlob({bool en = true, bool hi = true}) {
  final entries = <String, dynamic>{};
  if (en) {
    entries['en'] = {
      ..._decode(kRealEnResponse),
      'fetched_at': kFetchedAt,
    };
  }
  if (hi) {
    entries['hi'] = {
      ..._decode(kRealHiResponse),
      'fetched_at': kFetchedAt,
    };
  }
  return jsonEncode(entries);
}

Widget _host({ValueChanged<String>? onLangChanged}) {
  return MaterialApp(
    home: Scaffold(
      body: Column(
        children: [LimitExplanationCard(onLangChanged: onLangChanged)],
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Order matters: drop the singleton's in-memory copy first, then install
    // a fresh empty prefs store.
    LimitExplanationService().resetMemory();
    LimitExplanationService.onlineCheckOverride = () async => false;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    LimitExplanationService.onlineCheckOverride = null;
    LimitExplanationService().resetMemory();
  });

  // ── Model ───────────────────────────────────────────────────────────

  group('LimitExplanation.fromJson', () {
    test('parses the real EN backend response', () {
      final e = LimitExplanation.fromJson(_decode(kRealEnResponse));

      expect(e.headline, kEnHeadline);
      expect(
        e.body,
        'Right now you can spend ₹5,000 without a network. That is because no '
        'payment has ever been flagged while nothing is currently working '
        'against you.',
      );
      expect(e.tip, contains('complete your KYC'));
      expect(e.limit, 5000.0);
      expect(e.riskScore, closeTo(0.0004, 1e-9));
      expect(e.lang, 'en');
      expect(e.generatedBy, 'template');
      expect(e.isAiGenerated, isFalse);
      expect(e.fromCache, isFalse);
    });

    test('parses the real HI backend response', () {
      final e = LimitExplanation.fromJson(_decode(kRealHiResponse));

      expect(e.headline, kHiHeadline);
      expect(e.body, startsWith('Bina network ke aap abhi ₹5,000'));
      expect(e.tip, contains('KYC poora kariye'));
      expect(e.lang, 'hi');
      expect(e.limit, 5000.0);
    });

    test('flags the LLM branch and tolerates an int limit', () {
      final e = LimitExplanation.fromJson(_decode(kRealLlmResponse));

      expect(e.generatedBy, 'llm');
      expect(e.isAiGenerated, isTrue);
      expect(e.limit, 5000.0); // arrived as an int
    });

    test('generatedAt is our fetch time, not the backend generated_at', () {
      final before = DateTime.now();
      final e = LimitExplanation.fromJson(_decode(kRealEnResponse));

      // The backend stamp is 2026-09-12T14:58:48Z; ours must be "now".
      expect(e.generatedAt.isBefore(before.subtract(const Duration(minutes: 1))),
          isFalse);
      expect(
        e.generatedAt
            .isAfter(DateTime.now().add(const Duration(minutes: 1))),
        isFalse,
      );
    });

    test('a cache entry keeps its stored fetched_at', () {
      final e = LimitExplanation.fromJson({
        ..._decode(kRealEnResponse),
        'fetched_at': kFetchedAt,
      }, fromCache: true);

      expect(e.generatedAt.toUtc(), DateTime.parse(kFetchedAt).toUtc());
      expect(e.fromCache, isTrue);
    });

    test('does not throw on a sparse / malformed payload', () {
      final e = LimitExplanation.fromJson(<String, dynamic>{'headline': 'x'});

      expect(e.headline, 'x');
      expect(e.body, '');
      expect(e.limit, 0.0);
      expect(e.lang, 'en');
      expect(e.generatedBy, 'template');
    });
  });

  group('LimitExplanation round-trip', () {
    test('toJson/fromJson preserves every field', () {
      final original = LimitExplanation.fromJson({
        ..._decode(kRealHiResponse),
        'fetched_at': kFetchedAt,
      }, fromCache: true);

      final restored = LimitExplanation.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
        fromCache: true,
      );

      expect(restored.headline, original.headline);
      expect(restored.body, original.body);
      expect(restored.tip, original.tip);
      expect(restored.lang, original.lang);
      expect(restored.generatedBy, original.generatedBy);
      expect(restored.limit, original.limit);
      expect(restored.riskScore, original.riskScore);
      expect(restored.generatedAt.toUtc(), original.generatedAt.toUtc());
      expect(restored.fromCache, isTrue);
    });
  });

  // ── Service ─────────────────────────────────────────────────────────

  group('LimitExplanationService', () {
    test('offline with no cache resolves to null instead of hanging', () async {
      final result = await LimitExplanationService()
          .load()
          .timeout(const Duration(seconds: 5));

      expect(result, isNull);
    });

    test('offline serves the cache, marked fromCache', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: _cacheBlob(),
        AppConstants.explainerLangKey: 'en',
      });
      LimitExplanationService().resetMemory();

      final result = await LimitExplanationService()
          .load()
          .timeout(const Duration(seconds: 5));

      expect(result, isNotNull);
      expect(result!.headline, kEnHeadline);
      expect(result.fromCache, isTrue);
    });

    test('switching language offline reads the other language cache',
        () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: _cacheBlob(),
        AppConstants.explainerLangKey: 'en',
      });
      final service = LimitExplanationService()..resetMemory();

      expect((await service.load())!.headline, kEnHeadline);

      await service.setLang('hi');
      expect(await service.getLang(), 'hi');
      expect((await service.load())!.headline, kHiHeadline);
    });

    test('clear() wipes both the memory copy and prefs', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: _cacheBlob(),
        AppConstants.explainerLangKey: 'hi',
      });
      final service = LimitExplanationService()..resetMemory();
      expect(await service.cached(), isNotNull);

      await service.clear();

      expect(await service.cached(), isNull);
      expect(await service.getLang(), 'en');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.limitExplanationCacheKey), isNull);
    });

    test('a corrupt cache entry is treated as no cache', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: 'not json at all',
      });
      LimitExplanationService().resetMemory();

      expect(await LimitExplanationService().cached(lang: 'en'), isNull);
      expect(await LimitExplanationService().load(), isNull);
    });
  });

  // ── Widget ──────────────────────────────────────────────────────────

  group('LimitExplanationCard', () {
    testWidgets('no cache and no network renders nothing and does not throw',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      LimitExplanationService().resetMemory();

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(LimitExplanationCard)), Size.zero);
      // "Never a spinner that cannot resolve."
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('renders the headline from a seeded prefs cache',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: _cacheBlob(),
        AppConstants.explainerLangKey: 'en',
      });
      LimitExplanationService().resetMemory();

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(find.text(kEnHeadline), findsOneWidget);
      expect(tester.getSize(find.byType(LimitExplanationCard)).height,
          greaterThan(0));
      // Served from cache -> the subtle "as of h:mm a" stamp is shown.
      expect(find.textContaining('as of '), findsOneWidget);
      // template copy must NOT be labelled on stage.
      expect(find.text('AI'), findsNothing);
    });

    testWidgets('tapping the headline expands the body and tip',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: _cacheBlob(),
        AppConstants.explainerLangKey: 'en',
      });
      LimitExplanationService().resetMemory();

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final collapsed =
          tester.getSize(find.byType(LimitExplanationCard)).height;

      await tester.tap(find.text(kEnHeadline));
      await tester.pumpAndSettle();

      final expanded =
          tester.getSize(find.byType(LimitExplanationCard)).height;

      expect(expanded, greaterThan(collapsed));
      expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
      expect(find.textContaining('complete your KYC'), findsOneWidget);
    });

    testWidgets('the EN | हिं toggle switches to the cached Hindi copy',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: _cacheBlob(),
        AppConstants.explainerLangKey: 'en',
      });
      LimitExplanationService().resetMemory();

      final langs = <String>[];
      await tester.pumpWidget(_host(onLangChanged: langs.add));
      await tester.pumpAndSettle();
      expect(find.text(kEnHeadline), findsOneWidget);

      await tester.tap(find.text('हिं'));
      await tester.pumpAndSettle();

      expect(find.text(kHiHeadline), findsOneWidget);
      expect(find.text(kEnHeadline), findsNothing);
      expect(langs, ['hi']);
      // The choice is persisted for the next launch.
      expect(await LimitExplanationService().getLang(), 'hi');
    });

    testWidgets('refresh() resolves offline without throwing', (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: _cacheBlob(),
        AppConstants.explainerLangKey: 'en',
      });
      LimitExplanationService().resetMemory();

      final key = GlobalKey<LimitExplanationCardState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(children: [LimitExplanationCard(key: key)]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await key.currentState!.refresh().timeout(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(kEnHeadline), findsOneWidget);
    });

    testWidgets('shows the AI badge only for llm-generated copy',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.limitExplanationCacheKey: jsonEncode({
          'en': {..._decode(kRealLlmResponse), 'fetched_at': kFetchedAt},
        }),
        AppConstants.explainerLangKey: 'en',
      });
      LimitExplanationService().resetMemory();

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(find.text('AI'), findsOneWidget);
    });
  });
}
