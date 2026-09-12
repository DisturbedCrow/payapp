// Integration check: transcript -> parse -> resolveRecipient, in the exact
// shapes Google's on-device recogniser emits for localeId 'hi_IN'.
//
// The parser and the resolver each have their own unit tests; this covers the
// seam between them plus the real AppConstants.demoContacts table, which is
// what actually runs on stage.
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/config/constants.dart';
import 'package:offline_pay/services/voice_intent_parser.dart';

({double? amount, String? payee}) run(String transcript) {
  final intent = parse(transcript);
  final matches = intent.recipientQuery == null
      ? const <ResolvedRecipient>[]
      : resolveRecipient(intent.recipientQuery!,
          contacts: AppConstants.demoContacts);
  return (
    amount: intent.amount,
    payee: matches.isEmpty ? null : matches.first.name,
  );
}

void main() {
  group('recogniser output -> payable intent', () {
    const cases = <String, double>{
      // Devanagari — what hi_IN actually returns
      'रमेश को दो सौ रुपये भेजो': 200,
      'रमेश को 200 रुपये भेजो': 200,
      'रमेश को ढाई सौ भेज दो': 250,
      'रमेश को दो हज़ार रुपये भेजो': 2000, // nukta form of हजार
      // Roman-Hinglish — the en_IN fallback locale
      'ramesh ko do sau rupaye bhejo': 200,
      'ramesh ko paanch sau bhejo': 500,
      'send 200 rupees to ramesh': 200,
    };

    cases.forEach((transcript, expected) {
      test('"$transcript" -> ₹$expected to Ramesh', () {
        final r = run(transcript);
        expect(r.amount, expected, reason: 'amount from "$transcript"');
        expect(r.payee, 'Ramesh Kirana', reason: 'payee from "$transcript"');
      });
    });

    test('a payee with no amount still resolves, so the confirm screen '
        'can ask for the amount instead of failing', () {
      final r = run('रमेश को');
      expect(r.amount, isNull);
      expect(r.payee, 'Ramesh Kirana');
    });

    // ── The stage pair: "Jyati ko do sau rupaye bhejo" ──────────────
    const jyatiCases = <String, double>{
      'ज्याति को दो सौ रुपये भेजो': 200,
      'ज्योति को दो सौ रुपये भेजो': 200,   // what hi_IN usually returns
      'jyati ko do sau rupaye bhejo': 200,
      'jyoti ko do sau rupaye bhejo': 200,
      'jyati ko ढाई सौ भेज दो': 250,
      'send 200 rupees to jyati': 200,
    };
    jyatiCases.forEach((transcript, expected) {
      test('"$transcript" -> Rs $expected to Jyati', () {
        final r = run(transcript);
        expect(r.amount, expected, reason: transcript);
        expect(r.payee, 'Jyati Kirana', reason: transcript);
      });
    });

    test('a one-letter mishearing still resolves via Levenshtein', () {
      expect(run('jyathi ko do sau bhejo').payee, 'Jyati Kirana');
    });

    test('a shared surname does not steal the other contact', () {
      // Jyati Kirana and Ramesh Kirana share a surname. Aliases must stay
      // distinguishing, or a full name resolves to the wrong payee.
      expect(run('ramesh kirana ko do sau bhejo').payee, 'Ramesh Kirana');
      expect(run('jyati kirana ko do sau bhejo').payee, 'Jyati Kirana');
    });

    test('an unrelated utterance yields nothing and does not throw', () {
      final r = run('नमस्ते कैसे हो');
      expect(r.amount, isNull);
      expect(r.payee, isNull);
    });
  });
}
