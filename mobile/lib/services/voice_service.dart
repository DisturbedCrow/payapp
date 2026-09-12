// Feature G — thin, crash-proof wrapper around `speech_to_text`.
//
// CONTRACT: every method here is safe to call when the plugin is missing
// (unit tests, emulators without a recogniser, a phone with the Google app
// disabled). `init()` returns false and everything else no-ops, so the demo
// degrades to typed input instead of throwing. Nothing in this file is ever
// allowed to propagate an exception to the UI.

import 'dart:async';

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

  StreamController<String>? _partialsController;
  Completer<String?>? _session;
  Timer? _hardStop;
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
    if (_initialised) return _available;
    _initialised = true;

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
      return true;
    } catch (e) {
      // MissingPluginException in tests, or any platform-side failure.
      _available = false;
      _lastError = 'Speech engine unavailable';
      return false;
    }
  }

  /// Runs one listen session and resolves with the final transcript.
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

    // Only one session at a time.
    if (_session != null && !_session!.isCompleted) {
      await stop();
    }

    final completer = Completer<String?>();
    _session = completer;
    _lastTranscript = '';
    _listening = true;

    void finish(String? value) {
      if (completer.isCompleted) return;
      _listening = false;
      _hardStop?.cancel();
      _hardStop = null;
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
          _emitPartial(r.recognizedWords);
          if (r.finalResult) finish(r.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          // EXTRA_PREFER_OFFLINE on Android: a preference, not a hard fail, so
          // it is safe to always set and it is what makes the demo airplane-
          // mode-proof once the Hindi pack is downloaded.
          onDevice: true,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          pauseFor: AppConstants.voicePauseFor,
          listenFor: maxListen,
          localeId: _activeLocaleId,
        ),
      );
    } catch (e) {
      _lastError = 'Could not start listening';
      finish(null);
      _onFinal = null;
      return completer.future;
    }

    // Safety net: some Android recognisers neither deliver a final result nor
    // a terminal status. Fall back to the newest partial.
    _hardStop?.cancel();
    _hardStop = Timer(maxListen + const Duration(seconds: 2), () async {
      try {
        await _speech.stop();
      } catch (_) {/* ignore */}
      finish(_lastTranscript);
    });

    final result = await completer.future;
    _onFinal = null;
    return result;
  }

  /// Ends the current listen session early (user tapped stop / dismissed the
  /// sheet). Safe to call when nothing is running.
  Future<void> stop() async {
    _hardStop?.cancel();
    _hardStop = null;
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
    if (error.permanent) {
      final f = _onFinal;
      if (f != null) f(_lastTranscript);
    }
  }

  void _onStatus(String status) {
    // 'done' / 'notListening' are the terminal states. Android sometimes
    // reaches them without ever sending a final result, so resolve with the
    // newest partial rather than hanging the sheet.
    if (status == 'done' || status == 'notListening') {
      _listening = false;
      final f = _onFinal;
      if (f != null) f(_lastTranscript);
    }
  }
}
