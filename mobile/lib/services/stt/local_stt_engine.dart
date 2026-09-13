// Feature H2 — the on-device engine: a thin adapter over VoiceService.
//
// The recogniser ladder in VoiceService (offline hi-IN → online hi-IN →
// device default, plus its own silence timer) was hard-won against Android
// mic-closing bugs. This file deliberately adds no behaviour of its own.

import 'dart:async';

import '../voice_service.dart';
import 'stt_engine.dart';

class LocalSttEngine implements SttEngine {
  LocalSttEngine({VoiceService? voice}) : _voice = voice ?? VoiceService();

  final VoiceService _voice;

  @override
  String get id => SttProvider.onDevice;

  /// [lang] is ignored — the ladder picks the best installed locale itself.
  @override
  Future<SttResult?> listenOnce({Duration? timeout, String? lang}) async {
    final transcript = await _voice.listenOnce(timeout: timeout);
    if (transcript == null || transcript.trim().isEmpty) return null;
    return SttResult(
      transcript: transcript,
      provider: SttProvider.onDevice,
      lang: _voice.activeLocaleId?.replaceAll('_', '-'),
    );
  }

  @override
  Stream<String> get partials => _voice.partials;

  /// The platform recogniser exposes no usable level; the sheet shows live
  /// partials instead.
  @override
  Stream<double> get levels => const Stream<double>.empty();

  @override
  Future<void> stop() => _voice.stop();

  @override
  Future<void> cancel() => _voice.cancel();
}
