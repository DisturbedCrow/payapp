import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/auth_provider.dart';
import '../../providers/wallet_provider.dart';
import '../../providers/transaction_provider.dart';
import '../../widgets/transaction_tile.dart';
import '../../config/theme.dart';
import '../show_qr_screen.dart';

class MerchantDashboard extends StatefulWidget {
  const MerchantDashboard({super.key});

  @override
  State<MerchantDashboard> createState() => _MerchantDashboardState();
}

class _MerchantDashboardState extends State<MerchantDashboard> {
  bool _isRefreshing = false;

  Future<void> _refresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      final auth = context.read<AuthProvider>();
      final wallet = context.read<WalletProvider>();
      final txProvider = context.read<TransactionProvider>();
      await auth.refreshUser();
      await txProvider.loadLocalTransactions(userId: auth.user?.id);
      if (wallet.isOnline) {
        await txProvider.fetchServerTransactions(isUser: false, userId: auth.user?.id);
        await wallet.requestTokens();
      } else {
        await wallet.loadCachedTokens();
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final wallet = context.watch<WalletProvider>();
    final txProvider = context.watch<TransactionProvider>();
    final user = auth.user;
    final fmt = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

    final today = DateTime.now();
    final todayTx = txProvider.allTransactions.where((tx) {
      try {
        final d = DateTime.parse(tx.createdAt);
        return d.year == today.year &&
            d.month == today.month &&
            d.day == today.day;
      } catch (_) {
        return false;
      }
    }).toList();
    final todayEarnings = todayTx.fold(0.0, (s, tx) => s + tx.amount);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: AppTheme.navyBlue,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ── Header ──────────────────────────────────────────────
            SliverAppBar(
              expandedHeight: 210,
              pinned: true,
              backgroundColor: AppTheme.navyBlue,
              surfaceTintColor: Colors.transparent,
              actions: [
                if (_isRefreshing)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white70),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Colors.white70),
                    onPressed: _refresh,
                  ),
                IconButton(
                  icon: const Icon(Icons.logout, color: Colors.white70),
                  onPressed: () async {
                    txProvider.stopSync();
                    await auth.logout();
                    if (context.mounted) {
                      Navigator.of(context).pushReplacementNamed('/login');
                    }
                  },
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF283593), Color(0xFF3949AB)],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Branding row
                          Row(
                            children: [
                              const Text(
                                'Setu',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                ),
                              ),
                              const Text(
                                'Pay',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: AppTheme.saffron,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.paytmBlue.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color:
                                          AppTheme.paytmBlue.withOpacity(0.4)),
                                ),
                                child: const Text(
                                  'for Business',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.paytmBlue,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              // Online/Offline pill
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: wallet.isOnline
                                      ? Colors.green.withOpacity(0.2)
                                      : Colors.orange.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: wallet.isOnline
                                        ? Colors.green.withOpacity(0.5)
                                        : Colors.orange.withOpacity(0.5),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      wallet.isOnline
                                          ? Icons.wifi
                                          : Icons.wifi_off,
                                      size: 11,
                                      color: wallet.isOnline
                                          ? Colors.greenAccent
                                          : Colors.orangeAccent,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      wallet.isOnline ? 'Online' : 'Offline',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: wallet.isOnline
                                            ? Colors.greenAccent
                                            : Colors.orangeAccent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            user?.fullName ?? 'Merchant',
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.white70,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                          const Spacer(),
                          // Today's earnings row
                          const Text(
                            "Today's Earnings",
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                fmt.format(todayEarnings),
                                style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const Spacer(),
                              // QR button
                              GestureDetector(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ShowQRScreen(
                                      userId: user?.id ?? '',
                                      userName: user?.fullName ?? 'Merchant',
                                      userEmail: user?.email,
                                    ),
                                  ),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: AppTheme.paytmBlue,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.qr_code,
                                          color: Colors.white, size: 18),
                                      SizedBox(width: 6),
                                      Text(
                                        'My QR',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${todayTx.length} transaction${todayTx.length == 1 ? '' : 's'} today',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Body ──────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Offline banner
                    if (!wallet.isOnline)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3E0),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: Colors.orange.withOpacity(0.4)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.wifi_off,
                                size: 16, color: Colors.orange),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Offline mode — QR payments still work via your offline limit',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.orange,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Stat cards
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            label: 'Total Balance',
                            value: fmt.format((user?.balance ?? 0) + txProvider.pendingAmount),
                            icon: Icons.account_balance_wallet_outlined,
                            iconBg: const Color(0xFFE8F4FD),
                            iconColor: AppTheme.navyBlue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _StatCard(
                            label: 'Pending Sync',
                            value: '${txProvider.pendingCount} payments',
                            icon: Icons.cloud_upload_outlined,
                            iconBg: const Color(0xFFFFF8E1),
                            iconColor: Colors.amber.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            label: 'Total Received',
                            value: '${txProvider.allTransactions.length} txns',
                            icon: Icons.payments_outlined,
                            iconBg: const Color(0xFFE8F5E9),
                            iconColor: Colors.green.shade700,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _StatCard(
                            label: 'Pending Amount',
                            value: fmt.format(txProvider.pendingAmount),
                            icon: Icons.pending_actions_outlined,
                            iconBg: const Color(0xFFFCE4EC),
                            iconColor: Colors.pink.shade700,
                          ),
                        ),
                      ],
                    ),

                    // Sync button
                    if (wallet.isOnline && txProvider.pendingCount > 0) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: txProvider.isSyncing
                              ? null
                              : () async {
                                  await txProvider.syncTransactions();
                                  if (context.mounted) {
                                    await context.read<WalletProvider>().requestTokens();
                                    await context.read<AuthProvider>().refreshUser();
                                  }
                                },
                          icon: txProvider.isSyncing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.sync, size: 18),
                          label: Text(txProvider.isSyncing
                              ? 'Syncing…'
                              : 'Sync ${txProvider.pendingCount} pending payments'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.navyBlue,
                            side: const BorderSide(color: AppTheme.navyBlue),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // Recent payments header
                    Row(
                      children: [
                        const Text(
                          'Recent Payments',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        const Spacer(),
                        if (txProvider.allTransactions.isNotEmpty)
                          Text(
                            '${txProvider.allTransactions.length} total',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),

            // ── Transactions ─────────────────────────────────────
            txProvider.allTransactions.isEmpty
                ? SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(48),
                      child: Column(
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: AppTheme.lightBlue,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.store_outlined,
                                size: 36, color: AppTheme.navyBlue),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No payments yet',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Share your QR code to start accepting payments',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey.shade500),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ShowQRScreen(
                                  userId: auth.user?.id ?? '',
                                  userName: auth.user?.fullName ?? 'Merchant',
                                  userEmail: auth.user?.email,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.qr_code),
                            label: const Text('Show My QR'),
                          ),
                        ],
                      ),
                    ),
                  )
                : SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (ctx, i) {
                          final tx = txProvider.allTransactions[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TransactionTile(
                              transaction: tx,
                              isOutgoing: false,
                            ),
                          );
                        },
                        childCount: txProvider.allTransactions.length
                            .clamp(0, 20),
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconBg;
  final Color iconColor;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1A2E),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
