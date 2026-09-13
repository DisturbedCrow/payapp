// Feature H2 — GnaniSttEngine with a fake recorder and a fake uploader.
// No `record`, no `path_provider`, no network.
//
//   flutter test test/voice_gnani_engine_test.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/services/api_service.dart';
import 'package:offline_pay/services/stt/gnani_stt_engine.dart';
import 'package:offline_pay/services/stt/stt_engine.dart';

class FakeRecorder implements RecorderPort {
  FakeRecorder({this.samples, this.startError});

  /// Level samples (dBFS) to emit once recording starts. Null == a recorder
  /// that never reports a level.
  final List<double>? samples;
  final Object? startError;

  String? path;
  bool stopped = false;
  bool cancelled = false;
  bool disposed = false;

  @override
  Future<void> start(String path) async {
    final e = startError;
    if (e != null) throw e;
    this.path = path;
    // A real (tiny) file so the engine's cleanup is observable.
    await File(path).writeAsBytes(List<int>.filled(44, 0));
  }

  @override
  Stream<double> amplitudeDbfs(Duration interval) {
    final s = samples;
    if (s == null) return const Stream<double>.empty();
    return Stream<double>.fromIterable(s);
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    return path;
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> dispose() async => disposed = true;
}

/// One loud sample, then quiet: speech detected, then the silence timer ends
/// the recording.
const spoke = <double>[-50, -20, -18, -48];

void main() {
  late Directory tmp;
  late FakeRecorder recorder;
  late List<({String filePath, String lang, bool existed})> uploads;

  GnaniSttEngine engine({
    required TranscribeUploader uploader,
    List<double>? samples = spoke,
    Object? startError,
    Duration uploadTimeout = const Duration(seconds: 2),
    Duration maxRecord = const Duration(milliseconds: 600),
  }) {
    recorder = FakeRecorder(samples: samples, startError: startError);
    return GnaniSttEngine(
      recorderFactory: () => recorder,
      uploader: uploader,
      tempDir: () async => tmp,
      silenceAfterSpeech: const Duration(milliseconds: 40),
      noSpeechTimeout: const Duration(milliseconds: 150),
      maxRecord: maxRecord,
      uploadTimeout: uploadTimeout,
    );
  }

  TranscribeUploader replyWith(Map<String, dynamic> body) =>
      ({required String filePath, required String lang}) async {
        uploads.add((
          filePath: filePath,
          lang: lang,
          existed: File(filePath).existsSync(),
        ));
        return body;
      };

  TranscribeUploader failWith(Object error) =>
      ({required String filePath, required String lang}) async {
        uploads.add((filePath: filePath, lang: lang, existed: true));
        throw error;
      };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gnani_engine_test');
    uploads = [];
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  bool tempDirEmpty() => tmp.listSync().isEmpty;

  group('200 -> SttResult', () {
    test('maps provider, transcript, amount entity, lang and latency',
        () async {
      final e = engine(
        uploader: replyWith({
          'transcript': 'ramesh ko ₹250 bhejo',
          'provider': 'gnani',
          'lang': 'hi-IN',
          'latency_ms': 640,
          'entities': {'amount': 250},
        }),
      );

      final r = await e.listenOnce(lang: 'hi-IN');

      expect(r, isNotNull);
      expect(r!.transcript, 'ramesh ko ₹250 bhejo');
      expect(r.provider, SttProvider.gnani);
      expect(r.amountEntity, 250.0);
      expect(r.lang, 'hi-IN');
      expect(r.latencyMs, 640);

      expect(uploads, hasLength(1));
      expect(uploads.single.lang, 'hi-IN');
      expect(uploads.single.filePath, endsWith('.wav'));
      expect(uploads.single.existed, isTrue,
          reason: 'the WAV must exist when it is uploaded');
      expect(recorder.stopped, isTrue);
      expect(recorder.disposed, isTrue);
      expect(tempDirEmpty(), isTrue, reason: 'temp WAV must be deleted');
    });

    test('mock provider, null amount, en-IN is passed through', () async {
      final e = engine(
        uploader: replyWith({
          'transcript': 'send 1,500 to ramesh',
          'provider': 'mock',
          'lang': 'en-IN',
          'latency_ms': 3,
          'entities': {'amount': null},
        }),
      );
      final r = await e.listenOnce(lang: 'en-IN');
      expect(r!.provider, SttProvider.mock);
      expect(r.amountEntity, isNull);
      expect(r.lang, 'en-IN');
      expect(uploads.single.lang, 'en-IN');
    });

    test('an unsupported language hint is sent as hi-IN', () async {
      final e = engine(uploader: replyWith({'transcript': 'x', 'provider': 'gnani'}));
      await e.listenOnce(lang: 'fr-FR');
      expect(uploads.single.lang, 'hi-IN');
    });

    test('missing optional fields are tolerated', () async {
      final e = engine(uploader: replyWith({'transcript': 'ramesh ko 200'}));
      final r = await e.listenOnce(lang: 'hi-IN');
      expect(r!.provider, SttProvider.gnani);
      expect(r.amountEntity, isNull);
      expect(r.latencyMs, isNull);
      expect(r.lang, 'hi-IN');
    });

    test('an empty transcript means nothing was heard -> null', () async {
      final e = engine(
          uploader: replyWith({'transcript': '  ', 'provider': 'gnani'}));
      expect(await e.listenOnce(), isNull);
      expect(tempDirEmpty(), isTrue);
    });

    test('a recorder with no level stream records to the cap, then uploads',
        () async {
      final e = engine(
        samples: null,
        maxRecord: const Duration(milliseconds: 250),
        uploader: replyWith({'transcript': 'ramesh ko 200', 'provider': 'gnani'}),
      );
      final r = await e.listenOnce();
      expect(r, isNotNull);
      expect(uploads, hasLength(1));
    });
  });

  group('failures -> GnaniUnavailable', () {
    test('503 fallback', () async {
      final e = engine(
        uploader: failWith(ApiException('Request failed', statusCode: 503)),
      );
      await expectLater(
        e.listenOnce(),
        throwsA(isA<GnaniUnavailable>()
            .having((x) => x.statusCode, 'statusCode', 503)),
      );
      expect(tempDirEmpty(), isTrue, reason: 'temp WAV deleted on failure too');
      expect(recorder.disposed, isTrue);
    });

    test('transport error (ApiException with no status)', () async {
      final e = engine(uploader: failWith(ApiException('Could not reach')));
      await expectLater(e.listenOnce(), throwsA(isA<GnaniUnavailable>()));
    });

    test('400 bad file is also a fallback, never a crash', () async {
      final e = engine(
          uploader: failWith(ApiException('bad audio', statusCode: 400)));
      await expectLater(
        e.listenOnce(),
        throwsA(isA<GnaniUnavailable>()
            .having((x) => x.statusCode, 'statusCode', 400)),
      );
    });

    test('timeout', () async {
      final never = Completer<Map<String, dynamic>>();
      final e = engine(
        uploadTimeout: const Duration(milliseconds: 100),
        uploader: ({required String filePath, required String lang}) =>
            never.future,
      );
      final sw = Stopwatch()..start();
      await expectLater(e.listenOnce(), throwsA(isA<GnaniUnavailable>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(tempDirEmpty(), isTrue);
    });

    test('a 200 body that says fallback', () async {
      final e = engine(
        uploader: replyWith({'fallback': true, 'provider': 'gnani', 'reason': 'x'}),
      );
      await expectLater(e.listenOnce(), throwsA(isA<GnaniUnavailable>()));
    });

    test('a malformed body', () async {
      final e = engine(uploader: replyWith({'transcript': 42}));
      await expectLater(e.listenOnce(), throwsA(isA<GnaniUnavailable>()));
    });

    test('a recorder that will not start', () async {
      final e = engine(
        startError: Exception('mic busy'),
        uploader: replyWith({'transcript': 'x'}),
      );
      await expectLater(e.listenOnce(), throwsA(isA<GnaniUnavailable>()));
      expect(uploads, isEmpty);
    });
  });

  group('backend fallback reason survives to GnaniUnavailable', () {
    test('ApiService.fallbackReason reads {"fallback": true, "reason"}', () {
      expect(
        ApiService.fallbackReason(
            '{"fallback": true, "provider": "gnani", "reason": "rate_limited"}'),
        'rate_limited',
      );
      expect(ApiService.fallbackReason('{"detail": "bad lang"}'), isNull);
      expect(ApiService.fallbackReason('{"fallback": false, "reason": "x"}'),
          isNull);
      expect(ApiService.fallbackReason('<html>502</html>'), isNull);
    });

    test('a rate-limited 503 is a rate-limited GnaniUnavailable', () async {
      final e = engine(
        uploader: failWith(ApiException('rate_limited', statusCode: 503)),
      );
      await expectLater(
        e.listenOnce(),
        throwsA(isA<GnaniUnavailable>()
            .having((x) => x.isRateLimited, 'isRateLimited', isTrue)),
      );
    });
  });

  group('no upload when there is nothing to send', () {
    test('no speech within the no-speech window -> null, nothing uploaded',
        () async {
      final e = engine(
        samples: List<double>.filled(3, -55),
        uploader: replyWith({'transcript': 'x'}),
      );
      expect(await e.listenOnce(), isNull);
      expect(uploads, isEmpty);
      expect(recorder.cancelled, isTrue);
      expect(tempDirEmpty(), isTrue);
    });

    test('cancel() while recording -> null, nothing uploaded', () async {
      final e = engine(
        samples: null,
        maxRecord: const Duration(seconds: 5),
        uploader: replyWith({'transcript': 'x'}),
      );
      final pending = e.listenOnce();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(e.isBusy, isTrue);
      await e.cancel();
      expect(await pending, isNull);
      expect(uploads, isEmpty);
      expect(e.isBusy, isFalse);
    });

    test('stop() while recording uploads what was captured', () async {
      final e = engine(
        samples: null,
        maxRecord: const Duration(seconds: 5),
        uploader: replyWith({'transcript': 'ramesh ko 200', 'provider': 'gnani'}),
      );
      final pending = e.listenOnce();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await e.stop();
      expect((await pending)!.transcript, 'ramesh ko 200');
      expect(uploads, hasLength(1));
    });
  });

  group('levels and partials', () {
    test('levelFromDbfs maps -60..0 onto 0..1 and clamps', () {
      expect(GnaniSttEngine.levelFromDbfs(-90), 0);
      expect(GnaniSttEngine.levelFromDbfs(-60), 0);
      expect(GnaniSttEngine.levelFromDbfs(-30), closeTo(0.5, 1e-9));
      expect(GnaniSttEngine.levelFromDbfs(0), 1);
      expect(GnaniSttEngine.levelFromDbfs(3), 1);
      expect(GnaniSttEngine.levelFromDbfs(double.nan), 0);
    });

    test('levels stream while recording, "…" partial while uploading',
        () async {
      final e = engine(
        uploader: replyWith({'transcript': 'ramesh ko 200', 'provider': 'gnani'}),
      );
      final levels = <double>[];
      final partials = <String>[];
      final ls = e.levels.listen(levels.add);
      final ps = e.partials.listen(partials.add);

      await e.listenOnce();
      await Future<void>.delayed(Duration.zero);
      await ls.cancel();
      await ps.cancel();

      expect(levels.where((l) => l > 0.5), isNotEmpty);
      expect(partials, contains(GnaniSttEngine.uploadingMarker));
    });
  });
}
