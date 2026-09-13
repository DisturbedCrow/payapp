import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';

/// Works out which backend URL this handset can actually reach, right now.
///
/// A single hard-coded host is the wrong shape for this app. The same APK has
/// to work for a judge on the venue Wi-Fi, a phone on 5G, a laptop-tethered
/// demo device, and a developer on the office LAN — and the answer changes
/// when someone walks between rooms. So instead of trusting one address we
/// probe the candidates and use whichever answers `/health` first.
///
/// Design constraints, in priority order:
///   * NEVER blocks the UI. Probing is bounded and runs in parallel; if
///     nothing answers we keep the last known good URL and let the
///     offline-first path do its job — that path is the whole product.
///   * Sticky. The winner is cached in memory and in SharedPreferences, so a
///     relaunch on the same network is instant.
///   * Self-healing. [invalidate] is called when a request fails, so moving
///     from Wi-Fi to mobile data re-probes instead of failing forever.
class BackendResolver {
  static final BackendResolver _instance = BackendResolver._internal();
  factory BackendResolver() => _instance;
  BackendResolver._internal();

  static const String _cacheKey = 'resolved_backend_url';

  /// Per-candidate probe budget. Deliberately short: a dead LAN address must
  /// not hold up the public URL behind it.
  static const Duration _probeTimeout = Duration(seconds: 4);

  String? _resolved;
  Future<String>? _inflight;

  /// Test seam so unit tests never touch the network.
  @visibleForTesting
  static Future<bool> Function(String url)? probeOverride;

  /// Candidate URLs, best first.
  ///
  /// A `--dart-define=API_URL` always wins — that is how a developer or a
  /// CI build pins a specific backend. Everything after it is a fallback.
  static List<String> candidates() {
    final ordered = <String>[
      if (AppConstants.apiUrlOverride.isNotEmpty) AppConstants.apiUrlOverride,
      // Public HTTPS: the only candidate that works on mobile data, which is
      // what a judge's phone will be on.
      if (AppConstants.publicApiUrl.isNotEmpty) AppConstants.publicApiUrl,
      // Same-LAN laptop: fastest when it applies, useless otherwise.
      ...AppConstants.lanApiUrls,
      // `adb reverse tcp:8000 tcp:8000` — a USB-tethered demo phone.
      'http://127.0.0.1:8000',
    ];
    // Preserve order, drop duplicates.
    final seen = <String>{};
    return ordered.where(seen.add).toList();
  }

  /// The URL to use. Resolves once, then returns the cached answer.
  Future<String> baseUrl() {
    final cached = _resolved;
    if (cached != null) return Future.value(cached);
    return _inflight ??= _resolve().whenComplete(() => _inflight = null);
  }

  /// Best-effort synchronous read, for code that cannot await. Falls back to
  /// the first candidate, which is also what a fresh install would try.
  String get baseUrlSync => _resolved ?? candidates().first;

  /// Forget the current answer so the next call re-probes. Call this when a
  /// request fails — the network may have changed under us.
  Future<void> invalidate() async {
    _resolved = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (_) {/* best effort */}
  }

  // ── Internals ─────────────────────────────────────────────────

  Future<String> _resolve() async {
    final all = candidates();

    // A previously working URL goes to the front — usually an instant hit.
    String? remembered;
    try {
      final prefs = await SharedPreferences.getInstance();
      remembered = prefs.getString(_cacheKey);
    } catch (_) {/* ignore */}

    final ordered = <String>[
      if (remembered != null && remembered.isNotEmpty) remembered,
      ...all.where((c) => c != remembered),
    ];

    // Probe every candidate at once and take the first success, rather than
    // walking the list serially — a phone on 5G would otherwise wait out the
    // LAN timeout before reaching the public URL.
    final winner = await _firstReachable(ordered);
    final chosen = winner ?? ordered.first;

    _resolved = chosen;
    if (winner != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, winner);
      } catch (_) {/* ignore */}
      debugPrint('BackendResolver: using $winner');
    } else {
      // Offline, or every backend is down. Keep the best guess; the app is
      // offline-first and the sync engine will retry.
      debugPrint('BackendResolver: nothing reachable, defaulting to $chosen');
    }
    return chosen;
  }

  Future<String?> _firstReachable(List<String> urls) async {
    final completer = Completer<String?>();
    var pending = urls.length;
    if (pending == 0) return null;

    void settle(String url, bool alive) {
      if (completer.isCompleted) return;
      if (alive) {
        completer.complete(url);
        return;
      }
      pending -= 1;
      if (pending <= 0) completer.complete(null);
    }

    for (final url in urls) {
      // onError matters: without it a probe that throws never decrements
      // `pending`, the completer never fires, and baseUrl() hangs forever —
      // taking every network call in the app with it.
      // ignore: discarded_futures
      _probe(url).then(
        (alive) => settle(url, alive),
        onError: (_) => settle(url, false),
      );
    }

    // Belt and braces: even if a probe neither resolves nor rejects, the
    // resolver must give an answer.
    return completer.future.timeout(
      _probeTimeout + const Duration(seconds: 1),
      onTimeout: () => null,
    );
  }

  Future<bool> _probe(String url) async {
    final override = probeOverride;
    if (override != null) return override(url);
    try {
      final response = await http
          .get(Uri.parse('$url/health'))
          .timeout(_probeTimeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
