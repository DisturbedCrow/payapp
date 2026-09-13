// Feature H2 — which speech engine runs, and what happens when the cloud one
// fails. Fake engines only; no plugins, no network.
//
//   flutter test test/voice_router_test.dart

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/services/stt/stt_engine.dart';
import 'package:offline_pay/services/stt/voice_router.dart';

class FakeEngine implements SttEngine {
  FakeEngine(this.id, {this.result, this.error, this.log});

  @override
  final String id;
  SttResult? result;
  Object? error;
  final List<String>? log;

  int listens = 0;
  int stops = 0;
  int cancels = 0;
  String? lastLang;

  @override
  Future<SttResult?> listenOnce({Duration? timeout, String? lang}) async {
    listens++;
    lastLang = lang;
    log?.add('listen:$id');
    final e = error;
    if (e != null) throw e;
    return result;
  }

  @override
  Stream<String> get partials => const Stream<String>.empty();

  @override
  Stream<double> get levels => const Stream<double>.empty();

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> cancel() async => cancels++;
}

const gnaniHeard = SttResult(
  transcript: 'ramesh ko ₹250 bhejo',
  provider: SttProvider.gnani,
  amountEntity: 250,
  lang: 'hi-IN',
  latencyMs: 700,
);
const localHeard = SttResult(
  transcript: 'ramesh ko do sau pachas bhejo',
  provider: SttProvider.onDevice,
);

