// Feature G6 — the LLM garnish must never be able to hurt the demo.
//
// Pure Dart: both network and connectivity are replaced by test seams, so
// nothing here touches a platform channel.
//
//   flutter test test/voice_intent_remote_test.dart

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/services/voice_intent_parser.dart';
import 'package:offline_pay/services/voice_intent_remote.dart';

/// Transcripts the override was asked to send. Empty == no network call.
late List<String> calls;

/// Installs a POST seam that records the transcript and answers [reply].
void respondWith(Map<String, dynamic> reply) {
  VoiceIntentRemote.postOverride = (transcript) async {
    calls.add(transcript);
    return reply;
  };
}

PayIntent localIntent({
  double? amount,
  String? recipient,
  required double confidence,
  String transcript = 'ramesh ko do sau bhejo',
}) =>
    PayIntent(
      amount: amount,
      recipientQuery: recipient,
      confidence: confidence,
      transcript: transcript,
    );

Map<String, dynamic> llmReply({
  Object? amount = 200,
  Object? recipient = 'ramesh',
  Object? confidence = 0.9,
  String parsedBy = 'llm',
}) =>
    {
      'amount': amount,
      'recipient_query': recipient,
      'confidence': confidence,
      'transcript': 'echoed by the server',
      'parsed_by': parsedBy,
    };

