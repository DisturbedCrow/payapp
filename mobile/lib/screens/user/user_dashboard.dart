import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/wallet_provider.dart';
import '../../providers/transaction_provider.dart';
import '../../ml/edge_limit_engine.dart';
import '../../services/offline_limit_service.dart';
import '../../services/connectivity_service.dart';
import '../../widgets/edge_limit_source_label.dart';
import '../../widgets/edge_model_feed_sheet.dart';
import '../../widgets/limit_explanation_card.dart';
import '../../widgets/transaction_tile.dart';
import '../../config/theme.dart';
import '../home_screen.dart';
import '../receive_scan_screen.dart';
import 'pay_screen.dart';
import '../show_qr_screen.dart';
import 'risk_profile_screen.dart';

class UserDashboard extends StatefulWidget {
  const UserDashboard({super.key});

  @override
  State<UserDashboard> createState() => _UserDashboardState();
}

class _UserDashboardState extends State<UserDashboard> {
  // Lets us re-fetch the "Why this limit?" copy after a sync recalculates the
  // limit, so the card visibly updates on stage.
  final _explainerKey = GlobalKey<LimitExplanationCardState>();

  final EdgeLimitEngine _edge = EdgeLimitEngine();

  @override
  void initState() {
    super.initState();
    // Feature I2: whenever the on-device engine reprices (a payment, a sync,
    // this dashboard), repaint the badge from the rewritten limit.
    _edge.latest.addListener(_onEdgeReprice);
    // A sync writes the server limit after the engine ran: repaint then too.
    OfflineLimitService().limitChanged.addListener(_onEdgeReprice);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _repriceIfOffline('dashboard'));
  }

  @override
  void dispose() {
    _edge.latest.removeListener(_onEdgeReprice);
    OfflineLimitService().limitChanged.removeListener(_onEdgeReprice);
    super.dispose();
  }

  void _onEdgeReprice() {
    if (!mounted) return;
    context.read<WalletProvider>().loadCachedTokens();
  }

  /// Offline, re-score the limit on the phone: sync age keeps growing while
  /// the dashboard sits there. Online, the server number stands.
  Future<void> _repriceIfOffline(String reason) async {
    bool online;
    try {
      online = await ConnectivityService().checkNow();
    } catch (_) {
      return; // no connectivity plugin (tests): leave the limit alone
    }
    if (online || !mounted) return;
    await _edge.repriceOffline(reason: reason);
  }

  /// Badge tap: bring "Why this limit?" into view and open it.
  Future<void> _showLimitExplanationCard() async {
    final cardContext = _explainerKey.currentContext;
    if (cardContext == null) return;
    await Scrollable.ensureVisible(
      cardContext,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.2,
    );
    _explainerKey.currentState?.expand();
  }

  Future<void> _refresh() async {
    final auth = context.read<AuthProvider>();
    final wallet = context.read<WalletProvider>();
    final txProvider = context.read<TransactionProvider>();
    await auth.refreshUser();
    await txProvider.loadLocalTransactions(userId: auth.user?.id);
    if (wallet.isOnline) {
      await wallet.requestTokens();
      await txProvider.fetchServerTransactions(isUser: true, userId: auth.user?.id);
    } else {
      await _repriceIfOffline('refresh');
    }
    // Not awaited: the card resolves offline too, and awaiting it would hold
    // the pull-to-refresh spinner for the whole request timeout on bad Wi-Fi.
    _explainerKey.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final wallet = context.watch<WalletProvider>();
    final txProvider = context.watch<TransactionProvider>();
    final user = auth.user;
    final firstName = user?.fullName.split(' ').first ?? 'User';
    final initials = user?.fullName
            .split(' ')
            .where((w) => w.isNotEmpty)
            .take(2)
            .map((w) => w[0].toUpperCase())
            .join() ??
        'U';

    return Scaffold(
      backgroundColor: AppTheme.lightBlue,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            color: AppTheme.navyBlue,
            child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // ── App Bar ───────────────────────────────────────────
              SliverAppBar(
                pinned: true,
                backgroundColor: AppTheme.lightBlue,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                expandedHeight: 64,
                automaticallyImplyLeading: false,
                flexibleSpace: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        // Avatar + menu
                        GestureDetector(
                          onTap: () => _showProfileSheet(context, auth, user?.fullName ?? 'User', user?.email ?? '', initials),
                          child: Stack(
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: AppTheme.yellow,
                                child: Text(
                                  initials,
                                  style: const TextStyle(
                                    color: AppTheme.navyBlue,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: AppTheme.navyBlue,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: AppTheme.lightBlue, width: 1.5),
                                  ),
                                  child: const Icon(Icons.menu,
                                      size: 8, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        // SetuPay UPI logo
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            RichText(
                              text: const TextSpan(
                                children: [
                                  TextSpan(
                                    text: 'Setu',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      color: AppTheme.navyBlue,
                                    ),
                                  ),
                                  TextSpan(
                                    text: 'Pay',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      color: AppTheme.saffron,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Text(
                              '—सेतु · offline UPI—',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.navyBlue,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        // Icons
                        IconButton(
                          icon: const Icon(Icons.search,
                              color: AppTheme.navyBlue),
                          onPressed: () {},
                        ),
                        IconButton(
                          icon: const Icon(Icons.chat_bubble_outline,
                              color: AppTheme.navyBlue),
                          onPressed: () async {
                            await wallet.requestTokens();
                            await auth.refreshUser();
                            await txProvider.loadLocalTransactions(
                                userId: user?.id);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              SliverToBoxAdapter(
                child: Column(
                  children: [
                    // ── Promo Banner ─────────────────────────────────
                    _PromoBanner(
                      isOnline: wallet.isOnline,
                      offlineLimit: wallet.offlineLimitRemaining,
                      onTap: () => context
                          .findAncestorStateOfType<HomeScreenState>()
                          ?.setTab(1),
                    ),
                    const SizedBox(height: 10),

                    // ── Money Transfer ────────────────────────────────
                    _SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Money Transfer ',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.navyBlue,
                                ),
                              ),
                              const Icon(Icons.currency_rupee,
                                  size: 16, color: AppTheme.navyBlue),
                              const Icon(Icons.double_arrow,
                                  size: 14, color: AppTheme.paytmBlue),
                            ],
                          ),
                          const SizedBox(height: 16),
                          GridView.count(
                            crossAxisCount: 4,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            crossAxisSpacing: 4,
                            mainAxisSpacing: 16,
                            childAspectRatio: 0.78,
                            children: [
                              _GridItem(
                                icon: Icons.qr_code_scanner,
                                label: 'Scan & Pay',
                                color: AppTheme.paytmBlue,
                                onTap: () => context
                                    .findAncestorStateOfType<HomeScreenState>()
                                    ?.setTab(1),
                              ),
                              _GridItem(
                                icon: Icons.smartphone,
                                label: 'To Mobile',
                                color: const Color(0xFF5C6BC0),
                              ),
                              _GridItem(
                                icon: Icons.account_balance,
                                label: 'To Bank A/c',
                                color: const Color(0xFF26A69A),
                              ),
                              _GridItem(
                                icon: Icons.receipt_long,
                                label: 'Balance & History',
                                color: const Color(0xFF8D6E63),
                                badge: 'Passbook',
                                badgeColor: AppTheme.yellow,
                                onTap: () => context
                                    .findAncestorStateOfType<HomeScreenState>()
                                    ?.setTab(3),
                              ),
                              // ── OFFLINE PAYMENT (our feature) ──────
                              _GridItem(
                                icon: Icons.offline_bolt,
                                label: 'Pay Offline',
                                color: AppTheme.orange,
                                badge: 'New',
                                badgeColor: AppTheme.red,
                                onTap: () => context
                                    .findAncestorStateOfType<HomeScreenState>()
                                    ?.setTab(1),
                              ),
                              _GridItem(
                                icon: Icons.sync_alt,
                                label: 'To Self Account',
                                color: const Color(0xFF7E57C2),
                              ),
                              // Case 3b receiver: scan a signed blob straight
                              // off the sender's screen, fully offline.
                              _GridItem(
                                icon: Icons.download_rounded,
                                label: 'Receive Money',
                                color: AppTheme.green,
                                badge: 'Offline',
                                badgeColor: AppTheme.saffron,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ReceiveScanScreen(),
                                  ),
                                ),
                              ),
                              _GridItem(
                                icon: Icons.card_giftcard,
                                label: 'Send a Gift Voucher',
                                color: AppTheme.red,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ── My SetuPay ───────────────────────────────────
                    _SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'My SetuPay',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.navyBlue,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '${user?.email.split('@').first ?? 'user'}${AppConstants.upiSuffix}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),

                          // Balances row
                          Row(
                            children: [
                              _BalancePill(
                                label:
                                    'Rs ${(user?.balance ?? 0).toStringAsFixed(0)}',
                                color: AppTheme.green,
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const RiskProfileScreen()),
                                ),
                                child: _BalancePill(
                                  label:
                                      '₹${wallet.offlineLimitRemaining.toStringAsFixed(0)} offline ⓘ',
                                  color: wallet.isOnline
                                      ? AppTheme.navyBlue
                                      : AppTheme.orange,
                                  icon: wallet.isOnline
                                      ? null
                                      : Icons.wifi_off,
                                ),
                              ),
                            ],
                          ),

                          // ── "Why this limit?" — the AI made visible ──
                          // Hides itself entirely when offline with no cache,
                          // so it can never become a spinner that won't resolve.
                          const SizedBox(height: 12),
                          LimitExplanationCard(key: _explainerKey),

                          const SizedBox(height: 16),

                          // My SetuPay items grid
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceAround,
                            children: [
                              _GridItem(
                                icon: Icons.account_balance_wallet,
                                label: 'SetuPay Wallet',
                                color: AppTheme.navyBlue,
                                onTap: () => context
                                    .findAncestorStateOfType<HomeScreenState>()
                                    ?.setTab(2),
                              ),
                              // Feature I3: where the number came from, live.
                              // Tap -> "Why this limit?"; long-press -> the
                              // edge model feed (airplane-mode proof).
                              _GridItem(
                                icon: Icons.offline_bolt,
                                label: 'Offline Limit',
                                color: AppTheme.orange,
                                badge:
                                    '₹${wallet.offlineLimitRemaining.toStringAsFixed(0)}',
                                badgeColor: AppTheme.navyBlue,
                                subLabel: const SizedBox(
                                  width: 84,
                                  child: EdgeLimitSourceLabel(),
                                ),
                                onTap: _showLimitExplanationCard,
                                onLongPress: () => showEdgeModelFeed(context),
                              ),
                              _GridItem(
                                icon: Icons.people,
                                label: 'Refer & Earn',
                                color: const Color(0xFF26A69A),
                              ),
                              _GridItem(
                                icon: Icons.account_balance,
                                label: 'Personal Loan',
                                color: const Color(0xFF5C6BC0),
                                badge: '₹3Lakh Tak',
                                badgeColor: AppTheme.yellow,
                              ),
                            ],
                          ),

                          // Pending sync notice
                          if (txProvider.pendingCount > 0) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: AppTheme.orange.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: AppTheme.orange.withOpacity(0.3)),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.sync,
                                      size: 16, color: AppTheme.orange),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${txProvider.pendingCount} offline payment${txProvider.pendingCount > 1 ? 's' : ''} pending sync',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.orange,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (wallet.isOnline)
                                    GestureDetector(
                                      onTap: () =>
                                          txProvider.syncTransactions(),
                                      child: Text(
                                        'Sync now',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.navyBlue,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ── Recharge & Bill Payments ──────────────────────
                    _SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Recharge & Bill Payments',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.navyBlue,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'My Bills',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.paytmBlue,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceAround,
                            children: const [
                              _GridItem(
                                  icon: Icons.smartphone,
                                  label: 'Mobile\nRecharge',
                                  color: Color(0xFF5C6BC0)),
                              _GridItem(
                                  icon: Icons.bolt,
                                  label: 'Electricity',
                                  color: Color(0xFFFFA726)),
                              _GridItem(
                                  icon: Icons.wifi,
                                  label: 'Broadband',
                                  color: Color(0xFF26A69A)),
                              _GridItem(
                                  icon: Icons.local_gas_station,
                                  label: 'Gas',
                                  color: Color(0xFFEF5350)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // ── Recent Transactions ───────────────────────────
                    _SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Recent Transactions',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.navyBlue,
                                ),
                              ),
                              const Spacer(),
                              if (txProvider.allTransactions.isNotEmpty)
                                GestureDetector(
                                  onTap: () => context
                                      .findAncestorStateOfType<
                                          HomeScreenState>()
                                      ?.setTab(3),
                                  child: const Text(
                                    'See All',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.paytmBlue,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (txProvider.allTransactions.isEmpty)
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  children: [
                                    Icon(Icons.receipt_long_outlined,
                                        size: 40,
                                        color: Colors.grey.shade300),
                                    const SizedBox(height: 8),
                                    Text(
                                      'No transactions yet',
                                      style: TextStyle(
                                          color: Colors.grey.shade500,
                                          fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            ...txProvider.allTransactions
                                .take(5)
                                .map((tx) => TransactionTile(
                                      transaction: tx,
                                      isOutgoing:
                                          tx.senderId == user?.id,
                                    )),
                        ],
                      ),
                    ),

                    // Bottom padding for FAB
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ],
          ),
          ),  // RefreshIndicator

          // ── Pay by voice — the stage centrepiece ───────────────────
          // Sits above the QR row so it is the first thing a judge sees.
          if (AppConstants.voicePayEnabled)
            Positioned(
              bottom: 84,
              right: 24,
              child: FloatingActionButton.extended(
                heroTag: 'voicePayFab',
                backgroundColor: AppTheme.saffron,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.mic),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'बोलकर भेजें • Pay by Voice',
                    maxLines: 1,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
                onPressed: () {
                  // Hand off to the Pay tab, which owns the payment machinery,
                  // and have it open the mic straight away — one tap on stage.
                  PayScreen.autoStartVoice = true;
                  context
                      .findAncestorStateOfType<HomeScreenState>()
                      ?.setTab(1);
                },
              ),
            ),

          // ── Floating action buttons ────────────────────────────────
          Positioned(
            bottom: 16,
            left: 24,
            right: 24,
            child: Row(
              children: [
                // Scan Any QR
                Expanded(
                  child: GestureDetector(
                    onTap: () => context
                        .findAncestorStateOfType<HomeScreenState>()
                        ?.setTab(1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: AppTheme.navyBlue,
                        borderRadius: BorderRadius.circular(40),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.navyBlue.withOpacity(0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.qr_code_scanner,
                              color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Scan QR',
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
                ),
                const SizedBox(width: 12),
                // My QR
                Expanded(
                  child: Builder(builder: (ctx) {
                    final u = ctx.read<AuthProvider>().user;
                    return GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ShowQRScreen(
                            userId: u?.id ?? '',
                            userName: u?.fullName ?? 'User',
                            userEmail: u?.email,
                          ),
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(
                              color: AppTheme.navyBlue.withOpacity(0.3),
                              width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 12,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.qr_code,
                                color: AppTheme.navyBlue, size: 20),
                            SizedBox(width: 8),
                            Text(
                              'My QR',
                              style: TextStyle(
                                color: AppTheme.navyBlue,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _showLimitExplanation(
  BuildContext context,
  double remaining,
  double total,
  double riskScore,
  Map<String, dynamic> riskFactors,
) {
  // Human-readable factor labels and contribution direction
  const factorMeta = {
    'kyc_tier':              ('KYC Verification Tier',    true),
    'device_trust_score':    ('Device Trust Score',       true),
    'transaction_count':     ('Transaction History',      true),
    'days_since_registration': ('Account Age',            true),
    'fraud_flags':           ('Fraud Flags',              false),
  };

  // Map risk score to limit tier label
  String limitTier;
  if (riskScore < 0.2)       limitTier = '₹5,000 (Max)';
  else if (riskScore < 0.4)  limitTier = '₹3,000';
  else if (riskScore < 0.6)  limitTier = '₹1,500';
  else if (riskScore < 0.8)  limitTier = '₹500';
  else if (riskScore < 0.9)  limitTier = '₹100 (Min)';
  else                       limitTier = '₹0 (Restricted)';

  final riskPct = ((1.0 - riskScore) * 100).round();

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.navyBlue.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.offline_bolt,
                      color: AppTheme.navyBlue, size: 22),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Offline Credit Limit',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.navyBlue,
                      ),
                    ),
                    Text(
                      'AI-assigned based on your profile',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Limit summary
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.lightBlue,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Available',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade600)),
                        Text(
                          '₹${remaining.toStringAsFixed(0)}',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.navyBlue,
                          ),
                        ),
                        Text('of ₹${total.toStringAsFixed(0)} total',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Credit Score',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600)),
                      Text(
                        '$riskPct',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.paytmBlue,
                        ),
                      ),
                      Text('/ 100',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (1.0 - riskScore).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(
                  riskScore < 0.4
                      ? AppTheme.successColor
                      : riskScore < 0.7
                          ? AppTheme.orange
                          : Colors.red,
                ),
              ),
            ),
            const SizedBox(height: 20),

            const Text(
              'How your limit is calculated',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppTheme.navyBlue,
              ),
            ),
            const SizedBox(height: 12),

            // Factor rows
            if (riskFactors.isEmpty)
              Text(
                'Connect to internet to load your detailed breakdown.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
              )
            else
              ...riskFactors.entries.map((e) {
                final meta = factorMeta[e.key];
                if (meta == null) return const SizedBox.shrink();
                final label = meta.$1;
                final isPositive = meta.$2;
                final val = (e.value as num).toDouble().abs();
                // Normalise contribution bar (max ~0.3 per factor)
                final barFraction = (val / 0.35).clamp(0.0, 1.0);
                final color = isPositive ? AppTheme.successColor : Colors.red.shade400;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isPositive ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                            size: 14,
                            color: color,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(label,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w500)),
                          ),
                          Text(
                            isPositive ? '+${(barFraction * 100).round()} pts' : '-${(barFraction * 100).round()} pts',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: barFraction,
                          minHeight: 5,
                          backgroundColor: Colors.grey.shade100,
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                        ),
                      ),
                    ],
                  ),
                );
              }),

            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.lightBlue,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      size: 14, color: AppTheme.paytmBlue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Limit tier: $limitTier · Refreshes every 24 hours when online.',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.navyBlue),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void _showProfileSheet(BuildContext context, AuthProvider auth, String fullName, String email, String initials) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // Profile header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: AppTheme.yellow,
                    child: Text(
                      initials,
                      style: const TextStyle(
                        color: AppTheme.navyBlue,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fullName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.navyBlue,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          email,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            Divider(color: Colors.grey.shade100, height: 1),

            // Menu items
            _ProfileTile(icon: Icons.person_outline, label: 'Edit Profile', onTap: () => Navigator.pop(context)),
            _ProfileTile(icon: Icons.verified_user_outlined, label: 'KYC Status', onTap: () => Navigator.pop(context)),
            _ProfileTile(icon: Icons.lock_outline, label: 'Privacy & Security', onTap: () => Navigator.pop(context)),
            _ProfileTile(icon: Icons.help_outline, label: 'Help & Support', onTap: () => Navigator.pop(context)),
            _ProfileTile(icon: Icons.info_outline, label: 'About', onTap: () => Navigator.pop(context)),

            Divider(color: Colors.grey.shade100, height: 1),

            // Logout
            _ProfileTile(
              icon: Icons.logout,
              label: 'Logout',
              color: Colors.red.shade600,
              onTap: () async {
                Navigator.pop(context);
                await auth.logout();
              },
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ProfileTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.navyBlue;
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          color: c,
          fontWeight: color != null ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      trailing: color == null
          ? Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 20)
          : null,
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
    );
  }
}

// ── Reusable widgets ────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final Widget child;
  const _SectionCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

class _PromoBanner extends StatelessWidget {
  final bool isOnline;
  final double offlineLimit;
  final VoidCallback onTap;

  const _PromoBanner({
    required this.isOnline,
    required this.offlineLimit,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.lightBlue,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.offline_bolt,
                            size: 12, color: AppTheme.paytmBlue),
                        const SizedBox(width: 4),
                        const Text(
                          'Offline Payments',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.navyBlue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Pay without internet.\nAlways.',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.navyBlue,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.navyBlue,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Pay Offline →',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'T&C Apply',
                    style: TextStyle(fontSize: 9, color: Colors.grey),
                  ),
                ],
              ),
            ),
            // Right side — big limit display
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: AppTheme.lightBlue,
                shape: BoxShape.circle,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '₹${offlineLimit.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.navyBlue,
                    ),
                  ),
                  Text(
                    isOnline ? 'available' : 'offline',
                    style: TextStyle(
                      fontSize: 10,
                      color: isOnline ? AppTheme.paytmBlue : AppTheme.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Icon(
                    isOnline ? Icons.wifi : Icons.wifi_off,
                    size: 14,
                    color: isOnline ? AppTheme.paytmBlue : AppTheme.orange,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final String? badge;
  final Color? badgeColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Optional line under [label] (the offline limit's source label).
  final Widget? subLabel;

  const _GridItem({
    required this.icon,
    required this.label,
    required this.color,
    this.badge,
    this.badgeColor,
    this.onTap,
    this.onLongPress,
    this.subLabel,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              if (badge != null)
                Positioned(
                  top: -6,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: badgeColor ?? AppTheme.yellow,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badge!,
                        style: const TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF333333),
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          ),
          if (subLabel != null) ...[
            const SizedBox(height: 2),
            subLabel!,
          ],
        ],
      ),
    );
  }
}

class _BalancePill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const _BalancePill({required this.label, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
