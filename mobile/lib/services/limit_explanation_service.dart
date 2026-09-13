import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import 'api_service.dart';
import 'connectivity_service.dart';

/// One plain-language explanation of the user's AI offline limit.
///
/// Mirrors the payload of `GET /api/user/limit-explanation?lang=en|hi`
/// (backend/app/routes/explain_routes.py) plus two client-side fields:
/// [generatedAt] — when *we* fetched it — and [fromCache].
class LimitExplanation {
  final String headline;
  final String body;
  final String tip;
  final String lang;

  /// `'llm'` when a GenAI model wrote the copy, `'template'` for the
  /// deterministic fallback. Only `'llm'` earns the "AI" badge on stage.
  final String generatedBy;

  final double limit;
  final double riskScore;

  /// When this client fetched the explanation (NOT the backend's
  /// `generated_at`, which can be much older behind the server cache).
  final DateTime generatedAt;

  /// True when this instance was served from SharedPreferences rather than
  /// from a live request.
  final bool fromCache;

  const LimitExplanation({
    required this.headline,
    required this.body,
    required this.tip,
    required this.lang,
    required this.generatedBy,
    required this.limit,
    required this.riskScore,
    required this.generatedAt,
    this.fromCache = false,
  });

  /// [generatedBy] value for copy built on the phone by the edge engine
  /// (Feature I3) from its own factors, while offline.
  static const String onDevice = 'on-device';

  /// Whether the copy came from the GenAI model (drives the "AI" badge).
  bool get isAiGenerated => generatedBy == 'llm';

  /// Whether the copy was built on-device from the edge engine's factors.
  bool get isOnDevice => generatedBy == onDevice;

  /// Parses either a raw backend response or a cache entry written by
  /// [toJson]. Cache entries carry `fetched_at`; raw responses do not, so a
  /// raw response is stamped with the current time.
  ///
  /// Tolerates ints for `limit` / `risk_score` and missing optional fields;
  /// it never throws on a well-formed JSON map.
  factory LimitExplanation.fromJson(
    Map<String, dynamic> json, {
    bool fromCache = false,
    String fallbackLang = 'en',
  }) {
    final rawLang = json['lang'];
    final lang = (rawLang == 'hi' || rawLang == 'en')
        ? rawLang as String
        : fallbackLang;

    return LimitExplanation(
      headline: (json['headline'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      tip: (json['tip'] ?? '').toString(),
      lang: lang,
      generatedBy: (json['generated_by'] ?? 'template').toString(),
      limit: (json['limit'] as num?)?.toDouble() ?? 0.0,
      riskScore: (json['risk_score'] as num?)?.toDouble() ?? 0.0,
      generatedAt: _parseTime(json['fetched_at']) ?? DateTime.now(),
      fromCache: fromCache,
    );
  }

  /// The cache representation. Round-trips through [fromJson].
  Map<String, dynamic> toJson() => {
        'headline': headline,
        'body': body,
        'tip': tip,
        'lang': lang,
        'generated_by': generatedBy,
        'limit': limit,
        'risk_score': riskScore,
        'fetched_at': generatedAt.toIso8601String(),
      };

  LimitExplanation copyWith({bool? fromCache}) => LimitExplanation(
        headline: headline,
        body: body,
        tip: tip,
        lang: lang,
        generatedBy: generatedBy,
        limit: limit,
        riskScore: riskScore,
        generatedAt: generatedAt,
        fromCache: fromCache ?? this.fromCache,
      );

  static DateTime? _parseTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}

/// Fetches and caches the GenAI risk explanation (Feature D).
///
/// Contract, in order of importance for demo day:
///   * [load] NEVER throws and NEVER hangs — every path resolves to an
///     explanation or `null`.
///   * The cache is keyed by language (`{"en": {...}, "hi": {...}}`) under
///     [AppConstants.limitExplanationCacheKey], so toggling EN/हिं while
///     offline still renders if both languages were fetched once.
///   * An in-memory copy backs every read, so a dashboard rebuild does not
///     re-hit SharedPreferences each frame.
class LimitExplanationService {
  static final LimitExplanationService _instance =
      LimitExplanationService._internal();
  factory LimitExplanationService() => _instance;
  LimitExplanationService._internal();

  /// Test seam: overrides the connectivity probe so widget tests never reach
  /// the network. Production leaves this null.
  @visibleForTesting
  static Future<bool> Function()? onlineCheckOverride;

  static const Duration _requestTimeout = Duration(seconds: 20);
  static const Duration _connectivityTimeout = Duration(seconds: 3);

  final ApiService _api = ApiService();

  /// lang -> explanation, avoids a prefs round-trip on every rebuild.
  final Map<String, LimitExplanation> _memory = {};
  String? _langMemory;

  Future<LimitExplanation?>? _inflight;
  String? _inflightLang;

  // ── Language ──────────────────────────────────────────────────

  /// `'en'` or `'hi'`, persisted. Defaults to `'en'`.
  Future<String> getLang() async {
    final cached = _langMemory;
    if (cached != null) return cached;
    String lang = 'en';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(AppConstants.explainerLangKey) == 'hi') lang = 'hi';
    } catch (_) {
      lang = 'en';
    }
    _langMemory = lang;
    return lang;
  }

