// Feature H2 — cloud speech-to-text via the backend's Gnani Prisma proxy.
//
// Record-then-send: capture one short 16 kHz mono 16-bit WAV, stop on our own
// end-of-speech detector, upload it to POST /api/ai/transcribe, map the reply.
// The provider key lives on the backend only; this file knows nothing but our
// own API.
//
// Failure contract: anything that stops us getting a transcript from the
// backend — a 503 `{"fallback": true}`, a transport error, a timeout, an
// unusable body, a recorder that will not start — throws [GnaniUnavailable].
// "Nobody spoke" and "cancelled" resolve null instead. The temp WAV is always
// deleted.
//
// Plugins (`record`, `path_provider`) are only touched inside [listenOnce]
// through injectable seams, so constructing this engine is free and the whole
// class is unit-testable without platform channels.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../config/constants.dart';
import '../api_service.dart';
import 'stt_engine.dart';

/// The slice of a recorder this engine needs. Production: [RecordPackageRecorder].
abstract class RecorderPort {
  /// Starts writing a 16 kHz mono PCM16 WAV to [path].
  Future<void> start(String path);

  /// Microphone level in dBFS (≤ 0), sampled every [interval].
  Stream<double> amplitudeDbfs(Duration interval);

  /// Finalises the file. Resolves with its path.
  Future<String?> stop();

  /// Stops and discards the recording.
  Future<void> cancel();

  Future<void> dispose();
}

/// [RecorderPort] backed by `record` 7.x. The platform recorder is created on
/// first use, never in a constructor.
class RecordPackageRecorder implements RecorderPort {
  AudioRecorder? _recorder;
  AudioRecorder get _r => _recorder ??= AudioRecorder();

  static const RecordConfig config = RecordConfig(
    encoder: AudioEncoder.wav, // PCM 16-bit
    sampleRate: 16000,
    numChannels: 1,
  );

  @override
  Future<void> start(String path) => _r.start(config, path: path);

  @override
  Stream<double> amplitudeDbfs(Duration interval) =>
      _r.onAmplitudeChanged(interval).map((a) => a.current);

  @override
  Future<String?> stop() => _r.stop();

  @override
  Future<void> cancel() => _r.cancel();

  @override
  Future<void> dispose() async {
    final r = _recorder;
    _recorder = null;
    if (r != null) await r.dispose();
  }
}

/// Sends the recorded file; resolves with the decoded 200 body. Non-2xx must
/// surface as [ApiException] with its status (what [ApiService.postMultipart]
/// does).
typedef TranscribeUploader = Future<Map<String, dynamic>> Function({
  required String filePath,
  required String lang,
});

class GnaniSttEngine implements SttEngine {
  GnaniSttEngine({
    RecorderPort Function()? recorderFactory,
    TranscribeUploader? uploader,
    Future<Directory> Function()? tempDir,
    this.speechThresholdDbfs = AppConstants.gnaniSpeechThresholdDbfs,
    this.silenceAfterSpeech = AppConstants.voicePauseFor,
    this.noSpeechTimeout = AppConstants.gnaniNoSpeechTimeout,
    this.maxRecord = AppConstants.gnaniMaxRecord,
    this.uploadTimeout = AppConstants.gnaniUploadTimeout,
    this.amplitudeInterval = const Duration(milliseconds: 100),
  })  : _recorderFactory = recorderFactory ?? RecordPackageRecorder.new,
        _uploader = uploader,
        _tempDir = tempDir ?? getTemporaryDirectory;

  final RecorderPort Function() _recorderFactory;
  final TranscribeUploader? _uploader;
  final Future<Directory> Function() _tempDir;

  final double speechThresholdDbfs;
  final Duration silenceAfterSpeech;
  final Duration noSpeechTimeout;
  final Duration maxRecord;
  final Duration uploadTimeout;
  final Duration amplitudeInterval;

