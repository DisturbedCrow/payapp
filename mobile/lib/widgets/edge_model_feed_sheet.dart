import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../ml/edge_explainer.dart';
import '../ml/edge_limit_engine.dart';
import '../ml/edge_limit_math.dart';
import '../services/limit_explanation_service.dart';

/// Opens the "Edge model feed" bottom sheet (long-press on the dashboard's
/// offline-limit badge). The rows are the engine's own reprices — in airplane
/// mode this is the proof that the model runs on the phone.
Future<void> showEdgeModelFeed(BuildContext context) async {
  await EdgeLimitEngine().ensureLoaded();
  final lang = await LimitExplanationService().getLang();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => EdgeModelFeedSheet(lang: lang),
  );
}

class EdgeModelFeedSheet extends StatelessWidget {
  /// Defaults to `EdgeLimitEngine().feed`.
  final ValueListenable<List<EdgeReprice>>? feed;
  final String lang;

  const EdgeModelFeedSheet({super.key, this.feed, this.lang = 'en'});

  @override
  Widget build(BuildContext context) {
    final source = feed ?? EdgeLimitEngine().feed;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.memory, color: AppTheme.orange, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Edge model feed',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.navyBlue,
                        ),
                      ),
                      Text(
                        '${EdgeLimitConfig.modelName} · computed on this phone, no network',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<List<EdgeReprice>>(
              valueListenable: source,
              builder: (context, rows, _) {
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No on-device reprices yet. Go offline and make a payment.',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                  );
                }
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.6,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: Colors.grey.shade200),
                    itemBuilder: (_, i) => _FeedRow(entry: rows[i], lang: lang),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedRow extends StatelessWidget {
  final EdgeReprice entry;
  final String lang;

  const _FeedRow({required this.entry, required this.lang});

  static String _clock(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final dropped = entry.newLimit < entry.oldLimit;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _clock(entry.at),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.lightBlue,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  entry.reason,
                  style: const TextStyle(fontSize: 10, color: AppTheme.navyBlue),
                ),
              ),
              const Spacer(),
              Text(
                '${rupees(entry.oldLimit)} → ${rupees(entry.newLimit)}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: dropped ? AppTheme.orange : AppTheme.navyBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'score ${entry.score.toStringAsFixed(3)} '
            '(model ${entry.baselineScore.toStringAsFixed(4)} '
            '+ exposure ${entry.exposure.toStringAsFixed(3)})',
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.grey.shade700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            entry.topFactorFor(lang),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.navyBlue,
            ),
          ),
        ],
      ),
    );
  }
}
