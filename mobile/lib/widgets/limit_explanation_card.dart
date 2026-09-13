import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/constants.dart';
import '../config/theme.dart';
import '../ml/edge_limit_engine.dart';
import '../services/limit_explanation_service.dart';

/// The GenAI risk explainer card (Feature D, mobile side).
///
/// Sits directly under the offline-limit badge on the dashboard: a white
/// 16px-radius card whose headline expands to reveal the "why" and a tip.
/// A compact `EN | हिं` toggle in the top-right switches language.
///
/// Feature I3: when offline (or the fetch fails) and the on-device edge
/// engine has repriced the limit since the server last spoke, the card shows
/// a template explanation built from the engine's own factors instead of the
/// stale server copy, marked "computed on-device".
///
/// Never blocks the dashboard: if there is no cache and no network it
/// renders [SizedBox.shrink] rather than a spinner that cannot resolve.
///
/// Mount it with the shared key so the dashboard can force a re-fetch:
/// ```dart
/// LimitExplanationCard(key: LimitExplanationCard.globalKey)
/// ...
/// LimitExplanationCard.globalKey.currentState?.refresh();
/// ```
class LimitExplanationCard extends StatefulWidget {
  /// Opt-in key for dashboard-driven refreshes. Pass it explicitly; it is
  /// deliberately not the default key so more than one card (or a widget
  /// test) can never collide on it.
  static final GlobalKey<LimitExplanationCardState> globalKey =
      GlobalKey<LimitExplanationCardState>();

  /// Called with the new language code (`'en'` or `'hi'`) after a toggle.
  final ValueChanged<String>? onLangChanged;

  const LimitExplanationCard({super.key, this.onLangChanged});

  @override
  LimitExplanationCardState createState() => LimitExplanationCardState();
}

class LimitExplanationCardState extends State<LimitExplanationCard> {
  final LimitExplanationService _service = LimitExplanationService();
  final EdgeLimitEngine _edge = EdgeLimitEngine();

