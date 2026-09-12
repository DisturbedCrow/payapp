// Feature G — thin, crash-proof wrapper around `speech_to_text`.
//
// CONTRACT: every method here is safe to call when the plugin is missing
// (unit tests, emulators without a recogniser, a phone with the Google app
// disabled). `init()` returns false and everything else no-ops, so the demo
// degrades to typed input instead of throwing. Nothing in this file is ever
// allowed to propagate an exception to the UI.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../config/constants.dart';
import 'offline_storage.dart';
import 'voice_intent_parser.dart';

class VoiceService {
  static final VoiceService _instance = VoiceService._internal();
  factory VoiceService() => _instance;
  VoiceService._internal();

  final SpeechToText _speech = SpeechToText();

  bool _initialised = false;
  bool _available = false;
  bool _listening = false;
  String? _activeLocaleId;
  String? _lastError;

  /// Whether the current attempt ever produced words, and the error it hit.
  /// Together these separate "the engine cannot do this" from "nobody spoke".
  bool _sawPartial = false;
  String? _attemptError;

  StreamController<String>? _partialsController;
  Completer<String?>? _session;
  Timer? _hardStop;

  /// Fires [AppConstants.voicePauseFor] after the last word was heard.
  Timer? _silence;
  String _lastTranscript = '';

  // ── Public surface ──────────────────────────────────────────────────────

  /// True once [init] has succeeded and a recogniser is actually usable.
  bool get isAvailable => _available;

  /// True while a listen session is open.
  bool get isListening => _listening;

  /// The locale the recogniser was started with — 'hi_IN' when the Hindi pack
  /// is installed, else 'en_IN', else the device default (null).
  String? get activeLocaleId => _activeLocaleId;

  /// Human-readable reason the last operation failed, for the "voice isn't
  /// available" panel. Null when everything is fine.
  String? get lastError => _lastError;

  /// Live partial transcripts. Broadcast, and lazily recreated so a
  /// `dispose()` on this singleton never poisons the next mic tap.
  Stream<String> get partials {
    final c = _partialsController;
    if (c == null || c.isClosed) {
      _partialsController = StreamController<String>.broadcast();
    }
    return _partialsController!.stream;
  }

  /// Prepares the recogniser. Returns false when speech is unavailable or the
  /// microphone permission was denied — the caller should then hide the mic
  /// entry point / show the "Type instead" fallback. NEVER throws.
  Future<bool> init() async {
    if (!AppConstants.voicePayEnabled) {
      _lastError = 'Voice payments are disabled';
      return false;
    }
    // Only a SUCCESSFUL init is latched. A one-off "Deny" on the permission
    // dialog must not disable the mic for the rest of the session — the next
    // tap re-prompts.
    if (_initialised && _available) return true;

    try {
      if (!await _ensureMicPermission()) {
        _available = false;
        return false;
      }

      _available = await _speech.initialize(
        onError: _onError,
        onStatus: _onStatus,
        debugLogging: false,
      );

      if (!_available) {
        _lastError ??= 'No speech recogniser on this device';
        return false;
      }

      _activeLocaleId = await _pickLocale();
      _lastError = null;
      _initialised = true;
      return true;
    } catch (e) {
      // MissingPluginException in tests, or any platform-side failure.
      _available = false;
      _lastError = 'Speech engine unavailable';
      return false;
    }
  }

  /// One listen configuration. Google exposes several recognisers and not all
  /// of them can serve every locale, so we describe each attempt explicitly
  /// rather than assuming one works.
  static const List<_ListenAttempt> _ladder = [
    // Best: fully offline Hindi. Needs the on-device Hindi pack.
    _ListenAttempt(onDevice: true, preferHindi: true, label: 'offline hi-IN'),
    // Hindi via the network recogniser — works today, not in airplane mode.
    _ListenAttempt(onDevice: false, preferHindi: true, label: 'online hi-IN'),
    // Last resort: whatever locale the device defaults to. Hinglish speakers
    // are usually intelligible to en-IN and the parser reads Roman too.
    _ListenAttempt(onDevice: false, preferHindi: false, label: 'device default'),
  ];

  /// The ladder rung that last produced a transcript. Tried first next time so
  /// the demo does not pay the failed-attempt latency twice.
  int _preferredRung = 0;

  /// Human-readable description of the rung currently in use.
  String? get activeMode => _activeMode;
  String? _activeMode;