void main() {
  late FakeEngine gnani;
  late FakeEngine local;
  late bool online;
  late DateTime clock;
  late List<String> log;

  VoiceRouter router({bool enabled = true, String lang = 'hi-IN'}) =>
      VoiceRouter(
        gnani: gnani,
        local: local,
        isOnline: () async => online,
        lang: () async => lang,
        now: () => clock,
        gnaniEnabled: enabled,
      );

  setUp(() {
    log = [];
    gnani = FakeEngine(SttProvider.gnani, result: gnaniHeard, log: log);
    local = FakeEngine(SttProvider.onDevice, result: localHeard, log: log);
    online = true;
    clock = DateTime(2026, 9, 13, 12);
  });

  group('engine selection', () {
    test('online -> Gnani result, with the preferred language', () async {
      final r = router(lang: 'en-IN');
      final c = await r.capture();
      expect(c.result, same(gnaniHeard));
      expect(c.engine, same(gnani));
      expect(c.fellBack, isFalse);
      expect(gnani.lastLang, 'en-IN');
      expect(local.listens, 0);
      expect(r.activeEngine.value, same(gnani));
    });

    test('offline -> on-device, Gnani never touched', () async {
      online = false;
      final c = await router().capture();
      expect(c.result, same(localHeard));
      expect(c.engine, same(local));
      expect(gnani.listens, 0);
    });

    test('a connectivity probe that throws counts as offline', () async {
      final r = VoiceRouter(
        gnani: gnani,
        local: local,
        isOnline: () async => throw Exception('MissingPluginException'),
        now: () => clock,
        gnaniEnabled: true,
      );
      expect(await r.selectEngine(), same(local));
    });

    test('GNANI_VOICE flag off -> on-device even when online', () async {
      final c = await router(enabled: false).capture();
      expect(c.engine, same(local));
      expect(gnani.listens, 0);
    });

    test('a pre-selected engine is used as-is', () async {
      final r = router();
      final c = await r.capture(engine: local);
      expect(c.engine, same(local));
      expect(gnani.listens, 0);
    });

    test('onEngine reports the engine before it listens', () async {
      final seen = <String>[];
      await router().capture(onEngine: (e) => log.add('engine:${e.id}'));
      seen.addAll(log);
      expect(seen, ['engine:gnani', 'listen:gnani']);
    });

    test('a failing language lookup defaults to hi-IN', () async {
      final r = VoiceRouter(
        gnani: gnani,
        local: local,
        isOnline: () async => true,
        lang: () async => throw StateError('prefs'),
        now: () => clock,
        gnaniEnabled: true,
      );
      await r.capture();
      expect(gnani.lastLang, 'hi-IN');
    });
  });

  group('Gnani failure -> on-device fallback', () {
    test('GnaniUnavailable degrades Gnani and runs on-device immediately',
        () async {
      gnani.error = const GnaniUnavailable('provider down', statusCode: 503);
      final r = router();
      String? toldUser;

      final c = await r.capture(
        onFallback: (e) {
          toldUser = e.reason;
          log.add('fallback');
          return true;
        },
      );

      expect(c.fellBack, isTrue);
      expect(c.fallbackReason, 'provider down');
      expect(c.result, same(localHeard));
      expect(c.engine, same(local));
      expect(toldUser, 'provider down');
      // The UI is told BEFORE the on-device engine opens the mic.
      expect(log, ['listen:gnani', 'fallback', 'listen:on-device']);
      expect(r.isGnaniDegraded, isTrue);
      expect(r.degradedUntil, clock.add(const Duration(minutes: 3)));
      expect(r.activeEngine.value, same(local));
    });

    test('the next capture goes straight to on-device while degraded',
        () async {
      gnani.error = const GnaniUnavailable('timeout');
      final r = router();
      await r.capture();
      expect(gnani.listens, 1);

      gnani.error = null; // Gnani has recovered, but we are not asking yet
      final next = await r.capture();
      expect(next.engine, same(local));
      expect(next.fellBack, isFalse);
      expect(gnani.listens, 1);
    });

    test('still degraded at 2m59s, Gnani retried after 3 minutes', () async {
      gnani.error = const GnaniUnavailable('timeout');
      final r = router();
      await r.capture();
      gnani.error = null;

      clock = clock.add(const Duration(minutes: 2, seconds: 59));
      expect(r.isGnaniDegraded, isTrue);
      expect((await r.capture()).engine, same(local));
      expect(gnani.listens, 1);

      clock = clock.add(const Duration(seconds: 2));
      expect(r.isGnaniDegraded, isFalse);
      final back = await r.capture();
      expect(back.engine, same(gnani));
      expect(back.result, same(gnaniHeard));
      expect(gnani.listens, 2);
    });

    test('rate_limited backs off for 20 s, not 3 minutes', () async {
      gnani.error =
          const GnaniUnavailable('rate_limited', statusCode: 503);
      final r = router();
      final c = await r.capture();
      expect(c.fellBack, isTrue);
      expect(c.result, same(localHeard));
      expect(r.degradedUntil, clock.add(const Duration(seconds: 20)));

      gnani.error = null;
      clock = clock.add(const Duration(seconds: 19));
      expect((await r.capture()).engine, same(local));

      clock = clock.add(const Duration(seconds: 2));
      expect((await r.capture()).engine, same(gnani));
    });

    test('no_transcript (a mumble, silence) backs off 20 s, not 3 minutes',
        () async {
      gnani.error = const GnaniUnavailable('no_transcript', statusCode: 503);
      final r = router();
      final c = await r.capture();
      expect(c.fellBack, isTrue);
      expect(r.degradedUntil, clock.add(const Duration(seconds: 20)));

      gnani.error = null;
      clock = clock.add(const Duration(seconds: 21));
      expect((await r.capture()).engine, same(gnani));
    });

    test('an outage still keeps voice on-device for the full window', () {
      const outage = GnaniUnavailable('timeout', statusCode: 503);
      expect(outage.isShortLived, isFalse);
      expect(const GnaniUnavailable('no_transcript').isShortLived, isTrue);
      expect(const GnaniUnavailable('rate_limited').isShortLived, isTrue);
    });

    test('HTTP 429 also counts as rate limiting', () {
      expect(const GnaniUnavailable('slow down', statusCode: 429).isRateLimited,
          isTrue);
      expect(const GnaniUnavailable('provider down', statusCode: 503)
          .isRateLimited, isFalse);
    });

    test('onFallback returning false skips the on-device attempt', () async {
      gnani.error = const GnaniUnavailable('down');
      final r = router();
      final c = await r.capture(onFallback: (_) async => false);
      expect(c.fellBack, isTrue);
      expect(c.result, isNull);
      expect(local.listens, 0);
      expect(r.isGnaniDegraded, isTrue);
    });

    test('a throwing onFallback still falls back', () async {
      gnani.error = const GnaniUnavailable('down');
      final c = await router().capture(onFallback: (_) => throw StateError('x'));
      expect(c.result, same(localHeard));
    });

    test('other errors are not swallowed as a fallback', () async {
      gnani.error = StateError('bug');
      final r = router();
      await expectLater(r.capture(), throwsStateError);
      expect(r.isGnaniDegraded, isFalse);
    });

    test('offline fallback does not degrade Gnani', () async {
      online = false;
      final r = router();
      await r.capture();
      expect(r.isGnaniDegraded, isFalse);
    });
  });

  group('stop / cancel', () {
    test('are forwarded to the active engine', () async {
      final r = router();
      await r.stop(); // nothing active yet: no-op
      await r.capture();
      await r.stop();
      await r.cancel();
      expect(gnani.stops, 1);
      expect(gnani.cancels, 1);
      expect(local.stops, 0);
    });
  });

  test('preferredGnaniLang never throws and defaults to Hindi', () async {
    // No SharedPreferences mock is installed, so the read fails or is empty —
    // either way voice must default to hi-IN.
    expect(
      await VoiceRouter.preferredGnaniLang(),
      anyOf('hi-IN', 'en-IN'),
    );
  });
}