void main() {
  setUp(() {
    calls = [];
    // Online by default; the offline cases override it again.
    VoiceIntentRemote.onlineCheckOverride = () async => true;
  });

  tearDown(VoiceIntentRemote.resetOverrides);

  group('gating — when it is allowed to hit the network at all', () {
    test('confident local parse -> no call, null', () async {
      respondWith(llmReply());
      final result = await VoiceIntentRemote.refine(
        localIntent(amount: 200, recipient: 'ramesh', confidence: 0.9),
      );
      expect(result, isNull);
      expect(calls, isEmpty);
    });

    test('confidence exactly at the 0.6 floor -> no call, null', () async {
      respondWith(llmReply());
      final result = await VoiceIntentRemote.refine(
        localIntent(amount: 200, confidence: 0.6),
      );
      expect(result, isNull);
      expect(calls, isEmpty);
    });

    test('offline -> no call, null', () async {
      VoiceIntentRemote.onlineCheckOverride = () async => false;
      respondWith(llmReply());
      final result =
          await VoiceIntentRemote.refine(localIntent(confidence: 0.2));
      expect(result, isNull);
      expect(calls, isEmpty);
    });

    test('connectivity probe that throws is treated as offline', () async {
      VoiceIntentRemote.onlineCheckOverride =
          () async => throw Exception('MissingPluginException');
      respondWith(llmReply());
      final result =
          await VoiceIntentRemote.refine(localIntent(confidence: 0.2));
      expect(result, isNull);
      expect(calls, isEmpty);
    });

    test('empty transcript -> no call, null', () async {
      respondWith(llmReply());
      final result = await VoiceIntentRemote.refine(
        localIntent(confidence: 0.1, transcript: '   '),
      );
      expect(result, isNull);
      expect(calls, isEmpty);
    });

    test('low confidence + online -> the transcript is sent', () async {
      respondWith(llmReply());
      await VoiceIntentRemote.refine(
        localIntent(confidence: 0.3, transcript: 'ramesh ko kuch bhejo'),
      );
      expect(calls, ['ramesh ko kuch bhejo']);
    });

    test('an over-long transcript is capped at 500 chars', () async {
      respondWith(llmReply());
      await VoiceIntentRemote.refine(
        localIntent(confidence: 0.3, transcript: 'x' * 900),
      );
      expect(calls.single.length, 500);
    });
  });

  group('parsed_by', () {
    test('"unavailable" -> null', () async {
      respondWith(llmReply(
        amount: null,
        recipient: null,
        confidence: 0.0,
        parsedBy: 'unavailable',
      ));
      final result =
          await VoiceIntentRemote.refine(localIntent(confidence: 0.3));
      expect(result, isNull);
      expect(calls, hasLength(1)); // it did try — it just got nothing usable
    });

    test('"unavailable" with a stray amount is still ignored', () async {
      respondWith(llmReply(amount: 500, parsedBy: 'unavailable'));
      expect(
        await VoiceIntentRemote.refine(localIntent(confidence: 0.3)),
        isNull,
      );
    });

    test('a missing parsed_by field -> null', () async {
      VoiceIntentRemote.postOverride = (_) async => {
            'amount': 200,
            'recipient_query': 'ramesh',
            'confidence': 0.95,
          };
      expect(
        await VoiceIntentRemote.refine(localIntent(confidence: 0.3)),
        isNull,
      );
    });
  });

  group('strictly better, or nothing', () {
    test('remote finds the amount the local parse missed -> returned',
        () async {
      respondWith(llmReply(amount: 250, recipient: 'sunita', confidence: 0.4));
      final result = await VoiceIntentRemote.refine(
        localIntent(confidence: 0.3, transcript: 'sunita ko dhai sau bhejo'),
      );
      expect(result, isNotNull);
      expect(result!.amount, 250);
      expect(result.recipientQuery, 'sunita');
      // Local had no amount at all, so even a modest remote parse wins.
      expect(result.confidence, 0.4);
    });

    test('higher remote confidence -> returned, local transcript preserved',
        () async {
      respondWith(llmReply(amount: 200, recipient: 'ramesh', confidence: 0.95));
      final result = await VoiceIntentRemote.refine(
        localIntent(
          amount: 2,
          recipient: 'ramesh',
          confidence: 0.35,
          transcript: 'ramesh ko do sau bhejo',
        ),
      );
      expect(result, isNotNull);
      expect(result!.amount, 200);
      expect(result.confidence, 0.95);
      // Contract point 4: the transcript is what the USER said, never the
      // server's echo.
      expect(result.transcript, 'ramesh ko do sau bhejo');
    });

    test('equal confidence -> null (deterministic parser wins ties)', () async {
      respondWith(llmReply(amount: 999, confidence: 0.4));
      final result = await VoiceIntentRemote.refine(
        localIntent(amount: 200, recipient: 'ramesh', confidence: 0.4),
      );
      expect(result, isNull);
    });

    test('lower confidence with a local amount present -> null', () async {
      respondWith(llmReply(amount: 999, confidence: 0.1));
      final result = await VoiceIntentRemote.refine(
        localIntent(amount: 200, recipient: 'ramesh', confidence: 0.5),
      );
      expect(result, isNull);
    });

    test('remote with no amount -> null even at confidence 1.0', () async {
      respondWith(llmReply(amount: null, confidence: 1.0));
      expect(
        await VoiceIntentRemote.refine(localIntent(confidence: 0.2)),
        isNull,
      );
    });

    test('a remote result with no name keeps the local recipient', () async {
      respondWith(llmReply(amount: 200, recipient: null, confidence: 0.9));
      final result = await VoiceIntentRemote.refine(
        localIntent(recipient: 'ramesh', confidence: 0.3),
      );
      expect(result!.recipientQuery, 'ramesh');
    });
  });

  group('hostile payloads', () {
    test('negative and zero amounts -> null', () async {
      for (final bad in [-1, -200, 0]) {
        respondWith(llmReply(amount: bad, confidence: 0.99));
        expect(
          await VoiceIntentRemote.refine(localIntent(confidence: 0.2)),
          isNull,
          reason: 'amount $bad must not be accepted',
        );
      }
    });

    test('an absurd amount -> null', () async {
      respondWith(llmReply(amount: 99999999, confidence: 0.99));
      expect(
        await VoiceIntentRemote.refine(localIntent(confidence: 0.2)),
        isNull,
      );
    });

    test('string types are tolerated, not fatal', () async {
      respondWith(llmReply(amount: '200', confidence: '0.9'));
      final result =
          await VoiceIntentRemote.refine(localIntent(confidence: 0.2));
      expect(result!.amount, 200);
      expect(result.confidence, 0.9);
    });

    test('out-of-range confidence is clamped', () async {
      respondWith(llmReply(amount: 200, confidence: 7.5));
      final result =
          await VoiceIntentRemote.refine(localIntent(confidence: 0.2));
      expect(result!.confidence, 1.0);
    });

    test('junk types everywhere -> null, no exception', () async {
      respondWith(llmReply(
        amount: 'not a number',
        recipient: 42,
        confidence: 'yes',
      ));
      expect(
        await VoiceIntentRemote.refine(localIntent(confidence: 0.2)),
        isNull,
      );
    });

    test('an empty response map -> null', () async {
      VoiceIntentRemote.postOverride = (_) async => <String, dynamic>{};
      expect(
        await VoiceIntentRemote.refine(localIntent(confidence: 0.2)),
        isNull,
      );
    });
  });

  group('failure is always null, never an exception', () {
    test('a throwing POST -> null', () async {
      VoiceIntentRemote.postOverride =
          (_) async => throw Exception('401 Unauthorized');
      expect(
        await VoiceIntentRemote.refine(localIntent(confidence: 0.2)),
        isNull,
      );
    });

    test('a synchronously throwing POST -> null', () async {
      VoiceIntentRemote.postOverride = (_) => throw StateError('boom');
      expect(
        await VoiceIntentRemote.refine(localIntent(confidence: 0.2)),
        isNull,
      );
    });

    test('a hung socket -> null within the timeout', () async {
      final never = Completer<Map<String, dynamic>>();
      VoiceIntentRemote.postOverride = (_) => never.future;

      final stopwatch = Stopwatch()..start();
      final result = await VoiceIntentRemote.refine(
        localIntent(confidence: 0.2),
        timeout: const Duration(milliseconds: 100),
      );
      stopwatch.stop();

      expect(result, isNull);
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
    });

    test('a hung connectivity probe -> null within the timeout', () async {
      VoiceIntentRemote.onlineCheckOverride = () => Completer<bool>().future;
      respondWith(llmReply());
      final result = await VoiceIntentRemote.refine(
        localIntent(confidence: 0.2),
        timeout: const Duration(milliseconds: 100),
      );
      expect(result, isNull);
      expect(calls, isEmpty);
    });
  });
}
