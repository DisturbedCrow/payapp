// Feature G — the mic bottom sheet.
//
//   final intent = await showVoicePaySheet(context);
//   if (intent == null) { /* user cancelled or chose "Type instead" */ }
//
// Owns nothing but the listening UX: it returns a parsed [PayIntent] and lets
// the caller decide what to do with it. No payment objects are created here.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/constants.dart';
import '../../config/theme.dart';
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
    final mode = VoiceService().activeMode;
    final err = VoiceService().lastError;
    const base = 'Try again — say something like '
        '“Jyati ko do sau rupaye bhejo”.';
    if (err != null && err.isNotEmpty) {
      return '$base\n\n(recogniser: ${mode ?? 'unknown'} · $err)';
    }
    if (mode != null) return '$base\n\n(recogniser: $mode)';
    return base;
  }

  final VoiceService _voice = VoiceService();

  late final AnimationController _pulse;
  _SheetPhase _phase = _SheetPhase.starting;
  String _partial = '';
  String? _reason;

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
    // Stop the mic but never tear down the shared service — it is a singleton
    // and the next mic tap needs it alive.
    _voice.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final ok = await _voice.init();
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _phase = _SheetPhase.unavailable;
        _reason = _voice.lastError ?? 'Voice isn\'t available on this device';
      });
      return;
    }

    setState(() {
      _phase = _SheetPhase.listening;
      _partial = '';
    });
    HapticFeedback.mediumImpact();

    // Live partials keep the sheet feeling instant.
    final sub = _voice.partials.listen((text) {
      if (mounted) setState(() => _partial = text);
    });

    final transcript = await _voice.listenOnce(
      timeout: AppConstants.voiceMaxListen,
    );
    await sub.cancel();
    if (!mounted) return;

    HapticFeedback.mediumImpact();

    if (transcript == null || transcript.trim().isEmpty) {
      setState(() => _phase = _SheetPhase.nothingHeard);
      return;
    }

    setState(() {
      _phase = _SheetPhase.thinking;
      _partial = transcript;
    });

    final intent = parse(transcript);
    if (!mounted) return;
    Navigator.of(context).pop(intent);
  }

  void _cancel() => Navigator.of(context).pop();

  Future<void> _stopEarly() async {
    HapticFeedback.mediumImpact();
    await _voice.stop();
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
    final thinking = _phase == _SheetPhase.thinking;
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
        _voice.activeLocaleId == null
            ? 'Hindi ya English'
            : 'Locale: ${_voice.activeLocaleId}',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
      ),
      const SizedBox(height: 24),
      _pulsingMic(active: !thinking),
      const SizedBox(height: 24),
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 92),
        child: Center(
          child: Text(
            _partial.isEmpty ? '“Jyati ko do sau rupaye bhejo”' : _partial,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _partial.isEmpty ? 16 : 26,
              height: 1.25,
              fontWeight: _partial.isEmpty ? FontWeight.w400 : FontWeight.w700,
              color: _partial.isEmpty ? Colors.grey.shade400 : AppTheme.navyBlue,
            ),
          ),
        ),
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
