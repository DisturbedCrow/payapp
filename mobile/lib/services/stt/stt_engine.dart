// Feature H2 — the speech-to-text engine seam.
//
// PURE DART. No plugins, no Flutter. The parser imports [SttResult] from here,
// and the parser must stay runnable under a plain `flutter test`.
//
// Two engines implement [SttEngine]:
//   * GnaniSttEngine — records a short WAV and sends it to the backend's
//     /api/ai/transcribe (Gnani Prisma). Online only.
//   * LocalSttEngine — the on-device `speech_to_text` recogniser ladder in
//     VoiceService. Works in airplane mode.
// VoiceRouter decides which one runs.

/// Provider ids as they appear in [SttResult.provider].
class SttProvider {
  SttProvider._();
  static const String gnani = 'gnani';
  static const String mock = 'mock';
  static const String onDevice = 'on-device';
}

/// One finished utterance.
class SttResult {
  final String transcript;

  /// The amount the provider extracted itself (Gnani's ITN entity), in rupees.
  /// When present the parser trusts it over the digits in [transcript].
  final double? amountEntity;

  /// 'gnani' | 'mock' | 'on-device' — see [SttProvider].
  final String provider;

  /// BCP-47 code the utterance was transcribed as, e.g. 'hi-IN'.
  final String? lang;

  /// Server-reported transcription latency. Null for on-device.
  final int? latencyMs;

  const SttResult({
    required this.transcript,
    required this.provider,
    this.amountEntity,
    this.lang,
    this.latencyMs,
  });

  @override
  String toString() => 'SttResult($provider, "$transcript", '
      'amount: $amountEntity, lang: $lang, ${latencyMs ?? '-'}ms)';
}

abstract class SttEngine {
  /// Stable id of the engine, one of [SttProvider] (Gnani reports the actual
  /// backend provider in the result, which may be 'mock').
  String get id;

  /// Captures one utterance. Resolves null when nothing was heard or the
  /// capture was cancelled. [lang] is a hint ('hi-IN' / 'en-IN'); engines
  /// that pick their own locale ignore it.
  ///
  /// Throws [GnaniUnavailable] only from the cloud engine, meaning "use the
  /// on-device engine instead".
  Future<SttResult?> listenOnce({Duration? timeout, String? lang});

  /// Live partial transcripts, where the engine has them.
  Stream<String> get partials;

  /// Live microphone level, 0.0 (silence) .. 1.0 (loud), where the engine
  /// can measure it. Used for the waveform while recording.
  Stream<double> get levels;

  /// Ends capture early and keeps what was heard.
  Future<void> stop();

  /// Ends capture and discards it; [listenOnce] resolves null.
  Future<void> cancel();
}

/// The cloud transcriber could not produce a result — backend 503 fallback,
/// a transport failure, a timeout, or an unusable response. The utterance is
/// lost (it was recorded, not streamed), so the caller must ask the user to
/// say it again on-device.
class GnaniUnavailable implements Exception {
  final String reason;
  final int? statusCode;

  const GnaniUnavailable(this.reason, {this.statusCode});

  /// The provider throttled us — a short-lived condition, unlike an outage.
  bool get isRateLimited => reason == 'rate_limited' || statusCode == 429;

  /// Gnani heard nothing it could transcribe: a mumble, a noisy venue, a
  /// clip that was all silence. The service is fine — the next utterance
  /// should still go to the cloud.
  bool get isNoTranscript => reason == 'no_transcript';

  /// Conditions that clear in seconds, so the router backs off briefly
  /// instead of keeping voice on-device for minutes.
  bool get isShortLived => isRateLimited || isNoTranscript;

  @override
  String toString() => 'GnaniUnavailable($reason'
      '${statusCode == null ? '' : ', HTTP $statusCode'})';
}
