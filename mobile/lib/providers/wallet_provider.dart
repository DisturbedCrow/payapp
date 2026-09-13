import 'dart:async';
import 'package:flutter/material.dart';
import '../models/payment_token.dart';
import '../services/token_service.dart';
import '../services/sync_service.dart';
import '../services/offline_limit_service.dart';
import '../services/connectivity_service.dart';

class WalletProvider extends ChangeNotifier {
  final TokenService _tokenService = TokenService();
  final SyncService _syncService = SyncService();
  final OfflineLimitService _limitService = OfflineLimitService();
  final ConnectivityService _connectivityService = ConnectivityService();

  List<PaymentToken> _tokens = [];
  double _offlineLimit = 0;
  double _offlineLimitRemaining = 0;
  double _riskScore = 0.5;
  Map<String, dynamic> _riskFactors = {};
  bool _isLoading = false;
  bool _isOnline = true;
  String? _error;
  StreamSubscription<bool>? _connectivitySub;

  List<PaymentToken> get tokens => _tokens;
  List<PaymentToken> get activeTokens =>
      _tokens.where((t) => t.isValid).toList();
  double get offlineLimit => _offlineLimit;
  double get offlineLimitRemaining => _offlineLimitRemaining;
  double get riskScore => _riskScore;
  Map<String, dynamic> get riskFactors => _riskFactors;
  bool get isLoading => _isLoading;
  bool get isOnline => _isOnline;
  String? get error => _error;
  double get availableBalance =>
      activeTokens.fold(0.0, (sum, t) => sum + t.amount);

  /// Request new offline tokens from backend
  Future<bool> requestTokens({double? amount}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _tokenService.requestTokens(amount: amount);
      _tokens = result['tokens'] as List<PaymentToken>;
      _offlineLimit = result['offline_limit'] as double;
      _offlineLimitRemaining = result['offline_limit_remaining'] as double;
      _riskScore = result['risk_score'] as double;
      _riskFactors = result['risk_factors'] as Map<String, dynamic>;

      // Persist limit to SharedPrefs so it's available offline for 24h
      await _limitService.updateLimitFromSync(_offlineLimit);
      // Feature I: token issuance carries no risk-model inputs; cache them
      // now so the on-device engine can reprice from the very first offline
      // payment.
      await _limitService.refreshRiskFeatures();

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Load cached tokens (works offline)
  Future<void> loadCachedTokens() async {
    try {
      _tokens = await _tokenService.getActiveTokens();
      _isOnline = await _syncService.isOnline();

      // Load persisted limit from SharedPrefs (works offline, expires after 24h)
      _offlineLimitRemaining = await _limitService.getAvailableLimit();
      _offlineLimit = await _limitService.getTotalLimit();

      notifyListeners();
    } catch (e) {
      print('Error loading cached tokens: $e');
    }
  }

  /// Find a suitable token for a payment
  Future<PaymentToken?> findTokenForPayment(double amount) async {
    return await _tokenService.findTokenForAmount(amount);
  }

  /// Mark a token as used after payment
  Future<void> consumeToken(String tokenId) async {
    await _tokenService.consumeToken(tokenId);
    for (final t in _tokens) {
      if (t.tokenId == tokenId) {
        t.isConsumed = true;
      }
    }
    _offlineLimitRemaining = activeTokens.fold(0.0, (s, t) => s + t.amount);
    notifyListeners();
  }

  /// Check connectivity status and subscribe to ongoing changes.
  /// Calling this multiple times is safe — the previous subscription is cancelled.
  Future<void> checkConnectivity() async {
    _connectivityService.startListening();
    _isOnline = await _connectivityService.checkNow();
    notifyListeners();

    _connectivitySub?.cancel();
    _connectivitySub = _connectivityService.statusStream.listen((isOnline) {
      if (isOnline != _isOnline) {
        _isOnline = isOnline;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