  /// Emitted on [partials] once recording ends and the upload starts.
  static const String uploadingMarker = '…';

  /// Languages the sheet may ask for; anything else falls back to Hindi.
  static const Set<String> supportedLangs = {'hi-IN', 'en-IN'};

  _GnaniSession? _session;

  StreamController<String>? _partialsController;
  StreamController<double>? _levelsController;

  @override
  String get id => SttProvider.gnani;

  /// True while recording or uploading.
  bool get isBusy => _session != null;

  @override
  Stream<String> get partials {
    final c = _partialsController;
    if (c == null || c.isClosed) {
      _partialsController = StreamController<String>.broadcast();
    }
    return _partialsController!.stream;
  }

  @override
  Stream<double> get levels {
    final c = _levelsController;
    if (c == null || c.isClosed) {
      _levelsController = StreamController<double>.broadcast();
    }
    return _levelsController!.stream;
  }

  /// dBFS → 0..1 for the waveform: -60 dBFS and below is flat, 0 is full.
  static double levelFromDbfs(double dbfs) {
    if (dbfs.isNaN) return 0;
    return ((dbfs + 60) / 60).clamp(0.0, 1.0).toDouble();
  }

  @override
  Future<void> stop() async => _session?.end(_StopReason.userStop);

  @override
  Future<void> cancel() async => _session?.end(_StopReason.cancelled);

  @override
  Future<SttResult?> listenOnce({Duration? timeout, String? lang}) async {
    // One capture at a time.
    await _session?.end(_StopReason.cancelled);

    final language = supportedLangs.contains(lang) ? lang! : 'hi-IN';
    final session = _GnaniSession();
    _session = session;

    RecorderPort? recorder;
    final paths = <String>{};
    try {
      final String path;
      try {
        final dir = await _tempDir();
        path = '${dir.path}${Platform.pathSeparator}'
            'setupay_voice_${DateTime.now().microsecondsSinceEpoch}.wav';
        paths.add(path);
        recorder = _recorderFactory();
        await recorder.start(path);
      } catch (e) {
        throw GnaniUnavailable('could not start recording: $e');
      }

      final reason = await _awaitEndOfSpeech(
        recorder,
        session,
        hardCap: timeout ?? maxRecord,
      );

      if (reason == _StopReason.cancelled || reason == _StopReason.noSpeech) {
        await _quietly(recorder.cancel);
        return null;
      }

      String recorded;
      try {
        recorded = await recorder.stop() ?? path;
      } catch (e) {
        throw GnaniUnavailable('could not finish recording: $e');
      }
      paths.add(recorded);

      _emitPartial(uploadingMarker);
      final body = await _upload(recorded, language);
      if (session.isCancelled) return null;
      return _mapResponse(body, language);
    } finally {
      if (recorder != null) await _quietly(recorder.dispose);
      for (final p in paths) {
        await _quietly(() async {
          final f = File(p);
          if (await f.exists()) await f.delete();
        });
      }
      if (identical(_session, session)) _session = null;
      _emitLevel(0);
    }
  }

  // ── Internals ───────────────────────────────────────────────────────────