  LimitExplanation? _data;
  String _lang = 'en';
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    if (AppConstants.riskExplainerEnabled) {
      _edge.latest.addListener(_onEdgeReprice);
      _bootstrap();
    }
  }

  @override
  void dispose() {
    _edge.latest.removeListener(_onEdgeReprice);
    super.dispose();
  }

  /// Forces a re-fetch. Call this from the dashboard after a sync completes.
  /// Resolves even when offline (it simply re-reads the cache).
  Future<void> refresh() => _fetch(force: true);

  /// Opens the details (the dashboard's badge tap scrolls here first).
  void expand() {
    if (!mounted || _expanded) return;
    setState(() => _expanded = true);
  }

  // ── Loading ───────────────────────────────────────────────────

  Future<void> _bootstrap() async {
    final lang = await _service.getLang();
    if (!mounted) return;
    setState(() => _lang = lang);

    // Paint something before the network answers so there is no flicker:
    // a fresher on-device explanation first, else the server cache.
    final first =
        await _edge.offlineExplanation(lang) ?? await _service.cached(lang: lang);
    if (!mounted) return;
    if (first != null) setState(() => _data = first);

    await _fetch();
  }

  Future<void> _fetch({bool force = false}) async {
    LimitExplanation? result;
    try {
      result = await _service.load(forceRefresh: force);
    } catch (_) {
      result = null; // the service already swallows failures; belt and braces
    }
    // Offline or the request failed: the edge engine's own explanation beats
    // a cached server copy that predates the on-device reprice.
    if (result == null || result.fromCache) {
      result = await _edge.offlineExplanation(_lang) ?? result;
    }
    if (!mounted || result == null) return;
    setState(() => _data = result);
  }

  /// A reprice while the card shows cached or on-device copy: rebuild it
  /// locally, with no network round-trip.
  Future<void> _onEdgeReprice() async {
    final current = _data;
    if (current != null && !current.fromCache && !current.isOnDevice) return;
    final edge = await _edge.offlineExplanation(_lang);
    if (!mounted || edge == null) return;
    setState(() => _data = edge);
  }

  Future<void> _switchLang(String lang) async {
    if (lang == _lang) return;
    await _service.setLang(lang);
    if (!mounted) return;
    setState(() => _lang = lang);

    // Notify immediately — not after the fetch, which can take 20s on a
    // degraded network.
    widget.onLangChanged?.call(lang);

    // Offline, the other language's copy shows instantly: rebuilt on-device
    // when that is what is on screen, else the cache (if we ever fetched
    // it). If there is none we keep the current copy on screen rather than
    // blanking the card mid-demo.
    final LimitExplanation? instant = _data?.isOnDevice == true
        ? await _edge.offlineExplanation(lang)
        : await _service.cached(lang: lang);
    if (!mounted) return;
    if (instant != null) setState(() => _data = instant);

    await _fetch(force: true);
  }

  // ── Rendering ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!AppConstants.riskExplainerEnabled) return const SizedBox.shrink();

    final data = _data;
    // No cache and nothing fetched yet: stay invisible. Deliberately not a
    // spinner — offline, it would never resolve.
    if (data == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE6E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(data),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              firstChild: const SizedBox(width: double.infinity, height: 0),
              secondChild: _details(data),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              sizeCurve: Curves.easeOut,
            ),
            if (data.isOnDevice)
              _onDeviceLabel(data)
            else if (data.fromCache)
              _asOfLabel(data),
          ],
        ),
      ),
    );
  }

  Widget _header(LimitExplanation data) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            data.headline,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppTheme.navyBlue,
              height: 1.25,
            ),
          ),
        ),
        if (data.isAiGenerated) ...[
          const SizedBox(width: 8),
          const _AiBadge(),
        ],
        const SizedBox(width: 8),
        _LangToggle(lang: _lang, onChanged: _switchLang),
        const SizedBox(width: 2),
        Icon(
          _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          size: 20,
          color: Colors.grey.shade500,
        ),
      ],
    );
  }

  Widget _details(LimitExplanation data) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            data.body,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: Colors.grey.shade800,
            ),
          ),
          if (data.tip.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.lightbulb_outline,
                  size: 16,
                  color: AppTheme.orange,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    data.tip,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.orange,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _asOfLabel(LimitExplanation data) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'as of ${_formatTime(data.generatedAt)}',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
      ),
    );
  }

  /// Subtle marker for copy the phone wrote itself from the edge engine.
  Widget _onDeviceLabel(LimitExplanation data) {
    final text = _lang == 'hi'
        ? 'phone par calculate hua · ${_formatTime(data.generatedAt)}'
        : 'computed on-device · as of ${_formatTime(data.generatedAt)}';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(Icons.memory, size: 12, color: Colors.grey.shade500),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ),
        ],
      ),
    );
  }

  /// `h:mm a` via intl, with a manual fallback so an uninitialised device
  /// locale can never throw inside build().
  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    try {
      return DateFormat.jm().format(local);
    } catch (_) {
      final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
      final minute = local.minute.toString().padLeft(2, '0');
      return '$hour12:$minute ${local.hour < 12 ? 'AM' : 'PM'}';
    }
  }
}

/// "AI" pill — shown only when the backend reports `generated_by: "llm"`.
/// The template fallback stays unlabelled on purpose.
class _AiBadge extends StatelessWidget {
  const _AiBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.paytmBlue,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'AI',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Compact `EN | हिं` switch.
class _LangToggle extends StatelessWidget {
  final String lang;
  final ValueChanged<String> onChanged;

  const _LangToggle({required this.lang, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _option('EN', 'en'),
        Text('|', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        _option('हिं', 'hi'),
      ],
    );
  }

  Widget _option(String label, String code) {
    final selected = lang == code;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(code),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppTheme.navyBlue : Colors.grey.shade500,
          ),
        ),
      ),
    );
  }
}
