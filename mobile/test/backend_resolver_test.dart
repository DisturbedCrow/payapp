// The resolver is what makes one APK work on the venue Wi-Fi, on 5G, and on a
// tethered demo phone. These tests pin the behaviour that matters: it picks a
// reachable host, it never hangs when nothing is reachable, and it re-probes
// after the network moves.
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/config/constants.dart';
import 'package:offline_pay/services/backend_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BackendResolver.probeOverride = null;
    await BackendResolver().invalidate();
  });

  tearDown(() => BackendResolver.probeOverride = null);

  test('candidates are ordered public-first and de-duplicated', () {
    final c = BackendResolver.candidates();
    expect(c, isNotEmpty);
    expect(c.toSet().length, c.length, reason: 'no duplicates');
    // A phone on mobile data can only reach the public HTTPS host, so it must
    // come before any LAN address.
    if (AppConstants.publicApiUrl.isNotEmpty &&
        AppConstants.apiUrlOverride.isEmpty) {
      final pub = c.indexOf(AppConstants.publicApiUrl);
      final lan = c.indexOf(AppConstants.lanApiUrls.first);
      expect(pub, lessThan(lan));
    }
    expect(c.last, 'http://127.0.0.1:8000', reason: 'adb reverse is the last resort');
  });

  test('picks the only reachable candidate', () async {
    final target = BackendResolver.candidates().last;
    BackendResolver.probeOverride = (url) async => url == target;
    expect(await BackendResolver().baseUrl(), target);
  });

  test('an unreachable candidate does not block a reachable one', () async {
    final all = BackendResolver.candidates();
    final slowDead = all.first;
    final alive = all.last;
    BackendResolver.probeOverride = (url) async {
      if (url == slowDead) {
        await Future<void>.delayed(const Duration(seconds: 2));
        return false;
      }
      return url == alive;
    };
    final sw = Stopwatch()..start();
    final chosen = await BackendResolver().baseUrl();
    sw.stop();
    expect(chosen, alive);
    expect(sw.elapsed.inMilliseconds, lessThan(1500),
        reason: 'probes run in parallel, not one after another');
  });

  test('when nothing is reachable it still resolves, and fast', () async {
    BackendResolver.probeOverride = (_) async => false;
    final chosen = await BackendResolver().baseUrl();
    expect(chosen, isNotEmpty, reason: 'never returns null — offline is normal here');
    expect(BackendResolver.candidates(), contains(chosen));
  });

  test('the answer is cached — a second call does not re-probe', () async {
    var probes = 0;
    final target = BackendResolver.candidates().first;
    BackendResolver.probeOverride = (url) async {
      probes++;
      return url == target;
    };
    await BackendResolver().baseUrl();
    final after = probes;
    await BackendResolver().baseUrl();
    expect(probes, after, reason: 'cached, no second round of probes');
  });

  test('invalidate() forces a re-probe, so a network change self-heals', () async {
    final all = BackendResolver.candidates();
    var reachable = all.first;
    BackendResolver.probeOverride = (url) async => url == reachable;
    expect(await BackendResolver().baseUrl(), all.first);

    // The phone leaves the Wi-Fi; a different host is now the reachable one.
    reachable = all.last;
    await BackendResolver().invalidate();
    expect(await BackendResolver().baseUrl(), all.last);
  });

  test('a probe that throws is treated as unreachable, not fatal', () async {
    final alive = BackendResolver.candidates().last;
    BackendResolver.probeOverride = (url) async {
      if (url != alive) throw Exception('socket blew up');
      return true;
    };
    expect(await BackendResolver().baseUrl(), alive);
  });
}
