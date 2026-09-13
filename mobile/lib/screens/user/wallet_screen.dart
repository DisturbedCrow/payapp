import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../ml/edge_limit_engine.dart';
import '../../providers/wallet_provider.dart';
import '../../services/offline_limit_service.dart';
import '../../models/payment_token.dart';
import '../../config/theme.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletProvider>();
    final limit = wallet.limitSummary;
    final formatter = NumberFormat.currency(symbol: '₹', decimalDigits: 2);
    final dateFormatter = DateFormat('dd MMM, hh:mm a');

    return Scaffold(
      backgroundColor: AppTheme.surfaceColor,
      appBar: AppBar(
        title: const Text('Offline Wallet'),
        automaticallyImplyLeading: false,
        actions: [
          if (wallet.isOnline)
            TextButton.icon(
              onPressed: wallet.isLoading
                  ? null
                  : () => wallet.requestTokens(),
              icon: const Icon(Icons.add, color: Colors.white, size: 18),
              label: const Text('Get Tokens',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (wallet.isOnline) {
            await wallet.requestTokens();
          } else {
            await wallet.loadCachedTokens();
          }
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Summary card — the amount this phone can still pay offline.
            // Offline payments are authorised against the AI limit, not by
            // adding up tokens.
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.accentColor, Color(0xFF651FFF)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Available offline',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatter.format(limit.available),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (limit.approved > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'of ${formatter.format(limit.approved)} approved by AI',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _InfoChip(
                        label: '${wallet.activeTokens.length} tokens',
                        icon: Icons.token,
                      ),
                      const SizedBox(width: 8),
                      _InfoChip(
                        label: wallet.isOnline ? 'Online' : 'Offline',
                        icon: wallet.isOnline ? Icons.wifi : Icons.wifi_off,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Offline limit info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ValueListenableBuilder<EdgeReprice?>(
                valueListenable: EdgeLimitEngine().latest,
                builder: (context, edge, _) {
                  // The on-device model's score is current only if it ran
                  // after the server last issued the limit.
                  final synced = OfflineLimitService().lastSyncAt.value;
                  final fromEdge =
                      edge != null && (synced == null || !edge.at.isBefore(synced));
                  final risk = fromEdge ? edge.score : wallet.riskScore;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Offline Limit Details',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _LimitRow(
                        label: 'Approved Limit',
                        value: formatter.format(limit.approved),
                        color: AppTheme.primaryColor,
                      ),
                      _LimitRow(
                        label: 'Spent offline (not synced)',
                        value: formatter.format(limit.spent),
                        color: AppTheme.warningColor,
                      ),
                      if (limit.heldBackByAi >= 1)
                        _LimitRow(
                          label: 'Held back by AI',
                          value: formatter.format(limit.heldBackByAi),
                          color: AppTheme.errorColor,
                        ),
                      _LimitRow(
                        label: 'Remaining',
                        value: formatter.format(limit.available),
                        color: AppTheme.successColor,
                      ),
                      const SizedBox(height: 8),
                      if (limit.approved > 0)
                        Text(
                          'AI Risk Score: ${(risk * 100).round()}/100 · '
                          '${fromEdge ? 'on-device model' : 'server model'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 20),

            // Active Tokens
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Active Tokens',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${wallet.activeTokens.length} available',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (wallet.activeTokens.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      Icon(Icons.token_outlined,
                          size: 48, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text(
                        'No active tokens',
                        style: TextStyle(color: Colors.grey.shade500),
                      ),
                      if (wallet.isOnline) ...[
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: () => wallet.requestTokens(),
                          child: const Text('Request Tokens'),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            else
              ...wallet.activeTokens.map((token) {
                return _TokenCard(token: token, formatter: formatter);
              }),

            // Loading indicator
            if (wallet.isLoading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),

            // Error display
            if (wallet.error != null)
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  wallet.error!,
                  style: const TextStyle(
                      color: AppTheme.errorColor, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _InfoChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _LimitRow extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _LimitRow({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontSize: 14)),
            ],
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _TokenCard extends StatelessWidget {
  final PaymentToken token;
  final NumberFormat formatter;

  const _TokenCard({required this.token, required this.formatter});

  @override
  Widget build(BuildContext context) {
    DateTime? expiry;
    try {
      expiry = DateTime.parse(token.expiresAt);
    } catch (_) {}

    final remaining = expiry?.difference(DateTime.now());

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.accentColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.token,
              color: AppTheme.accentColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatter.format(token.amount),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (remaining != null)
                  Text(
                    'Expires in ${remaining.inHours}h ${remaining.inMinutes % 60}m',
                    style: TextStyle(
                      fontSize: 11,
                      color: remaining.inHours < 1
                          ? AppTheme.errorColor
                          : Colors.grey.shade500,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.successColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'Active',
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.successColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