  /// Runs one listen session and resolves with the final transcript.
  ///
  /// Walks [_ladder] until something works. The reason this exists: forcing
  /// `onDevice: true` when the on-device Hindi model is not installed makes
  /// Google's recogniser throw within ~200 ms — the mic opens and shuts
  /// instantly and the sheet looks broken. Rather than guess what a given
  /// handset has installed, we try the best option and fall back on a
  /// fast failure.
  ///
  /// Returns null when nothing was heard, the session was cancelled, or the
  /// plugin is unavailable. Auto-stops after [AppConstants.voicePauseFor] of
  /// silence or [AppConstants.voiceMaxListen] overall, whichever comes first.
  Future<String?> listenOnce({Duration? timeout}) async {
    final maxListen = timeout ?? AppConstants.voiceMaxListen;

    if (!_available) {
      final ok = await init();
      if (!ok) return null;
    }

    // Start at the rung that worked last time, then wrap around.
    final order = <int>[
      _preferredRung,
      for (var i = 0; i < _ladder.length; i++)
        if (i != _preferredRung) i,
    ];

    for (var i = 0; i < order.length; i++) {
      final rung = order[i];
      final attempt = _ladder[rung];

      // After a refusal the platform recogniser is left in a state where the
      // next listen() returns error_language_unavailable in ~5 ms without ever
      // opening the mic. Re-initialising clears it, so each rung gets a fair
      // attempt rather than inheriting the previous one's failure.
      if (i > 0) {
        await _reinitialise();
      }

      final outcome = await _attemptListen(attempt, maxListen);

      if (outcome.transcript != null) {
        _preferredRung = rung;
        _activeMode = attempt.label;
        return outcome.transcript;
      }

      // The engine refused this configuration (wrong locale, no offline
      // model). Drop to the next rung immediately.
      if (outcome.failedFast) continue;

      // The engine worked and the user simply said nothing. Retrying a
      // different recogniser would not help and would double the wait.
      _activeMode = attempt.label;
      return null;
    }

    return null;
  }

  /// Arms (or re-arms) the end-of-speech pause. Called on every partial, so
  /// the countdown restarts while the user is still talking and only fires
  /// once they have genuinely stopped.
  void _armSilenceTimer(void Function(String?) finish) {
    _silence?.cancel();
    _silence = Timer(AppConstants.voicePauseFor, () async {
      try {
        await _speech.stop();
      } catch (_) {/* ignore */}
      finish(_lastTranscript);
    });
  }