  /// Resolves when recording should end:
  ///   * speech was heard and then [silenceAfterSpeech] passed without any;
  ///   * [noSpeechTimeout] passed with level samples but none above the
  ///     threshold (resolves [_StopReason.noSpeech] — nothing to upload);
  ///   * [hardCap];
  ///   * [stop] / [cancel].
  /// A recorder that never reports a level is not treated as silence — we
  /// record to the hard cap and let the server decide.
  Future<_StopReason> _awaitEndOfSpeech(
    RecorderPort recorder,
    _GnaniSession session, {
    required Duration hardCap,
  }) async {
    var heardSpeech = false;
    var sawSample = false;
    Timer? silence;

    final hard = Timer(hardCap, () => session.end(_StopReason.hardCap));
    final noSpeech = Timer(noSpeechTimeout, () {
      if (!heardSpeech && sawSample) session.end(_StopReason.noSpeech);
    });

    StreamSubscription<double>? sub;
    try {
      sub = recorder.amplitudeDbfs(amplitudeInterval).listen(
        (dbfs) {
          sawSample = true;
          _emitLevel(levelFromDbfs(dbfs));
          if (dbfs > speechThresholdDbfs) {
            heardSpeech = true;
            silence?.cancel();
            silence = Timer(
              silenceAfterSpeech,
              () => session.end(_StopReason.speechEnded),
            );
          }
        },
        onError: (Object _) {/* level is cosmetic; keep recording */},
        cancelOnError: false,
      );
    } catch (_) {
      // No level stream at all: the hard cap still ends the recording.
    }

    final reason = await session.ended;
    hard.cancel();
    noSpeech.cancel();
    silence?.cancel();
    await _quietly(() async => sub?.cancel());
    return reason;
  }

  Future<Map<String, dynamic>> _upload(String filePath, String lang) async {
    try {
      final upload = _uploader ?? _defaultUploader;
      return await upload(filePath: filePath, lang: lang).timeout(uploadTimeout);
    } on ApiException catch (e) {
      throw GnaniUnavailable(e.message, statusCode: e.statusCode);
    } on TimeoutException {
      throw const GnaniUnavailable('transcription timed out');
    } catch (e) {
      throw GnaniUnavailable('upload failed: $e');
    }
  }

  Future<Map<String, dynamic>> _defaultUploader({
    required String filePath,
    required String lang,
  }) {
    return ApiService().postMultipart(
      AppConstants.transcribeEndpoint,
      fields: {'lang': lang},
      fileField: 'audio_file',
      filePath: filePath,
      contentType: http.MediaType('audio', 'wav'),
      timeout: uploadTimeout,
    );
  }

  /// 200 body → [SttResult]. Null for an empty transcript (nothing heard).
  SttResult? _mapResponse(Map<String, dynamic> body, String requestedLang) {
    if (body['fallback'] == true) {
      throw GnaniUnavailable('${body['reason'] ?? 'provider fallback'}');
    }
    final transcript = body['transcript'];
    if (transcript is! String) {
      throw const GnaniUnavailable('malformed transcription response');
    }
    if (transcript.trim().isEmpty) return null;

    final provider = body['provider'];
    final lang = body['lang'];
    final entities = body['entities'];

    return SttResult(
      transcript: transcript.trim(),
      provider: provider is String && provider.isNotEmpty
          ? provider
          : SttProvider.gnani,
      amountEntity: entities is Map ? _amount(entities['amount']) : null,
      lang: lang is String && lang.isNotEmpty ? lang : requestedLang,
      latencyMs: _int(body['latency_ms']),
    );
  }

  static double? _amount(Object? raw) {
    final v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
    if (v == null || !v.isFinite || v <= 0) return null;
    return v;
  }

  static int? _int(Object? raw) {
    if (raw is num && raw.isFinite) return raw.round();
    return int.tryParse('${raw ?? ''}');
  }

  void _emitPartial(String text) {
    final c = _partialsController;
    if (c != null && !c.isClosed) c.add(text);
  }

  void _emitLevel(double level) {
    final c = _levelsController;
    if (c != null && !c.isClosed) c.add(level);
  }

  static Future<void> _quietly(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {/* best effort */}
  }
}

enum _StopReason { speechEnded, noSpeech, hardCap, userStop, cancelled }

class _GnaniSession {
  final Completer<_StopReason> _ended = Completer<_StopReason>();
  bool isCancelled = false;

  Future<_StopReason> get ended => _ended.future;

  Future<void> end(_StopReason reason) async {
    if (reason == _StopReason.cancelled) isCancelled = true;
    if (!_ended.isCompleted) _ended.complete(reason);
  }
}
