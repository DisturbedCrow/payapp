import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/theme.dart';

enum ReceiptStatus { settled, pendingSync, sentViaBluetooth, failed }

class PaymentReceiptScreen extends StatelessWidget {
  final double amount;
  final String recipientName;
  final String paymentId;
  final ReceiptStatus status;
  final bool isOnline;
  final DateTime timestamp;
  final String? senderName;

  const PaymentReceiptScreen({
    super.key,
    required this.amount,
    required this.recipientName,
    required this.paymentId,
    required this.status,
    required this.isOnline,
    required this.timestamp,
    this.senderName,
  });

  @override
  Widget build(BuildContext context) {
    final cfg = _config(status);

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // ── Hero block (light blue) ─────────────────────────────
          _HeroSection(
            amount: amount,
            recipientName: recipientName,
            status: status,
            cfg: cfg,
            onClose: () => Navigator.of(context).pop(),
          ),

          // ── Details card ───────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  // Scalloped connector
                  _ScallopDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        _DetailRow(
                          label: 'To',
                          value: recipientName,
                          bold: true,
                        ),
                        if (senderName != null) ...[
                          const Divider(height: 1, color: Color(0xFFF0F0F0)),
                          _DetailRow(label: 'From', value: senderName!),
                        ],
                        const Divider(height: 1, color: Color(0xFFF0F0F0)),
                        _DetailRow(
                          label: 'Amount',
                          value: '₹${amount.toStringAsFixed(2)}',
                          bold: true,
                          valueColor: AppTheme.primaryColor,
                        ),
                        const Divider(height: 1, color: Color(0xFFF0F0F0)),
                        _DetailRow(
                          label: 'Mode',
                          valueWidget: _ModeChip(status: status, isOnline: isOnline),
                        ),
                        const Divider(height: 1, color: Color(0xFFF0F0F0)),
                        _DetailRow(
                          label: 'Payment ID',
                          valueWidget: GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: paymentId));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Copied'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _shortId(paymentId),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.primaryColor,
                                    fontWeight: FontWeight.w600,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.copy,
                                    size: 13, color: AppTheme.secondaryColor),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFFF0F0F0)),
                        _DetailRow(
                          label: 'Date & Time',
                          value: _fmtDate(timestamp),
                        ),
                      ],
                    ),
                  ),

                  // What happens next (only for offline)
                  if (cfg.nextSteps.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.lightBlue,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(cfg.nextIcon, size: 16, color: cfg.color),
                              const SizedBox(width: 6),
                              Text(
                                'What happens next',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: cfg.color,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ...cfg.nextSteps.asMap().entries.map((e) => Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 18,
                                      height: 18,
                                      margin: const EdgeInsets.only(right: 8, top: 1),
                                      decoration: BoxDecoration(
                                        color: cfg.color.withOpacity(0.15),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Text(
                                          '${e.key + 1}',
                                          style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              color: cfg.color),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(e.value,
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade700,
                                              height: 1.4)),
                                    ),
                                  ],
                                ),
                              )),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // Done button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Done'),
                      ),
                    ),
                  ),

                  // Footer
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Powered by ',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade400)),
                      const Text('UPI',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF6A5ACD))),
                      Text(' | ',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade300)),
                      const Text('Setu',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: AppTheme.primaryColor)),
                      const Text('Pay',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.saffron)),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _shortId(String id) {
    if (id.length <= 16) return id;
    final parts = id.replaceAll('-', '');
    return '${parts.substring(0, 7)} ${parts.substring(7, 12)}';
  }

  String _fmtDate(DateTime dt) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month]} ${dt.year}, $h:$min $ampm';
  }

  _Cfg _config(ReceiptStatus s) {
    switch (s) {
      case ReceiptStatus.settled:
        return _Cfg(
          icon: Icons.check_circle,
          nextIcon: Icons.check_circle_outline,
          color: const Color(0xFF22A45D),
          label: 'Payment Successful',
          nextSteps: [],
        );
      case ReceiptStatus.pendingSync:
        return _Cfg(
          icon: Icons.schedule_rounded,
          nextIcon: Icons.sync,
          color: AppTheme.warningColor,
          label: 'Pending Sync',
          nextSteps: [
            'Payment recorded securely on this device.',
            'Will automatically sync when you reconnect.',
            'Recipient is credited within seconds of sync.',
          ],
        );
      case ReceiptStatus.sentViaBluetooth:
        return _Cfg(
          icon: Icons.bluetooth,
          nextIcon: Icons.bluetooth_searching,
          color: AppTheme.primaryColor,
          label: 'Sent via Bluetooth',
          nextSteps: [
            'Payment blob sent directly to recipient\'s device.',
            'Recipient\'s app settles this when they go online.',
            'Also stored in your sync queue as a backup.',
          ],
        );
      case ReceiptStatus.failed:
        return _Cfg(
          icon: Icons.error_outline,
          nextIcon: Icons.help_outline,
          color: AppTheme.errorColor,
          label: 'Payment Failed',
          nextSteps: ['Please try again or contact support.'],
        );
    }
  }
}

