// Feature G / H2 — the mic bottom sheet.
//
//   final intent = await showVoicePaySheet(context);
//   if (intent == null) { /* user cancelled or chose "Type instead" */ }
//
// Owns nothing but the listening UX: it returns a parsed [PayIntent] (with
// `provider` set to the speech engine that heard it) and lets the caller
// decide what to do with it. No payment objects are created here.
//
// Capture goes through [VoiceRouter]: Gnani Prisma (cloud, record-then-send,
// shown as a level meter) when online, the on-device recogniser (live
// partials) otherwise. If the cloud attempt fails the router switches to
// on-device and this sheet says so — the first utterance is lost, so the user
// is asked to say it again rather than shown a silent retry.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/constants.dart';
import '../../config/theme.dart';
import '../../services/stt/gnani_stt_engine.dart';
import '../../services/stt/stt_engine.dart';
import '../../services/stt/voice_router.dart';
import '../../services/voice_intent_parser.dart';
import '../../services/voice_service.dart';

/// Opens the voice-payment sheet and resolves with the parsed intent, or null
/// when the user cancelled / voice is unavailable / nothing was heard.
Future<PayIntent?> showVoicePaySheet(BuildContext context) {
  return showModalBottomSheet<PayIntent>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true, // swipe-down to cancel
    backgroundColor: Colors.transparent,
    builder: (_) => const _VoicePaySheet(),
  );
}

enum _SheetPhase { starting, listening, thinking, unavailable, nothingHeard }

/// Shown after a cloud failure. Honest: the utterance is gone.
const String _fallbackNotice = 'On-device mode — say it again';

class _VoicePaySheet extends StatefulWidget {
  const _VoicePaySheet();

  @override
  State<_VoicePaySheet> createState() => _VoicePaySheetState();
}

