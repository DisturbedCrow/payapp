// Feature G3.5 — spoken confirmation readback ("₹200 Ramesh ko bhejne ke liye
// confirm karein"), so a user who cannot read the screen still hears what is
// about to be paid before tapping Confirm.
//
// CONTRACT (identical in spirit to voice_service.dart): this file is polish,
// never a dependency. Every plugin call is wrapped; a missing plugin, a phone
// with no TTS engine, or an absent Hindi voice all degrade to silence. The
// method is fire-and-forget — the caller must NOT await it, and an unawaited
// call can never surface an unhandled async error, because nothing in
// [VoiceReadbackService.speakConfirmation] is allowed to escape its try/catch.
//
// A demo must never hang or crash because the phone cannot talk.

import 'package:flutter_tts/flutter_tts.dart';

import '../config/constants.dart';

/// Builds the sentence that gets spoken. Pure — no plugin, no state — so the
/// wording is unit-testable without a platform channel.
///
/// * `lang == 'hi'` (default): Hinglish, the phrasing the spec asks for —
///   `"₹200 Ramesh ko bhejne ke liye confirm karein"`.
/// * `lang == 'en'`: `"Confirm to send 200 rupees to Ramesh"`.
///
/// Whole amounts are spoken as plain integers (200, not 200.0); anything with
/// paise keeps two decimals, matching `formatRupees` on the confirm screen so
/// the ear and the eye agree.
String buildConfirmationPhrase({
  required double amount,
  required String payeeName,
  required String lang,
}) {
  final digits = _amountDigits(amount);
  final name = payeeName.trim();

  if (lang.toLowerCase().startsWith('en')) {
    return 'Confirm to send $digits rupees to $name';
  }
  return '₹$digits $name ko bhejne ke liye confirm karein';
}

String _amountDigits(double amount) {
  if (!amount.isFinite) return '0';
  final whole = amount == amount.roundToDouble();
  return whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2);
}

class VoiceReadbackService {
  static final VoiceReadbackService _instance =
      VoiceReadbackService._internal();
  factory VoiceReadbackService() => _instance;
  VoiceReadbackService._internal();

  /// Created lazily: `FlutterTts()` installs a method-call handler in its
  /// constructor, which needs a binding. Building it inside the guarded path
  /// means even constructing this service can never throw.
  FlutterTts? _tts;

  /// Flipped true the first time an utterance actually reaches the platform,
  /// false whenever a plugin call fails. Meaningless (false) until the first
  /// [speakConfirmation] — this is a status light for the UI, not a gate.
  bool _available = false;

  /// Set once `awaitSpeakCompletion(false)` has been accepted.
  bool _configured = false;

  /// Guards against a stale utterance winning the race when the user changes
  /// the selected payee twice in quick succession.
  int _generation = 0;

  /// True when the last readback attempt reached a real TTS engine.
  bool get isAvailable => _available;

  /// Speaks the confirmation line. Fire-and-forget: do not await it.
  ///
  /// Silently no-ops when voice pay is off, when `flutter_tts` is not
  /// registered (unit tests, desktop), or when the device has no engine.
  Future<void> speakConfirmation({
    required double amount,
    required String payeeName,
    String lang = 'hi',
  }) async {
    try {
      if (!AppConstants.voicePayEnabled) return;

      final phrase = buildConfirmationPhrase(
        amount: amount,
        payeeName: payeeName,
        lang: lang,
      );
      if (phrase.trim().isEmpty) return;

      final tts = _engine();
      if (tts == null) return;

      final generation = ++_generation;

      // Whatever is mid-sentence is now stale.
      await stop();
      if (generation != _generation) return;

      if (!_configured) {
        // speak() must return as soon as the utterance is queued, so the
        // caller's UI thread is never parked on the engine.
        await tts.awaitSpeakCompletion(false);
        _configured = true;
      }

      await _applyLanguage(tts, lang);
      if (generation != _generation) return;

      await tts.speak(phrase);
      _available = true;
    } catch (_) {
      // MissingPluginException under `flutter test`, no engine installed,
      // engine crashed mid-call — all of them mean "stay quiet".
      _available = false;
    }
  }

  /// Stops any in-flight utterance. Safe when nothing is speaking and safe
  /// when the plugin was never available.
  Future<void> stop() async {
    try {
      final tts = _tts;
      if (tts == null) return;
      await tts.stop();
    } catch (_) {/* nothing to stop */}
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  FlutterTts? _engine() {
    final existing = _tts;
    if (existing != null) return existing;
    try {
      return _tts = FlutterTts();
    } catch (_) {
      return null;
    }
  }

  /// Best-effort locale selection.
  ///
  /// If `hi-IN` is installed we use it. If it is not — a very common state on
  /// a stock phone whose Hindi voice pack was never downloaded — we leave the
  /// engine on the device default and still speak the Hinglish sentence: a
  /// Hindi line in an English voice is better than silence.
  Future<void> _applyLanguage(FlutterTts tts, String lang) async {
    final wanted = lang.toLowerCase().startsWith('en') ? 'en-IN' : 'hi-IN';
    try {
      // isLanguageAvailable is dynamic; only an explicit true counts.
      final available = await tts.isLanguageAvailable(wanted);
      if (available == true) await tts.setLanguage(wanted);
    } catch (_) {/* device default it is */}
  }
}
