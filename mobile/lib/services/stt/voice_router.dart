// Feature H2 — picks the speech engine for one voice capture.
//
//   online  AND gnaniVoiceEnabled AND not degraded  → Gnani Prisma (cloud)
//   otherwise                                      → on-device recogniser
//
// When the cloud engine throws [GnaniUnavailable] the router marks it degraded
// for [AppConstants.gnaniDegradedFor] and, in the same capture, starts the
// on-device engine. The recorded utterance is gone at that point (record-then-
// send), so the UI is told via `onFallback` and must ask the user to say it
// again — the router never pretends the first attempt was heard.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/constants.dart';
import '../connectivity_service.dart';
import 'gnani_stt_engine.dart';
import 'local_stt_engine.dart';
import 'stt_engine.dart';

/// What one [VoiceRouter.capture] produced.
class VoiceCapture {
  /// The utterance, or null when nothing was heard / cancelled / aborted.
  final SttResult? result;

  /// The engine that produced [result] (the last one tried).
  final SttEngine engine;

  /// True when the cloud engine failed and the on-device engine took over.
  final bool fellBack;

  /// Why the cloud engine failed, when [fellBack].
  final String? fallbackReason;

  const VoiceCapture({
    required this.result,
    required this.engine,
    this.fellBack = false,
    this.fallbackReason,
  });
}

class VoiceRouter {
  VoiceRouter({
    SttEngine? gnani,
    SttEngine? local,
    Future<bool> Function()? isOnline,
    Future<String> Function()? lang,
    DateTime Function()? now,
    bool? gnaniEnabled,
    this.degradedFor = AppConstants.gnaniDegradedFor,
    this.rateLimitedFor = AppConstants.gnaniRateLimitedFor,
  })  : _gnaniOverride = gnani,
        _localOverride = local,
        _isOnline = isOnline ?? _connectivityOnline,
        _lang = lang ?? preferredGnaniLang,
        _now = now ?? DateTime.now,
        gnaniEnabled = gnaniEnabled ?? AppConstants.gnaniVoiceEnabled;

  /// App-wide router. Degraded state lives here so it survives the voice
  /// sheet being closed and reopened.
  static VoiceRouter get shared => _shared ??= VoiceRouter();
  static VoiceRouter? _shared;

  @visibleForTesting
  static set shared(VoiceRouter router) => _shared = router;

  final SttEngine? _gnaniOverride;
  final SttEngine? _localOverride;
  SttEngine? _gnaniDefault;
  SttEngine? _localDefault;

  final Future<bool> Function() _isOnline;
  final Future<String> Function() _lang;
  final DateTime Function() _now;

  final bool gnaniEnabled;
  /// How long a cloud failure keeps voice on-device.
  final Duration degradedFor;

  /// The shorter back-off for a rate-limit reply ([GnaniUnavailable.isRateLimited]).
  final Duration rateLimitedFor;

  DateTime? _degradedUntil;

  /// The engine of the capture in progress (or the last one). The sheet uses
  /// it to decide between a waveform and live partials.
  final ValueNotifier<SttEngine?> activeEngine = ValueNotifier<SttEngine?>(null);

  SttEngine get gnani => _gnaniOverride ?? (_gnaniDefault ??= GnaniSttEngine());
  SttEngine get local => _localOverride ?? (_localDefault ??= LocalSttEngine());

  bool get isGnaniDegraded {
    final until = _degradedUntil;
    return until != null && _now().isBefore(until);
  }

  DateTime? get degradedUntil => isGnaniDegraded ? _degradedUntil : null;

  /// Keeps voice on-device for [duration] (default [degradedFor]).
  void markGnaniDegraded([Duration? duration]) =>
      _degradedUntil = _now().add(duration ?? degradedFor);

  @visibleForTesting
  void clearDegraded() => _degradedUntil = null;

  /// The engine the next capture would use. Never throws.
  Future<SttEngine> selectEngine() async {
    if (!gnaniEnabled || isGnaniDegraded) return local;
    try {
      return await _isOnline() ? gnani : local;
    } catch (_) {
      return local;
    }
  }

  /// Runs one capture.
  ///
  /// [engine] lets the caller pass the result of [selectEngine] after doing
  /// its own pre-flight (permission, recogniser init); otherwise the router
  /// selects. [onEngine] fires whenever an engine starts listening.
  ///
  /// [onFallback] fires after a cloud failure, before the on-device engine
  /// starts; return false to skip the on-device attempt (e.g. no recogniser on
  /// this phone), in which case the capture resolves with a null result.
  ///
  /// Only [GnaniUnavailable] is caught; the on-device engine never throws.
  Future<VoiceCapture> capture({
    SttEngine? engine,
    Duration? timeout,
    void Function(SttEngine engine)? onEngine,
    FutureOr<bool> Function(GnaniUnavailable error)? onFallback,
  }) async {
    final chosen = engine ?? await selectEngine();
    activeEngine.value = chosen;
    onEngine?.call(chosen);

    if (!identical(chosen, gnani)) {
      return VoiceCapture(
        result: await chosen.listenOnce(timeout: timeout),
        engine: chosen,
      );
    }

    try {
      final lang = await _safeLang();
      final result = await chosen.listenOnce(timeout: timeout, lang: lang);
      return VoiceCapture(result: result, engine: chosen);
    } on GnaniUnavailable catch (e) {
      final backOff = e.isShortLived ? rateLimitedFor : degradedFor;
      debugPrint('VoiceRouter: $e — on-device for ${backOff.inSeconds}s');
      markGnaniDegraded(backOff);

      final fallback = local;
      var proceed = true;
      if (onFallback != null) {
        try {
          proceed = await onFallback(e);
        } catch (_) {
          proceed = true;
        }
      }
      activeEngine.value = fallback;
      if (!proceed) {
        return VoiceCapture(
          result: null,
          engine: fallback,
          fellBack: true,
          fallbackReason: e.reason,
        );
      }
      onEngine?.call(fallback);
      return VoiceCapture(
        result: await fallback.listenOnce(timeout: timeout),
        engine: fallback,
        fellBack: true,
        fallbackReason: e.reason,
      );
    }
  }

  /// Ends the active capture early, keeping what was heard.
  Future<void> stop() async => activeEngine.value?.stop();

  /// Ends the active capture and discards it.
  Future<void> cancel() async => activeEngine.value?.cancel();

  Future<String> _safeLang() async {
    try {
      return await _lang();
    } catch (_) {
      return 'hi-IN';
    }
  }

  // ── Production dependencies ─────────────────────────────────────────────

  static Future<bool> _connectivityOnline() async {
    try {
      return await ConnectivityService()
          .checkNow()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return false; // fail closed: unknown connectivity → on-device
    }
  }

  /// The EN | हिं preference the limit explainer persists, as a Gnani language
  /// code. Read from the stored key rather than
  /// `LimitExplanationService.getLang()` because that getter defaults to 'en',
  /// while voice must default to Hindi when the user never chose.
  static Future<String> preferredGnaniLang() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(AppConstants.explainerLangKey) == 'en'
          ? 'en-IN'
          : 'hi-IN';
    } catch (_) {
      return 'hi-IN';
    }
  }
}