class _VoicePaySheetState extends State<_VoicePaySheet>
    with SingleTickerProviderStateMixin {

  /// What to tell the user when nothing was transcribed. Includes which
  /// recogniser configuration was actually used — without this, "it just
  /// closes" is indistinguishable from "you said nothing", which is exactly
  /// the confusion that cost us an evening.
  String _diagnostic() {
    const base = 'Try again — say something like '
        '“Jyati ko do sau rupaye bhejo”.';
    if (_cloud) return '$base\n\n(recogniser: Gnani Prisma)';
    final mode = VoiceService().activeMode;
    final err = VoiceService().lastError;
    if (err != null && err.isNotEmpty) {
      return '$base\n\n(recogniser: ${mode ?? 'unknown'} · $err)';
    }
    if (mode != null) return '$base\n\n(recogniser: $mode)';
    return base;
  }

  final VoiceService _voice = VoiceService();
  final VoiceRouter _router = VoiceRouter.shared;

  late final AnimationController _pulse;
  _SheetPhase _phase = _SheetPhase.starting;
  String _partial = '';
  String? _reason;

  /// True while the active engine is the cloud one (level meter, no partials).
  bool _cloud = false;

  /// Inline notice after a cloud → on-device switch.
  String? _notice;

  /// Recent mic levels, 0..1, newest last — the waveform.
  final List<double> _levels = [];
  static const int _levelBars = 28;

  StreamSubscription<String>? _partialSub;
  StreamSubscription<double>? _levelSub;

  bool get _uploading =>
      _cloud && _partial == GnaniSttEngine.uploadingMarker;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _pulse.dispose();
    _partialSub?.cancel();
    _levelSub?.cancel();
    // Stop the mic but never tear down the shared services — they are
    // singletons and the next mic tap needs them alive.
    _router.cancel();
    super.dispose();
  }

  /// Pre-flight for [engine]. The on-device engine needs a working recogniser;
  /// the cloud engine only needs the microphone. Sets [_reason] on failure.
  Future<bool> _prepare(SttEngine engine) async {
    if (engine.id == SttProvider.gnani) {
      final ok = await _voice.ensureMicPermission();
      if (!ok) _reason = _voice.lastError ?? 'Microphone permission denied';
      return ok;
    }
    final ok = await _voice.init();
    if (!ok) {
      _reason = _voice.lastError ?? 'Voice isn\'t available on this device';
    }
    return ok;
  }

  /// Points the partial / level listeners at the engine that is listening.
  void _attach(SttEngine engine) {
    _partialSub?.cancel();
    _levelSub?.cancel();
    if (mounted) {
      setState(() {
        _cloud = engine.id == SttProvider.gnani;
        _partial = '';
        _levels.clear();
      });
    }
    // Live partials keep the on-device sheet feeling instant; the cloud
    // engine only ever sends the "uploading" marker here.
    _partialSub = engine.partials.listen((text) {
      if (mounted) setState(() => _partial = text);
    });
    _levelSub = engine.levels.listen((level) {
      if (!mounted) return;
      setState(() {
        _levels.add(level);
        if (_levels.length > _levelBars) _levels.removeAt(0);
      });
    });
  }

  Future<void> _start() async {
    final engine = await _router.selectEngine();
    if (!mounted) return;

    final ready = await _prepare(engine);
    if (!mounted) return;
    if (!ready) {
      setState(() => _phase = _SheetPhase.unavailable);
      return;
    }

    setState(() {
      _phase = _SheetPhase.listening;
      _partial = '';
    });
    HapticFeedback.mediumImpact();

    final capture = await _router.capture(
      engine: engine,
      timeout: AppConstants.voiceMaxListen,
      onEngine: _attach,
      onFallback: (_) async {
        if (!mounted) return false;
        setState(() {
          _notice = _fallbackNotice;
          _phase = _SheetPhase.starting;
          _partial = '';
          _levels.clear();
        });
        HapticFeedback.heavyImpact();
        final ok = await _prepare(_router.local);
        if (!mounted) return false;
        if (!ok) {
          setState(() => _phase = _SheetPhase.unavailable);
          return false;
        }
        setState(() => _phase = _SheetPhase.listening);
        return true;
      },
    );
    await _partialSub?.cancel();
    await _levelSub?.cancel();
    _partialSub = null;
    _levelSub = null;
    if (!mounted || _phase == _SheetPhase.unavailable) return;

    HapticFeedback.mediumImpact();

    final result = capture.result;
    if (result == null || result.transcript.trim().isEmpty) {
      setState(() => _phase = _SheetPhase.nothingHeard);
      return;
    }

    setState(() {
      _phase = _SheetPhase.thinking;
      _partial = result.transcript;
    });

    final intent = parseResult(result);
    if (!mounted) return;
    Navigator.of(context).pop(intent);
  }

  void _cancel() => Navigator.of(context).pop();

  Future<void> _stopEarly() async {
    HapticFeedback.mediumImpact();
    await _router.stop();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 12,
        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _grabber(),
            const SizedBox(height: 20),
            ..._body(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _grabber() => Container(
        width: 44,
        height: 5,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(3),
        ),
      );

  List<Widget> _body() {
    switch (_phase) {
      case _SheetPhase.unavailable:
        return _unavailableBody();
      case _SheetPhase.nothingHeard:
        return _nothingHeardBody();
      case _SheetPhase.starting:
      case _SheetPhase.listening:
      case _SheetPhase.thinking:
        return _listeningBody();
    }
  }

  // ── Listening ───────────────────────────────────────────────────────────

  List<Widget> _listeningBody() {
    final thinking = _phase == _SheetPhase.thinking || _uploading;
    return [
      Text(
        thinking ? 'Samajh raha hoon…' : 'Suniye… boliye',
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppTheme.navyBlue,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        _cloud
            ? 'Gnani Prisma · cloud'
            : _voice.activeLocaleId == null
                ? 'Hindi ya English'
                : 'On-device · ${_voice.activeLocaleId}',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
      ),
      if (_notice != null) ...[
        const SizedBox(height: 10),
        _noticePill(_notice!),
      ],
      const SizedBox(height: 24),
      _pulsingMic(active: !thinking),
      const SizedBox(height: 24),
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 92),
        child: Center(child: _captureText()),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: _cancel,
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: thinking ? null : _stopEarly,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.navyBlue,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        'Swipe down to cancel',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
      ),
    ];
  }

  /// On-device: the live partial (or the hint). Cloud: a level meter and "…"
  /// while recording, "…" while uploading. Both: the transcript once heard.
  Widget _captureText() {
    final heard = _phase == _SheetPhase.thinking;
    if (_cloud && !heard) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_uploading) _waveform(),
          const SizedBox(height: 10),
          Text(
            '…',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      );
    }
    return Text(
      _partial.isEmpty ? '“Jyati ko do sau rupaye bhejo”' : _partial,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: _partial.isEmpty ? 16 : 26,
        height: 1.25,
        fontWeight: _partial.isEmpty ? FontWeight.w400 : FontWeight.w700,
        color: _partial.isEmpty ? Colors.grey.shade400 : AppTheme.navyBlue,
      ),
    );
  }

  Widget _waveform() {
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_levelBars, (i) {
          // Right-align the history so new samples enter from the right.
          final offset = _levelBars - _levels.length;
          final level = i < offset ? 0.0 : _levels[i - offset];
          return AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: 4,
            height: 4 + 44 * level,
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            decoration: BoxDecoration(
              color: AppTheme.navyBlue.withValues(alpha: 0.35 + 0.65 * level),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }

  Widget _noticePill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.orange.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 14, color: AppTheme.orange),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.orange,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pulsingMic({required bool active}) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = active ? _pulse.value : 0.0;
        final halo = 96.0 + 34.0 * t;
        return SizedBox(
          width: 150,
          height: 150,
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: halo,
                  height: halo,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.paytmBlue.withValues(alpha: 0.16 * (1 - t)),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? AppTheme.navyBlue : Colors.grey.shade400,
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.navyBlue.withValues(alpha: 0.28),
                        blurRadius: 18 + 10 * t,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Icon(
                    active ? Icons.mic_rounded : Icons.graphic_eq_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Fallbacks ───────────────────────────────────────────────────────────

  List<Widget> _unavailableBody() => [
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.lightBlue,
          ),
          child: const Icon(Icons.mic_off_rounded,
              size: 36, color: AppTheme.navyBlue),
        ),
        const SizedBox(height: 18),
        const Text(
          'Voice isn\'t available on this device',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppTheme.navyBlue,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _reason ?? 'No speech recogniser found.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _cancel, // null result → caller falls back to typing
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.navyBlue,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            icon: const Icon(Icons.keyboard_rounded),
            label: const Text('Type instead'),
          ),
        ),
      ];

  List<Widget> _nothingHeardBody() => [
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.lightBlue,
          ),
          child: const Icon(Icons.hearing_disabled_rounded,
              size: 36, color: AppTheme.orange),
        ),
        const SizedBox(height: 18),
        const Text(
          'Kuch sunai nahi diya',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppTheme.navyBlue,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _diagnostic(),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.keyboard_rounded, size: 18),
                label: const Text('Type instead'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _phase = _SheetPhase.starting;
                    _partial = '';
                    _notice = null;
                    _levels.clear();
                  });
                  _start();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.navyBlue,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.mic_rounded, size: 18),
                label: const Text('Retry'),
              ),
            ),
          ],
        ),
      ];
}