// ── Hero section ───────────────────────────────────────────────────────────────

class _HeroSection extends StatelessWidget {
  final double amount;
  final String recipientName;
  final ReceiptStatus status;
  final _Cfg cfg;
  final VoidCallback onClose;

  const _HeroSection({
    required this.amount,
    required this.recipientName,
    required this.status,
    required this.cfg,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppTheme.lightBlue,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Back button row
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, color: AppTheme.primaryColor),
                onPressed: onClose,
              ),
            ),

            // SetuPay logo
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Setu',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.primaryColor)),
                Text('Pay',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.saffron)),
              ],
            ),
            const SizedBox(height: 20),

            // Status label
            Text(
              cfg.label,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: cfg.color,
              ),
            ),
            const SizedBox(height: 12),

            // Amount + badge
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '₹${amount.toStringAsFixed(0)}',
                  style: const TextStyle(
                    fontSize: 52,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.primaryColor,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: cfg.color,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    status == ReceiptStatus.settled
                        ? Icons.check
                        : cfg.icon,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ],
            ),

            // Amount in words (for settled only)
            if (status == ReceiptStatus.settled) ...[
              const SizedBox(height: 6),
              Text(
                _amountWords(amount),
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Blue gradient bar
            Container(
              height: 5,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppTheme.primaryColor, AppTheme.secondaryColor],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _amountWords(double amount) {
    final n = amount.toInt();
    if (n == 0) return 'Zero Rupees Only';
    final words = <String>[];
    if (n >= 1000) words.add('${_w(n ~/ 1000)} Thousand');
    if ((n % 1000) >= 100) words.add('${_w((n % 1000) ~/ 100)} Hundred');
    final rem = n % 100;
    if (rem > 0) words.add(_w(rem));
    return '${words.join(' ')} ${n == 1 ? 'Rupee' : 'Rupees'} Only';
  }

  String _w(int n) {
    const ones = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
        'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
        'Seventeen', 'Eighteen', 'Nineteen'];
    const tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
    if (n < 20) return ones[n];
    if (n % 10 == 0) return tens[n ~/ 10];
    return '${tens[n ~/ 10]} ${ones[n % 10]}';
  }
}

// ── Scalloped divider ──────────────────────────────────────────────────────────

class _ScallopDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 24),
      painter: _ScallopPainter(),
    );
  }
}

class _ScallopPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = AppTheme.lightBlue;
    final fg = Paint()..color = Colors.white;

    // Fill the top half with lightBlue
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height / 2), bg);
    // Fill bottom half with white
    canvas.drawRect(Rect.fromLTWH(0, size.height / 2, size.width, size.height / 2), fg);

    // Draw scallops (semicircles cut from lightBlue into white)
    const r = 10.0;
    final path = Path()..moveTo(0, size.height / 2);
    double x = 0;
    while (x < size.width) {
      path.arcToPoint(
        Offset(x + r * 2, size.height / 2),
        radius: const Radius.circular(r),
        clockwise: false,
      );
      x += r * 2;
    }
    path.lineTo(size.width, 0);
    path.lineTo(0, 0);
    path.close();
    canvas.drawPath(path, bg);
  }

  @override
  bool shouldRepaint(_) => false;
}

// ── Shared widgets ─────────────────────────────────────────────────────────────

class _Cfg {
  final IconData icon;
  final IconData nextIcon;
  final Color color;
  final String label;
  final List<String> nextSteps;
  const _Cfg({
    required this.icon,
    required this.nextIcon,
    required this.color,
    required this.label,
    required this.nextSteps,
  });
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String? value;
  final Widget? valueWidget;
  final bool bold;
  final Color? valueColor;

  const _DetailRow({
    required this.label,
    this.value,
    this.valueWidget,
    this.bold = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
          valueWidget ??
              Text(
                value ?? '',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  color: valueColor ?? Colors.black87,
                ),
              ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final ReceiptStatus status;
  final bool isOnline;

  const _ModeChip({required this.status, required this.isOnline});

  @override
  Widget build(BuildContext context) {
    final icon = status == ReceiptStatus.sentViaBluetooth
        ? Icons.bluetooth
        : isOnline
            ? Icons.wifi
            : Icons.wifi_off;
    final label = status == ReceiptStatus.sentViaBluetooth
        ? 'Bluetooth'
        : isOnline
            ? 'Online'
            : 'Offline';
    final color = status == ReceiptStatus.sentViaBluetooth
        ? AppTheme.primaryColor
        : isOnline
            ? AppTheme.successColor
            : AppTheme.offlineColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}
