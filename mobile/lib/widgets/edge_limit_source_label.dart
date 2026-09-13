import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../ml/edge_limit_engine.dart';
import '../services/offline_limit_service.dart';

/// `2s ago`, `4m ago`, `3h ago`, `2d ago`.
String formatAgo(Duration elapsed) {
  final d = elapsed.isNegative ? Duration.zero : elapsed;
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Where the offline limit on screen last came from:
/// `computed on-device · 2s ago` when the edge engine ran after the server
/// last issued it, `from server · 5s ago` otherwise, '' when neither is known.
String describeLimitSource({
  DateTime? edgeAt,
  DateTime? serverAt,
  required DateTime now,
}) {
  if (edgeAt != null && (serverAt == null || !edgeAt.isBefore(serverAt))) {
    return 'computed on-device · ${formatAgo(now.difference(edgeAt))}';
  }
  if (serverAt != null) {
    return 'from server · ${formatAgo(now.difference(serverAt))}';
  }
  return '';
}

/// Feature I3 — the sub-label under the dashboard's offline-limit badge.
///
/// Listens to the edge engine and the server sync time, and ticks once a
/// second while there is a timestamp to show (repainting only when the text
/// actually changes).
class EdgeLimitSourceLabel extends StatefulWidget {
  /// Defaults to `EdgeLimitEngine().latest`.
  final ValueListenable<EdgeReprice?>? edge;

  /// Defaults to `OfflineLimitService().lastSyncAt`.
  final ValueListenable<DateTime?>? server;

  /// Test seam for the clock.
  final DateTime Function()? clock;

  final TextAlign textAlign;

  const EdgeLimitSourceLabel({
    super.key,
    this.edge,
    this.server,
    this.clock,
    this.textAlign = TextAlign.center,
  });

  @override
  State<EdgeLimitSourceLabel> createState() => _EdgeLimitSourceLabelState();
}

class _EdgeLimitSourceLabelState extends State<EdgeLimitSourceLabel> {
  late final ValueListenable<EdgeReprice?> _edge =
      widget.edge ?? EdgeLimitEngine().latest;
  late final ValueListenable<DateTime?> _server =
      widget.server ?? OfflineLimitService().lastSyncAt;

  Timer? _ticker;
  String _text = '';

  @override
  void initState() {
    super.initState();
    _edge.addListener(_update);
    _server.addListener(_update);
    _update();
    // Populate the shared notifiers from prefs after a cold start.
    if (widget.edge == null) unawaited(EdgeLimitEngine().ensureLoaded());
    if (widget.server == null) unawaited(OfflineLimitService().getLastSyncAt());
  }

  void _update() {
    if (!mounted) return;
    final next = describeLimitSource(
      edgeAt: _edge.value?.at,
      serverAt: _server.value,
      now: (widget.clock ?? DateTime.now)(),
    );
    if (next.isNotEmpty) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _update());
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
    if (next != _text) setState(() => _text = next);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _edge.removeListener(_update);
    _server.removeListener(_update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_text.isEmpty) return const SizedBox.shrink();
    final onDevice = _text.startsWith('computed on-device');
    return Text(
      _text,
      textAlign: widget.textAlign,
      maxLines: 2,
      style: TextStyle(
        fontSize: 8.5,
        height: 1.2,
        fontWeight: onDevice ? FontWeight.w700 : FontWeight.w500,
        color: onDevice ? AppTheme.orange : Colors.grey.shade600,
      ),
    );
  }
}