  /// Persists the preferred language. Anything other than `'hi'` becomes
  /// `'en'` so a bad value can never reach the `^(en|hi)$` backend guard.
  Future<void> setLang(String lang) async {
    final normalized = lang == 'hi' ? 'hi' : 'en';
    _langMemory = normalized;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.explainerLangKey, normalized);
    } catch (_) {
      // Preference is best-effort; the in-memory value still applies.
    }
  }

  // ── Reads ─────────────────────────────────────────────────────

  /// The cached explanation for [lang] (default: the persisted language),
  /// always flagged `fromCache: true`. `null` when nothing is cached or the
  /// cache entry is corrupt.
  Future<LimitExplanation?> cached({String? lang}) async {
    final target = lang ?? await getLang();

    final inMemory = _memory[target];
    if (inMemory != null) return inMemory.copyWith(fromCache: true);

    final all = await _readAll();
    final entry = all[target];
    if (entry is! Map) return null;
    try {
      final parsed = LimitExplanation.fromJson(
        Map<String, dynamic>.from(entry),
        fromCache: true,
        fallbackLang: target,
      );
      _memory[target] = parsed;
      return parsed;
    } catch (_) {
      return null; // corrupt entry == no cache
    }
  }

  /// Loads the explanation for the current language.
  ///
  /// Offline  -> the cache, or `null` when there is none.
  /// Online   -> `GET /api/user/limit-explanation?lang=…`, persisted per
  ///             language, returned fresh.
  /// Any error (timeout, 401, connection dropped mid-flight) -> the cache,
  /// else `null`. This method never throws.
  Future<LimitExplanation?> load({bool forceRefresh = false}) async {
    final lang = await getLang();

    // Collapse the initState fetch and a dashboard refresh() that lands a few
    // milliseconds later into a single request.
    final pending = _inflight;
    if (!forceRefresh && pending != null && _inflightLang == lang) {
      return pending;
    }

    final future = _fetch(lang);
    _inflight = future;
    _inflightLang = lang;
    try {
      return await future;
    } finally {
      if (identical(_inflight, future)) {
        _inflight = null;
        _inflightLang = null;
      }
    }
  }

  /// Drops the cache (memory + prefs) and the stored language.
  Future<void> clear() async {
    resetMemory();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConstants.limitExplanationCacheKey);
      await prefs.remove(AppConstants.explainerLangKey);
    } catch (_) {
      // Nothing to do — the in-memory copy is already gone.
    }
  }

  /// Clears only the in-memory copy. Used between tests so the singleton
  /// cannot leak state across cases.
  @visibleForTesting
  void resetMemory() {
    _memory.clear();
    _langMemory = null;
    _inflight = null;
    _inflightLang = null;
  }

  // ── Internals ─────────────────────────────────────────────────

  Future<LimitExplanation?> _fetch(String lang) async {
    if (!await _isOnline()) return cached(lang: lang);

    try {
      final response = await _api
          .get('/api/user/limit-explanation?lang=$lang')
          .timeout(_requestTimeout);

      final fresh = LimitExplanation.fromJson(response, fallbackLang: lang);
      _memory[lang] = fresh;
      await _persist(lang, fresh);
      return fresh;
    } catch (_) {
      // ApiException, timeout, offline mid-flight, malformed payload —
      // the card must still render, so fall back to whatever we have.
      return cached(lang: lang);
    }
  }

  /// Fail-closed: if connectivity cannot be determined we treat the device as
  /// offline, which serves the cache instead of blocking on a doomed request.
  Future<bool> _isOnline() async {
    final override = onlineCheckOverride;
    if (override != null) {
      try {
        return await override();
      } catch (_) {
        return false;
      }
    }
    try {
      return await ConnectivityService().checkNow().timeout(
            _connectivityTimeout,
          );
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConstants.limitExplanationCacheKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _persist(String lang, LimitExplanation explanation) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = await _readAll();
      all[lang] = explanation.toJson();
      await prefs.setString(
        AppConstants.limitExplanationCacheKey,
        jsonEncode(all),
      );
    } catch (_) {
      // Caching is best-effort — a failed write must not fail the fetch.
    }
  }
}
