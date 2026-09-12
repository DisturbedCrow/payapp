// Feature G — the mandatory confirmation step.
//
// NOTHING is ever paid by voice alone. Every voice utterance lands here and a
// human taps Confirm. This widget is pure presentation + callbacks: it does
// not build PaymentBlobs, touch OfflineStorage, or call any payment service.
//
// NOTE ON THE BASE CLASS: the spec sketched a StatelessWidget, but "Confirm is
// disabled until a candidate is chosen" requires local selection state, so it
// is a StatefulWidget with the *identical* constructor. Call sites are
// unaffected.

import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../services/voice_intent_parser.dart';

String formatRupees(double amount) {
  final whole = amount == amount.roundToDouble();
  return '₹${whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2)}';
}

class VoiceConfirmScreen extends StatefulWidget {
  final PayIntent intent;
  final List<ResolvedRecipient> matches;
  final double availableLimit;
  final void Function(ResolvedRecipient recipient, double amount) onConfirm;
  final VoidCallback onRerecord;
  final void Function(double? amount, String? recipientQuery) onEdit;

  /// Optional: shown in the picker when [matches] is empty, so the user can
  /// still land the payment on someone they have paid before.
  final List<ResolvedRecipient> recentPayees;

  const VoiceConfirmScreen({
    super.key,
    required this.intent,
    required this.matches,
    required this.availableLimit,
    required this.onConfirm,
    required this.onRerecord,
    required this.onEdit,
    this.recentPayees = const [],
  });

  @override
  State<VoiceConfirmScreen> createState() => _VoiceConfirmScreenState();
}

class _VoiceConfirmScreenState extends State<VoiceConfirmScreen> {
  ResolvedRecipient? _selected;

  /// The candidates offered in the picker: the fuzzy matches, or the recent
  /// payees when nothing matched at all.
  List<ResolvedRecipient> get _candidates =>
      widget.matches.isNotEmpty ? widget.matches : widget.recentPayees;

  bool get _needsPicker => widget.matches.length != 1;

  double? get _amount => widget.intent.amount;

  bool get _overLimit =>
      _amount != null && _amount! > widget.availableLimit;

  bool get _canConfirm =>
      _selected != null && _amount != null && _amount! > 0 && !_overLimit;

  @override
  void initState() {
    super.initState();
    if (widget.matches.length == 1) _selected = widget.matches.first;
  }

  void _confirm() {
    final r = _selected;
    final a = _amount;
    if (r == null || a == null) return;
    widget.onConfirm(r, a);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.lightBlue,
      appBar: AppBar(title: const Text('Confirm payment')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            _headline(),
            const SizedBox(height: 14),
            _transcriptQuote(),
            if (_amount == null) ...[
              const SizedBox(height: 16),
              _banner(
                icon: Icons.help_outline_rounded,
                color: AppTheme.orange,
                text: 'Amount samajh nahi aaya — tap Edit to type it, '
                    'or Re-record.',
              ),
            ],
            if (_overLimit) ...[
              const SizedBox(height: 16),
              _banner(
                icon: Icons.error_outline_rounded,
                color: AppTheme.red,
                text: 'Offline limit ke bahar — '
                    '${formatRupees(widget.availableLimit)} available',
              ),
            ],
            if (_needsPicker) ...[
              const SizedBox(height: 22),
              _pickerSection(),
            ],
            const SizedBox(height: 26),
            _actions(),
            const SizedBox(height: 14),
            _confidenceFooter(),
          ],
        ),
      ),
    );
  }

  // ── Headline: ₹200 → Ramesh ─────────────────────────────────────────────

  Widget _headline() {
    final name = _selected?.name ??
        (widget.intent.recipientQuery == null
            ? 'Kise bhejein?'
            : '“${widget.intent.recipientQuery}”');
    final unknownPayee = _selected == null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.navyBlue.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            _amount == null ? '₹—' : formatRupees(_amount!),
            style: TextStyle(
              fontSize: 46,
              fontWeight: FontWeight.w800,
              height: 1.05,
              color: _overLimit ? AppTheme.red : AppTheme.navyBlue,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.arrow_forward_rounded,
                  size: 20, color: Colors.grey.shade500),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: unknownPayee ? Colors.grey.shade600 : AppTheme.navyBlue,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _transcriptQuote() {
    final t = widget.intent.transcript;
    return Center(
      child: Text(
        t.isEmpty ? '“…”' : '“$t”',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 15,
          fontStyle: FontStyle.italic,
          color: Colors.grey.shade600,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _banner({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Picker ──────────────────────────────────────────────────────────────

  Widget _pickerSection() {
    final candidates = _candidates;

    if (candidates.isEmpty) {
      return _banner(
        icon: Icons.person_search_rounded,
        color: AppTheme.orange,
        text: widget.intent.recipientQuery == null
            ? 'No payee heard. Tap Edit to choose one, or Re-record.'
            : 'Koi contact match nahi hua for '
                '“${widget.intent.recipientQuery}”. Tap Edit or Re-record.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.matches.isEmpty ? 'Recent payees' : 'Kise bhejna hai?',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppTheme.navyBlue,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Pick one to enable Confirm',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        ...candidates.map(_candidateTile),
      ],
    );
  }

  Widget _candidateTile(ResolvedRecipient r) {
    final selected = _selected?.id == r.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _selected = r),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? AppTheme.navyBlue : Colors.grey.shade300,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor:
                    selected ? AppTheme.navyBlue : AppTheme.lightBlue,
                child: Text(
                  r.name.isEmpty ? '?' : r.name.characters.first.toUpperCase(),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppTheme.navyBlue,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.name,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.navyBlue,
                      ),
                    ),
                    Text(
                      'match ${(r.score * 100).round()}%',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? AppTheme.navyBlue : Colors.grey.shade400,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  Widget _actions() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _canConfirm ? _confirm : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.green,
              disabledBackgroundColor: Colors.grey.shade300,
              padding: const EdgeInsets.symmetric(vertical: 17),
            ),
            icon: const Icon(Icons.check_circle_outline_rounded),
            label: Text(
              _amount == null
                  ? 'Confirm'
                  : 'Confirm ${formatRupees(_amount!)}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: widget.onRerecord,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.navyBlue,
                  side: const BorderSide(color: AppTheme.navyBlue),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.mic_rounded, size: 18),
                label: const Text('Re-record'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => widget.onEdit(
                  _amount,
                  _selected?.name ?? widget.intent.recipientQuery,
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.navyBlue,
                  side: const BorderSide(color: AppTheme.navyBlue),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Edit'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _confidenceFooter() {
    final pct = (widget.intent.confidence * 100).round();
    final low = widget.intent.confidence < 0.75;
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            low ? Icons.info_outline_rounded : Icons.verified_outlined,
            size: 15,
            color: low ? AppTheme.orange : Colors.grey.shade500,
          ),
          const SizedBox(width: 6),
          Text(
            low
                ? 'Low confidence ($pct%) — please double-check'
                : 'Heard with $pct% confidence',
            style: TextStyle(
              fontSize: 12,
              color: low ? AppTheme.orange : Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }
}
