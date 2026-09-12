// Feature G — parser gate. Pure Dart, no Flutter bindings, no plugins.
//
//   flutter test test/voice_intent_parser_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/config/constants.dart';
import 'package:offline_pay/services/voice_intent_parser.dart';

/// Resolves the parsed recipientQuery to a single contact id, or null.
String? _resolveId(PayIntent intent) {
  final q = intent.recipientQuery;
  if (q == null) return null;
  final matches = resolveRecipient(q);
  return matches.isEmpty ? null : matches.first.id;
}

const String rameshId = 'f30ca7a5-cc00-5efb-a792-e136e834a7aa';
const String vivekId = 'a7f6c445-d25b-5ae0-b382-e2a6144d9549';

void main() {
  group('parse() — the demo-day utterance matrix', () {
    test('"ramesh ko do sau rupaye bhejo" -> 200 / ramesh (NOT 250)', () {
      final r = parse('ramesh ko do sau rupaye bhejo');
      expect(r.amount, 200);
      expect(r.recipientQuery, 'ramesh');
      expect(_resolveId(r), rameshId);
      expect(r.confidence, 1.0);
    });

    test('"ramesh ko do sau pachas bhejo" -> 250 / ramesh', () {
      final r = parse('ramesh ko do sau pachas bhejo');
      expect(r.amount, 250);
      expect(r.recipientQuery, 'ramesh');
      expect(_resolveId(r), rameshId);
    });

    test('"send 200 rupees to ramesh" -> 200 / ramesh', () {
      final r = parse('send 200 rupees to ramesh');
      expect(r.amount, 200);
      expect(r.recipientQuery, 'ramesh');
      expect(_resolveId(r), rameshId);
      expect(r.confidence, 1.0);
    });

    test('"ramesh ko ₹500 bhej do" -> 500 / ramesh', () {
      final r = parse('ramesh ko ₹500 bhej do');
      expect(r.amount, 500);
      expect(r.recipientQuery, 'ramesh');
      expect(_resolveId(r), rameshId);
    });

    test('"paanch sau ramesh" -> 500 / ramesh (no verb)', () {
      final r = parse('paanch sau ramesh');
      expect(r.amount, 500);
      expect(r.recipientQuery, 'ramesh');
      expect(_resolveId(r), rameshId);
      expect(r.confidence, closeTo(0.75, 0.001));
    });

    test('"dhai sau ramesh ko" -> 250 / ramesh', () {
      final r = parse('dhai sau ramesh ko');
      expect(r.amount, 250);
      expect(r.recipientQuery, 'ramesh');
      expect(_resolveId(r), rameshId);
    });

    test('Devanagari: "रमेश को दो '
        'सौ रुपये भेजो" '
        '-> 200 / ramesh', () {
      final r = parse('रमेश को दो सौ रुपये भेजो');
      expect(r.amount, 200);
      expect(r.recipientQuery, 'रमेश');
      expect(_resolveId(r), rameshId);
      expect(r.confidence, 1.0);
    });

    test('"transfer two fifty to ramesh" -> 250', () {
      final r = parse('transfer two fifty to ramesh');
      expect(r.amount, 250);
      expect(r.recipientQuery, 'ramesh');
      expect(_resolveId(r), rameshId);
    });

    test('"do hazaar ramesh ko bhejo" -> 2000', () {
      final r = parse('do hazaar ramesh ko bhejo');
      expect(r.amount, 2000);
      expect(r.recipientQuery, 'ramesh');
      expect(_resolveId(r), rameshId);
    });

    test('empty transcript -> null amount, confidence 0, no throw', () {
      final r = parse('');
      expect(r.amount, isNull);
      expect(r.confidence, 0.0);
      expect(r.transcript, '');
      expect(r.recipientQuery, isNull);
    });

    test('gibberish "asdf qwer zxcv" -> null amount, no throw', () {
      final r = parse('asdf qwer zxcv');
      expect(r.amount, isNull);
      expect(r.confidence, 0.0);
    });
  });

  group('parse() — amount forms', () {
    test('digits without a currency word', () {
      expect(parse('ramesh ko 350 bhejo').amount, 350);
    });

    test('rupee sign already spaced', () {
      expect(parse('₹ 750 vivek ko').amount, 750);
    });

    test('rs prefix glued to digits', () {
      expect(parse('rs1200 ramesh ko bhejo').amount, 1200);
    });

    test('decimal amount survives', () {
      expect(parse('ramesh ko 99.50 rupaye bhejo').amount, closeTo(99.5, 0.001));
    });

    test('Indian digit grouping 1,000 is one number', () {
      expect(parse('ramesh ko 1,000 rupaye bhejo').amount, 1000);
    });

    test('Devanagari digits २०० -> 200', () {
      expect(parse('रमेश को २०० रुपये भेजो').amount, 200);
    });

    test('trailing punctuation does not break the parse', () {
      final r = parse('Ramesh ko, do sau rupaye bhejo!');
      expect(r.amount, 200);
      expect(r.recipientQuery, 'ramesh');
    });

    test('"do sau" is 200 and "do hazaar" is 2000', () {
      expect(parse('do sau').amount, 200);
      expect(parse('do hazaar').amount, 2000);
    });

    test('compound with trailing tens', () {
      expect(parse('teen sau bees ramesh ko bhejo').amount, 320);
      expect(parse('paanch sau pachas').amount, 550);
    });

    test('fractional prefixes', () {
      expect(parse('dhai sau').amount, 250);
      expect(parse('dedh sau').amount, 150);
      expect(parse('sava sau').amount, 125);
      expect(parse('dhai hazaar').amount, 2500);
      expect(parse('dedh hazaar').amount, 1500);
      expect(parse('adha sau').amount, 50);
    });

    test('Devanagari fractional ढाई सौ -> 250', () {
      expect(parse('रमेश को ढाई सौ रुपये भेजो').amount, 250);
    });

    test('Devanagari nukta folding: हज़ार -> 1000', () {
      expect(parse('रमेश को दो हज़ार रुपये भेजो').amount, 2000);
    });

    test('English hundred compounds', () {
      expect(parse('two hundred fifty to ramesh').amount, 250);
      expect(parse('five hundred to ramesh').amount, 500);
      expect(parse('two hundred and fifty to ramesh').amount, 250);
    });

    test('tens-then-unit stays additive (twenty five = 25)', () {
      expect(parse('twenty five rupees to ramesh').amount, 25);
    });

    test('saat/saath ambiguity: bare form prefers 7', () {
      expect(parse('ramesh ko saath rupaye bhejo').amount, 7);
      expect(parse('ramesh ko saat rupaye bhejo').amount, 7);
    });

    test('saat/saath ambiguity: after a multiplier it is 60', () {
      expect(parse('do sau saath ramesh ko bhejo').amount, 260);
    });

    test('"bhej do" tail is a verb, never the number two', () {
      expect(parse('ramesh ko 500 bhej do').amount, 500);
      expect(parse('ramesh ko paanch sau de do').amount, 500);
    });

    test('digits win over spelled-out words when both appear', () {
      expect(parse('ramesh ko 300 rupaye do sau bhejo').amount, 300);
    });

    test('zero amount is treated as no amount', () {
      final r = parse('ramesh ko zero rupaye bhejo');
      expect(r.amount, isNull);
      expect(r.confidence, 0.0);
    });
  });

  group('parse() — recipient extraction', () {
    test('"ko" takes the token before it', () {
      expect(parse('vivek ko sau rupaye bhejo').recipientQuery, 'vivek');
    });

    test('"to" takes the token after it', () {
      expect(parse('pay 100 to vivek').recipientQuery, 'vivek');
    });

    test('two-word names survive', () {
      expect(
        parse('ramesh kirana ko do sau bhejo').recipientQuery,
        'ramesh kirana',
      );
    });

    test('no marker -> first non-number/verb/currency token', () {
      expect(parse('paanch sau vivek').recipientQuery, 'vivek');
    });

    test('recipient may be missing entirely', () {
      final r = parse('do sau rupaye bhejo');
      expect(r.amount, 200);
      expect(r.recipientQuery, isNull);
      expect(r.confidence, closeTo(0.75, 0.001));
    });
  });

  group('parse() — confidence', () {
    test('amount + recipient + verb = 1.0', () {
      expect(parse('ramesh ko do sau rupaye bhejo').confidence, 1.0);
    });

    test('missing verb drops 0.25', () {
      expect(parse('ramesh ko do sau rupaye').confidence, closeTo(0.75, 0.001));
    });

    test('missing recipient and verb drops 0.5', () {
      expect(parse('do sau rupaye').confidence, closeTo(0.5, 0.001));
    });

    test('no amount is always 0.0', () {
      expect(parse('ramesh ko bhejo').confidence, 0.0);
    });
  });

  group('parse() — robustness (must never throw)', () {
    final nasty = <String>[
      '',
      '   ',
      '\n\t',
      '!!!',
      '...',
      ',',
      '₹',
      'rs',
      '0',
      '00000',
      '999999999999999999999',
      'ko to ko to',
      'do do do do',
      'bhej do bhej do',
      'ramesh',
      'रमेश',
      'सौ',
      'a' * 500,
      '1,2,3,4,5',
      '12.34.56',
      'ramesh ko -200 bhejo',
      'ramesh ko 200.999 bhejo',
      '😀 ramesh ko 200 bhejo 🚀',
    ];
    for (final s in nasty) {
      test('does not throw on ${s.length > 24 ? '${s.substring(0, 24)}…' : '"$s"'}',
          () {
        expect(() => parse(s), returnsNormally);
        final r = parse(s);
        expect(r.confidence, inInclusiveRange(0.0, 1.0));
        expect(r.transcript, isNotNull);
      });
    }

    test('emoji are stripped but the payment survives', () {
      final r = parse('😀 ramesh ko 200 bhejo 🚀');
      expect(r.amount, 200);
      expect(r.recipientQuery, 'ramesh');
    });

    test('normaliseTranscript is idempotent', () {
      const raw = 'Ramesh KO, ₹500 bhej do!!';
      final once = normaliseTranscript(raw);
      expect(normaliseTranscript(once), once);
      expect(once, 'ramesh ko ₹ 500 bhej do');
    });
  });

  group('resolveRecipient()', () {
    test('exact alias', () {
      final m = resolveRecipient('ramesh');
      expect(m, isNotEmpty);
      expect(m.first.id, rameshId);
      expect(m.first.name, 'Ramesh Kirana');
      expect(m.first.score, 1.0);
    });

    test('exact multi-word alias', () {
      final m = resolveRecipient('ramesh kirana');
      expect(m.first.id, rameshId);
      expect(m.first.score, 1.0);
    });

    test('prefix match "ram"', () {
      final m = resolveRecipient('ram');
      expect(m, isNotEmpty);
      expect(m.first.id, rameshId);
      expect(m.first.score, greaterThan(0.8));
    });

    test('typo within Levenshtein 2: "rmesh"', () {
      final m = resolveRecipient('rmesh');
      expect(m, isNotEmpty);
      expect(m.first.id, rameshId);
    });

    test('typo within Levenshtein 2: "vivk"', () {
      final m = resolveRecipient('vivk');
      expect(m, isNotEmpty);
      expect(m.first.id, vivekId);
    });

    test('Devanagari alias resolves', () {
      expect(resolveRecipient('रमेश').first.id, rameshId);
      expect(resolveRecipient('विवेक').first.id, vivekId);
    });

    test('no match -> empty list', () {
      expect(resolveRecipient('zzzzqqqq'), isEmpty);
      expect(resolveRecipient('bhattacharya'), isEmpty);
      expect(resolveRecipient(''), isEmpty);
      expect(resolveRecipient('   '), isEmpty);
    });

    test('results are sorted by score descending', () {
      final m = resolveRecipient('ramesh');
      for (var i = 1; i < m.length; i++) {
        expect(m[i - 1].score, greaterThanOrEqualTo(m[i].score));
      }
    });

    test('recent payees are searched too', () {
      final m = resolveRecipient(
        'sunita',
        contacts: const <String, DemoContact>{},
        recent: const [RecentPayee(id: 'recent-1', name: 'Sunita Devi')],
      );
      expect(m, isNotEmpty);
      expect(m.first.id, 'recent-1');
    });

    test('a custom contact table can be injected', () {
      final m = resolveRecipient(
        'gita',
        contacts: const {
          'gita': DemoContact(id: 'g1', name: 'Gita Stores', aliases: ['gita']),
        },
      );
      expect(m.single.id, 'g1');
    });

    test('one contact is never returned twice', () {
      final m = resolveRecipient('ramesh kirana');
      final ids = m.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('levenshtein()', () {
    test('known distances', () {
      expect(levenshtein('', ''), 0);
      expect(levenshtein('abc', 'abc'), 0);
      expect(levenshtein('', 'abc'), 3);
      expect(levenshtein('abc', ''), 3);
      expect(levenshtein('rmesh', 'ramesh'), 1);
      expect(levenshtein('kitten', 'sitting'), 3);
      expect(levenshtein('ramesh', 'vivek'), greaterThan(2));
    });

    test('is symmetric', () {
      expect(levenshtein('ramesh', 'rmesh'), levenshtein('rmesh', 'ramesh'));
    });
  });

  group('end-to-end: transcript -> intent -> resolved recipient', () {
    const utterances = <String, double>{
      'ramesh ko do sau rupaye bhejo': 200,
      'ramesh ko do sau pachas bhejo': 250,
      'send 200 rupees to ramesh': 200,
      'ramesh ko ₹500 bhej do': 500,
      'paanch sau ramesh': 500,
      'dhai sau ramesh ko': 250,
      'रमेश को दो सौ रुपये भेजो': 200,
      'transfer two fifty to ramesh': 250,
      'do hazaar ramesh ko bhejo': 2000,
    };

    utterances.forEach((utterance, expected) {
      test('"$utterance" resolves to Ramesh for ₹$expected', () {
        final intent = parse(utterance);
        expect(intent.amount, expected);
        expect(intent.recipientQuery, isNotNull);
        final matches = resolveRecipient(intent.recipientQuery!);
        expect(matches, isNotEmpty);
        expect(matches.first.id, rameshId);
      });
    });
  });
}