  /// Tears the plugin down and brings it back up, clearing any latched error
  /// state from a refused configuration.
  Future<void> _reinitialise() async {
    try {
      await _speech.cancel();
    } catch (_) {/* ignore */}
    try {
      await _speech.stop();
    } catch (_) {/* ignore */}
    _initialised = false;
    _available = false;
    _attemptError = null;
    // Give the platform service a moment to release the session.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      _available = await _speech.initialize(
        onError: _onError,
        onStatus: _onStatus,
        debugLogging: false,
      );
      _initialised = _available;
    } catch (_) {
      _available = false;
    }
  }

  /// Runs exactly one configuration. Never throws.
  Future<_ListenOutcome> _attemptListen(
    _ListenAttempt attempt,
    Duration maxListen,
  ) async {
    // Only one session at a time.
    if (_session != null && !_session!.isCompleted) {
      await stop();
    }

    final localeId = attempt.preferHindi ? _activeLocaleId : null;
    final completer = Completer<String?>();
    _session = completer;
    _lastTranscript = '';
    _listening = true;
    _sawPartial = false;
    _attemptError = null;
    final startedAt = DateTime.now();

    void finish(String? value) {
      if (completer.isCompleted) return;
      _listening = false;
      _hardStop?.cancel();
      _hardStop = null;
      _silence?.cancel();
      _silence = null;
      final trimmed = value?.trim();
      completer.complete(
        (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      );
    }

    _onFinal = finish;

    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult r) {
          _lastTranscript = r.recognizedWords;
          if (r.recognizedWords.isNotEmpty) {
            _sawPartial = true;
            _armSilenceTimer(finish);
          }
          _emitPartial(r.recognizedWords);
          if (r.finalResult) finish(r.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          // On Android this is EXTRA_PREFER_OFFLINE. Only the first rung sets
          // it — see the ladder comment above for why forcing it is unsafe.
          onDevice: attempt.onDevice,
          partialResults: true,
          // Deliberately false: an error must not tear the session down before
          // we can decide whether to retry on the next rung.
          cancelOnError: false,
          listenMode: ListenMode.dictation,
          // NOT AppConstants.voicePauseFor. The plugin starts counting
          // `pauseFor` the instant listening begins, so a 1.2 s value ends the
          // session 1.2 s after the sheet opens unless the user is already
          // mid-word — which is what made the mic look like it "opens and
          // closes instantly". We give the platform a generous ceiling and
          // enforce the real 1.2 s end-of-speech pause ourselves, armed only
          // once words have actually arrived (see _armSilenceTimer).
          pauseFor: maxListen,
          listenFor: maxListen,
          localeId: localeId,
        ),
      );
    } catch (e) {
      _lastError = 'Could not start listening';
      _onFinal = null;
      return const _ListenOutcome(transcript: null, failedFast: true);
    }

    // Safety net: some Android recognisers neither deliver a final result nor
    // a terminal status. Fall back to the newest partial.
    _hardStop?.cancel();
    _hardStop = null;
    if (!completer.isCompleted) {
      _hardStop = Timer(maxListen + const Duration(seconds: 2), () async {
        try {
          await _speech.stop();
        } catch (_) {/* ignore */}
        finish(_lastTranscript);
      });
    }

    final result = await completer.future;
    _onFinal = null;

    // "Failed fast" means the engine rejected this configuration rather than
    // listening and hearing silence.
    //
    // Deliberately NOT conditioned on an error callback: Google's on-device
    // recogniser, asked for a locale whose model is not installed, simply
    // reports `done` ~200 ms after start with no error and no words. The
    // reliable signal is the timing — the listen window is 8 s, and a human
    // cannot deliver an utterance in under a second, so a session that
    // produced nothing and ended almost immediately did not hear silence, it
    // declined to listen.
    final elapsed = DateTime.now().difference(startedAt);
    final failedFast = result == null &&
        !_sawPartial &&
        elapsed < const Duration(milliseconds: 800);

    debugPrint('VoiceService: rung "${attempt.label}" ended after '
        '${elapsed.inMilliseconds}ms — '
        'transcript=${result == null ? "none" : "yes"} '
        'partials=$_sawPartial err=${_attemptError ?? "none"} '
        '${failedFast ? "=> REFUSED, trying next rung" : "=> accepted as final"}');

    return _ListenOutcome(transcript: result, failedFast: failedFast);
  }

  /// Ends the current listen session early (user tapped stop / dismissed the
  /// sheet). Safe to call when nothing is running.
  Future<void> stop() async {
    _hardStop?.cancel();
    _hardStop = null;
    _silence?.cancel();
    _silence = null;
    _listening = false;
    try {
      if (_speech.isListening) await _speech.stop();
    } catch (_) {/* plugin missing — nothing to stop */}
    final f = _onFinal;
    if (f != null) f(_lastTranscript);
  }

  /// Cancels without keeping the partial transcript.
  Future<void> cancel() async {
    _hardStop?.cancel();
    _hardStop = null;
    _silence?.cancel();
    _silence = null;
    _listening = false;
    _lastTranscript = '';
    try {
      if (_speech.isListening) await _speech.cancel();
    } catch (_) {/* ignore */}
    final f = _onFinal;
    if (f != null) f(null);
  }

  /// Releases the listen session. Deliberately does NOT close the broadcast
  /// controller: this is a singleton and a closed controller would break the
  /// next mic tap with "Cannot add event after closing".
  void dispose() {
    _hardStop?.cancel();
    _hardStop = null;
    _silence?.cancel();
    _silence = null;
    _listening = false;
    try {
      if (_speech.isListening) _speech.cancel();
    } catch (_) {/* ignore */}
    final f = _onFinal;
    if (f != null) f(null);
    _onFinal = null;
  }

  /// Convenience: listen, then parse. Returns null when nothing was heard.
  Future<PayIntent?> listenAndParse({Duration? timeout}) async {
    final transcript = await listenOnce(timeout: timeout);
    if (transcript == null) return null;
    return parse(transcript);
  }

  // ── Recent payees (read-only, defensive) ────────────────────────────────

  /// Most-recently-paid counterparties from the local `payment_blobs` table,
  /// newest first.
  ///
  /// Reads ONLY `receiver_id` and `timestamp` — other agents are adding
  /// columns to that table concurrently, and the whole thing is wrapped so a
  /// schema change or a missing DB can never break the voice flow. Names come
  /// from [AppConstants.demoContacts] because the blob table stores no name.
  Future<List<RecentPayee>> loadRecentPayees({int limit = 5}) async {
    try {
      final db = await OfflineStorage().database;
      final rows = await db.rawQuery(
        'SELECT receiver_id, MAX(timestamp) AS ts FROM payment_blobs '
        'GROUP BY receiver_id ORDER BY ts DESC LIMIT ?',
        [limit],
      );

      final byId = <String, DemoContact>{
        for (final c in AppConstants.demoContacts.values) c.id: c,
      };

      final out = <RecentPayee>[];
      for (final row in rows) {
        final id = row['receiver_id'] as String?;
        if (id == null || id.isEmpty) continue;
        final known = byId[id];
        out.add(RecentPayee(
          id: id,
          name: known?.name ?? 'Payee ${id.substring(0, id.length.clamp(0, 6))}',
          lastPaidAt: DateTime.tryParse('${row['ts'] ?? ''}'),
        ));
      }
      return out;
    } catch (_) {
      // No DB yet, schema drift, or running under `flutter test`.
      return const [];
    }
  }

  // ── Internals ───────────────────────────────────────────────────────────

  void Function(String?)? _onFinal;

  void _emitPartial(String text) {
    final c = _partialsController;
    if (c != null && !c.isClosed) c.add(text);
  }

  Future<bool> _ensureMicPermission() async {
    try {
      var status = await Permission.microphone.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) {
        _lastError = 'Microphone permission is blocked in Settings';
        return false;
      }
      status = await Permission.microphone.request();
      if (status.isGranted) return true;
      _lastError = 'Microphone permission denied';
      return false;
    } catch (_) {
      // permission_handler is not registered (tests / desktop). Let
      // speech_to_text's own initialize() be the arbiter instead of failing
      // hard here.
      return true;
    }
  }

  /// hi_IN when the device has it, else en_IN, else the system default
  /// (null == let the platform choose).
  Future<String?> _pickLocale() async {
    try {
      final locales = await _speech.locales();
      debugPrint('VoiceService: ${locales.length} locales available; '
          'indic=${locales.where((l) => RegExp(r"^(hi|bn|ta|te|mr|gu|kn|ml|pa|ur)").hasMatch(l.localeId.toLowerCase())).map((l) => l.localeId).join(",")}; '
          'en=${locales.where((l) => l.localeId.toLowerCase().startsWith("en")).map((l) => l.localeId).take(6).join(",")}');
      String? match(bool Function(String id) test) {
        for (final l in locales) {
          if (test(l.localeId.replaceAll('-', '_'))) return l.localeId;
        }
        return null;
      }

      final hi = match((id) => id.toLowerCase() == 'hi_in') ??
          match((id) => id.toLowerCase().startsWith('hi'));
      if (hi != null) return hi;

      final enIn = match((id) => id.toLowerCase() == 'en_in');
      if (enIn != null) return enIn;

      final system = await _speech.systemLocale();
      return system?.localeId;
    } catch (_) {
      return null;
    }
  }

  void _onError(SpeechRecognitionError error) {
    _lastError = error.errorMsg;
    _attemptError = error.errorMsg;
    // Close the session so the ladder can move on. Whether the error is
    // "permanent" is not the useful question — an unusable configuration
    // reports error_language_unavailable / error_client, and we want to try
    // the next rung either way.
    final f = _onFinal;
    if (f != null) f(_lastTranscript);
  }

  void _onStatus(String status) {
    if (status == SpeechToText.notListeningStatus) {
      // Speech has ENDED but the result is not in yet. The plugin now arms its
      // own `finalTimeout` (2s) window, during which the engine usually
      // delivers the full final transcript — and only then emits 'done'.
      // Completing here would truncate the utterance to whatever partial was
      // current at end-of-speech ("ramesh ko do" → ₹2), so we only stop the
      // spinner and wait.
      _listening = false;
      return;
    }
    if (status == SpeechToText.doneStatus) {
      // Genuinely terminal. Some Android recognisers get here without ever
      // sending a final result, so fall back to the newest partial rather
      // than hanging the sheet.
      _listening = false;
      final f = _onFinal;
      if (f != null) f(_lastTranscript);
    }
  }
}

/// One rung of the recogniser fallback ladder.
class _ListenAttempt {
  final bool onDevice;
  final bool preferHindi;
  final String label;
  const _ListenAttempt({
    required this.onDevice,
    required this.preferHindi,
    required this.label,
  });
}

class _ListenOutcome {
  final String? transcript;

  /// True when the engine refused the configuration rather than listening.
  final bool failedFast;
  const _ListenOutcome({required this.transcript, required this.failedFast});
}
