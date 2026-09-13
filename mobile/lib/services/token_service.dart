import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'secure_storage.dart';
import '../models/payment_token.dart';
import '../config/constants.dart';
import 'api_service.dart';
import 'offline_storage.dart';

class TokenService {
  final ApiService _api = ApiService();
  final FlutterSecureStorage _storage = appSecureStorage;
  final OfflineStorage _offlineStorage = OfflineStorage();

  /// Request new offline tokens from backend
  Future<Map<String, dynamic>> requestTokens({double? amount}) async {
    final body = <String, dynamic>{};
    if (amount != null) {
      body['requested_amount'] = amount;
    }

    final response = await _api.post('/api/tokens/request', body);

    // Save public key
    final publicKey = response['public_key'];
    if (publicKey != null) {
      await _storage.write(key: AppConstants.publicKeyKey, value: publicKey);
    }

    // Parse tokens
    final tokensList = (response['tokens'] as List)
        .map((t) => PaymentToken.fromJson(t))
        .toList();

    // Cache tokens locally
    await _cacheTokens(tokensList);

    // Also save to SQLite for offline access
    for (final token in tokensList) {
      await _offlineStorage.insertToken(token);
    }

    return {
      'tokens': tokensList,
      'offline_limit': (response['offline_limit'] ?? 0).toDouble(),
      'offline_limit_remaining': (response['offline_limit_remaining'] ?? 0).toDouble(),
      'risk_score': (response['risk_score'] ?? 0.5).toDouble(),
      'risk_factors': response['risk_factors'] ?? {},
    };
  }

  /// Get all active tokens (from local cache/DB)
  Future<List<PaymentToken>> getActiveTokens() async {
    // Try from SQLite first (works offline)
    final dbTokens = await _offlineStorage.getActiveTokens();
    if (dbTokens.isNotEmpty) return dbTokens;

    // Fall back to secure storage cache
    return await _getCachedTokens();
  }

  /// Find best token(s) for a given payment amount
  Future<PaymentToken?> findTokenForAmount(double amount) async {
    final tokens = await getActiveTokens();
    // Find smallest token that covers the amount
    tokens.sort((a, b) => a.amount.compareTo(b.amount));

    for (final token in tokens) {
      if (token.isValid && token.amount >= amount) {
        return token;
      }
    }
    return null;
  }

  /// Mark a token as consumed locally
  Future<void> consumeToken(String tokenId) async {
    await _offlineStorage.markTokenConsumed(tokenId);

    // Also update cache
    final tokens = await _getCachedTokens();
    for (final t in tokens) {
      if (t.tokenId == tokenId) {
        t.isConsumed = true;
      }
    }
    await _cacheTokens(tokens);
  }

  /// Get total available offline balance
  Future<double> getAvailableOfflineBalance() async {
  final tokens = await getActiveTokens();

  double total = 0.0;

  for (var t in tokens) {
    if (t.isValid) {
      total += t.amount;
    }
  }

  return total;
}

  /// Fetch active tokens from server (needs connectivity)
  Future<List<PaymentToken>> fetchActiveTokensFromServer() async {
    try {
      final response = await _api.get('/api/tokens/active');
      final tokensList = (response['tokens'] as List)
          .map((t) => PaymentToken.fromJson(t))
          .toList();
      await _cacheTokens(tokensList);
      return tokensList;
    } catch (_) {
      return await getActiveTokens();
    }
  }

  // ── Private helpers ────────────────────────────────────────

  Future<void> _cacheTokens(List<PaymentToken> tokens) async {
    final data = jsonEncode(tokens.map((t) => t.toJson()).toList());
    await _storage.write(key: AppConstants.offlineTokensKey, value: data);
  }

  Future<List<PaymentToken>> _getCachedTokens() async {
    final data = await _storage.read(key: AppConstants.offlineTokensKey);
    if (data == null) return [];
    try {
      final list = jsonDecode(data) as List;
      return list
          .map((t) => PaymentToken.fromJson(t))
          .where((t) => t.isValid)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
