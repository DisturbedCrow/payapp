import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/qr_transfer.dart';
import '../services/ble_service.dart';
import '../models/payment_blob.dart';
import '../providers/transaction_provider.dart';
import '../providers/auth_provider.dart';
import '../config/constants.dart';
import '../config/theme.dart';

/// Universal receive-QR screen.
/// Works for any user type (UPI user, retailer, merchant).
/// Starts BLE advertising so nearby offline senders can push a blob directly.
class ShowQRScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final String? userEmail;

  const ShowQRScreen({
    super.key,
    required this.userId,
    required this.userName,
    this.userEmail,
  });

  @override
  State<ShowQRScreen> createState() => _ShowQRScreenState();
}

class _ShowQRScreenState extends State<ShowQRScreen> {
  final _ble = BLEService();
  String? _bleUuid;
  bool _bleStarting = false;
  bool _bleError = false;
  String _bleErrorMsg = '';
  PaymentBlob? _lastBlob;
  StreamSubscription? _blobSub;

  @override
  void initState() {
    super.initState();
    _startBLE();
    _blobSub = _ble.onBlobReceived.listen(_onBlob);
  }

  @override
  void dispose() {
    _blobSub?.cancel();
    _ble.stopReceiving();
    super.dispose();
  }

  Future<void> _startBLE() async {
    setState(() {
      _bleStarting = true;
      _bleError = false;
    });
    try {
      final uuid = await _ble.startReceiving();
      if (mounted) setState(() {
        _bleUuid = uuid;
        _bleStarting = false;
      });
    } catch (e) {
      debugPrint('[BLE] startReceiving error: $e');
      if (mounted) setState(() {
        _bleStarting = false;
        _bleError = true;
        _bleErrorMsg = e.toString();
      });
    }
  }

  void _onBlob(dynamic blob) {
    if (blob is PaymentBlob && mounted) {
      setState(() => _lastBlob = blob);
      // Refresh transaction list so receiver sees the incoming payment immediately
      final auth = context.read<AuthProvider>();
      context.read<TransactionProvider>().loadLocalTransactions(userId: auth.user?.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Payment received: ₹${blob.amount.toStringAsFixed(2)}'),
          backgroundColor: AppTheme.successColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final qrData = QrTransferService.generateReceiveQR(
      receiverId: widget.userId,
      receiverName: widget.userName,
      bleUuid: _bleUuid,
    );
    final upiHandle = widget.userEmail != null
        ? '${widget.userEmail!.split('@').first}${AppConstants.upiSuffix}'
        : null;

    return Scaffold(
      backgroundColor: AppTheme.surfaceColor,
      appBar: AppBar(
        title: const Text('My QR Code'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // BLE status row
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: _BleStatusRow(
                  starting: _bleStarting, error: _bleError, active: _bleUuid != null, errorMsg: _bleErrorMsg),
            ),
            const SizedBox(height: 12),

            // QR card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  // SetuPay UPI header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Text('Setu',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.primaryColor,
                          )),
                      Text('Pay',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.saffron,
                          )),
                      SizedBox(width: 6),
                      Text('UPI',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.secondaryColor,
                          )),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // QR
                  QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.circle,
                      color: AppTheme.primaryColor,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.circle,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                  const SizedBox(height: 16),

                  Text(
                    widget.userName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (upiHandle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      upiHandle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.lightBlue,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Works online & offline',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Last BLE received
            if (_lastBlob != null)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppTheme.successColor.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bluetooth,
                        color: AppTheme.successColor, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'BLE payment received: ₹${_lastBlob!.amount.toStringAsFixed(2)} — will settle when online',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.successColor,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 12),

            // How it works
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _InfoRow(
                    icon: Icons.wifi,
                    color: AppTheme.successColor,
                    text: 'Online — settles instantly',
                  ),
                  const SizedBox(height: 10),
                  _InfoRow(
                    icon: Icons.wifi_off,
                    color: AppTheme.offlineColor,
                    text: 'Sender offline — deducted from their limit, settles on reconnect',
                  ),
                  const SizedBox(height: 10),
                  _InfoRow(
                    icon: Icons.bluetooth,
                    color: AppTheme.primaryColor,
                    text: 'Both offline — Bluetooth transfer, settles when either comes online',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _BleStatusRow extends StatelessWidget {
  final bool starting;
  final bool error;
  final bool active;
  final String errorMsg;

  const _BleStatusRow(
      {required this.starting, required this.error, required this.active, this.errorMsg = ''});

  @override
  Widget build(BuildContext context) {
    if (starting) {
      return const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Starting Bluetooth…',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }
    if (error) {
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.bluetooth_disabled, size: 14, color: Colors.red),
              const SizedBox(width: 6),
              Text('BLE error — QR works without it',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
            ],
          ),
          if (errorMsg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(errorMsg,
                  style: const TextStyle(fontSize: 10, color: Colors.red),
                  textAlign: TextAlign.center),
            ),
        ],
      );
    }
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.bluetooth_connected,
            size: 14, color: AppTheme.successColor),
        SizedBox(width: 6),
        Text('Bluetooth active — ready for all offline payments',
            style: TextStyle(fontSize: 12, color: AppTheme.successColor)),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _InfoRow(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
        ),
      ],
    );
  }
}
