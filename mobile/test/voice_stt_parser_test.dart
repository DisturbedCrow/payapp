// Feature G2 — the parser reads cloud STT output: Gnani's ITN writes money as
// "₹250" / "₹1,500" / "₹1,50,000" and may hand us the amount as an entity.
//
//   flutter test test/voice_stt_parser_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/config/constants.dart';
import 'package:offline_pay/services/stt/stt_engine.dart';
import 'package:offline_pay/services/voice_intent_parser.dart';

String? payeeOf(PayIntent intent) {
  final q = intent.recipientQuery;
  if (q == null) return null;
  final matches = resolveRecipient(q, contacts: AppConstants.demoContacts);
  return matches.isEmpty ? null : matches.first.name;
}

void main() {
  group('parse() — ITN money and Devanagari digits', () {
    test('"ramesh ko 250 rupaye bhejo" -> 250 to Ramesh', () {
      final i = parse('ramesh ko 250 rupaye bhejo');
      expect(i.amount, 250);
      expect(payeeOf(i), 'Ramesh Kirana');
      expect(i.confidence, 1.0);
    });

    test('"send ₹1,500 to ramesh" -> 1500 to Ramesh', () {
      final i = parse('send ₹1,500 to ramesh');
      expect(i.amount, 1500);
      expect(payeeOf(i), 'Ramesh Kirana');
    });

    test('"रमेश को ₹२५० भेजो" -> 250 to Ramesh', () {
      final i = parse('रमेश को ₹२५० भेजो');
      expect(i.amount, 250);
      expect(payeeOf(i), 'Ramesh Kirana');
    });

    test('Indian lakh grouping "₹1,50,000" -> 150000', () {
      expect(parse('ramesh ko ₹1,50,000 bhejo').amount, 150000);
    });

    test('ten-lakh grouping "₹10,00,000" -> 1000000', () {
      expect(parse('ramesh ko ₹10,00,000 bhejo').amount, 1000000);
    });

    test('Western grouping "1,500,000" -> 1500000', () {
      expect(parse('send 1,500,000 to ramesh').amount, 1500000);
    });

    test('grouping plus decimals "₹1,500.50" -> 1500.5', () {
      expect(parse('send ₹1,500.50 to ramesh').amount, 1500.5);
    });

    test('Devanagari digits with grouping "₹१,५००" -> 1500', () {
      expect(parse('रमेश को ₹१,५०० भेजो').amount, 1500);
    });

    test('"Rs. 500" and "rs.500" and "Rs500"', () {
      expect(parse('Rs. 500 ramesh ko bhejo').amount, 500);
      expect(parse('rs.500 ramesh ko bhejo').amount, 500);
      expect(parse('Rs500 to ramesh').amount, 500);
    });

    test('"Rs." is not taken as the payee', () {
      expect(payeeOf(parse('Rs. 500 ramesh ko bhejo')), 'Ramesh Kirana');
    });

    test('a sentence-final comma is not grouping: "ramesh ko 250, bhejo"', () {
      expect(parse('ramesh ko 250, bhejo').amount, 250);
    });

    test('existing Hindi number words are unaffected', () {
      expect(parse('ramesh ko dhai sau bhejo').amount, 250);
      expect(parse('रमेश को दो हज़ार रुपये भेजो').amount, 2000);
      expect(parse('ramesh ko do sau pachas bhejo').amount, 250);
    });
  });

  // Live Gnani Prisma output for the spoken "जयति को दो सौ पचास रुपये भेजो".
  group('live Gnani output for the stage payee Jyati', () {
    const jyatiId = '8061253a-e03b-538b-a8b5-75194294fec1';

    String? payeeIdOf(PayIntent intent) {
      final q = intent.recipientQuery;
      if (q == null) return null;
      final m = resolveRecipient(q, contacts: AppConstants.demoContacts);
      return m.isEmpty ? null : m.first.id;
    }

    test('ITN transcript "जयती को ₹250 भेजो" -> ₹250 to Jyati', () {
      final i = parse('जयती को ₹250 भेजो');
      expect(i.amount, 250);
      expect(payeeIdOf(i), jyatiId);
    });

    test('verbatim "जयती को दो सौ पचास रुपए भेजो" -> ₹250 to Jyati', () {
      final i = parse('जयती को दो सौ पचास रुपए भेजो');
      expect(i.amount, 250);
      expect(payeeIdOf(i), jyatiId);
    });

    test('SttResult with amount entity -> ₹250 to Jyati', () {
      final i = parseResult(const SttResult(
        transcript: 'जयती को ₹250 भेजो',
        amountEntity: 250,
        provider: 'gnani',
      ));
      expect(i.amount, 250);
      expect(payeeIdOf(i), jyatiId);
      expect(i.provider, 'gnani');
    });
  });

  group('parseResult(SttResult)', () {
    test('amountEntity overrides the digits in the transcript', () {
      final i = parseResult(const SttResult(
        transcript: 'ramesh ko 25 rupaye bhejo',
        amountEntity: 250,
        provider: SttProvider.gnani,
        lang: 'hi-IN',
        latencyMs: 640,
      ));
      expect(i.amount, 250);
      expect(payeeOf(i), 'Ramesh Kirana');
      expect(i.confidence, 1.0);
      expect(i.provider, SttProvider.gnani);
    });

    test('amountEntity fills an amount the transcript lacks', () {
      final i = parseResult(const SttResult(
        transcript: 'ramesh ko paise bhejo',
        amountEntity: 1500,
        provider: SttProvider.gnani,
      ));
      expect(i.amount, 1500);
      expect(i.confidence, 1.0);
    });

    test('null amountEntity falls back to the transcript', () {
      final i = parseResult(const SttResult(
        transcript: 'send ₹1,500 to ramesh',
        provider: SttProvider.mock,
      ));
      expect(i.amount, 1500);
      expect(i.provider, SttProvider.mock);
    });

    test('a zero or negative amountEntity is ignored', () {
      for (final bad in [0.0, -250.0]) {
        final i = parseResult(SttResult(
          transcript: 'ramesh ko 300 bhejo',
          amountEntity: bad,
          provider: SttProvider.gnani,
        ));
        expect(i.amount, 300, reason: 'entity $bad');
      }
    });

    test('on-device result parses exactly like parse()', () {
      const t = 'रमेश को दो सौ रुपये भेजो';
      final a = parse(t);
      final b = parseResult(
          const SttResult(transcript: t, provider: SttProvider.onDevice));
      expect(b.amount, a.amount);
      expect(b.recipientQuery, a.recipientQuery);
      expect(b.confidence, a.confidence);
      expect(b.transcript, a.transcript);
      expect(b.provider, SttProvider.onDevice);
    });

    test('plain parse() carries no provider', () {
      expect(parse('ramesh ko 200 bhejo').provider, isNull);
    });
  });
}
