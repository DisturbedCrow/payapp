import 'package:flutter/foundation.dart';

class AppConstants {
  // ── Branding ─────────────────────────────────────────────────
  static const String appName = 'SetuPay';
  static const String appTagline = 'Offline payments with an AI trust layer';
  static const String upiSuffix = '@setupay';

  // ── Demo-day feature flags (Sept 13 sprint) ──────────────────
  // Every new behaviour ships behind one of these so the three existing
  // payment cases keep working exactly as before when a flag is off.
  static const bool demoMode = true;
  static const bool voicePayEnabled = true;
  static const bool qrHandoffEnabled = true;
  static const bool riskExplainerEnabled = true;

  // Backend API URL
  // Override at build time:  flutter run --dart-define=API_URL=https://your-app.onrender.com
  static const String _envUrl = String.fromEnvironment('API_URL', defaultValue: '');

  static String get baseUrl {
    if (_envUrl.isNotEmpty) return _envUrl;
    if (kIsWeb) return 'http://127.0.0.1:8000';
    if (defaultTargetPlatform == TargetPlatform.android) return 'https://offlinepay-api.onrender.com';
    return 'https://offlinepay-api.onrender.com'; // production
  }

  // Storage keys
  static const String tokenKey = 'auth_token';
  static const String userKey = 'user_data';
  static const String publicKeyKey = 'server_public_key';
  static const String offlineTokensKey = 'offline_tokens';
  static const String limitExplanationCacheKey = 'limit_explanation_cache';
  static const String explainerLangKey = 'explainer_lang';

  // Database
  static const String dbName = 'offline_pay.db';
  static const int dbVersion = 5; // v5: payment_blobs.handoff_method + direction

  // Token settings
  static const int maxOfflineTokens = 10;
  static const Duration tokenCheckInterval = Duration(minutes: 5);

  // Sync settings
  static const Duration syncInterval = Duration(seconds: 30);
  static const int maxSyncRetries = 3;

  // ── Voice payments (Feature G) ───────────────────────────────
  // Seeded demo contacts, resolvable with the phone in airplane mode. Ids
  // are the deterministic uuid5 values backend/seed.py assigns to the
  // demo-day cast (see backend/app/services/demo_ids.py).
  static const Map<String, DemoContact> demoContacts = {
    'ramesh': DemoContact(
      id: 'f30ca7a5-cc00-5efb-a792-e136e834a7aa',
      name: 'Ramesh Kirana',
      aliases: ['ramesh', 'ramesh kirana', 'kirana', 'रमेश'],
    ),
    'vivek': DemoContact(
      id: 'a7f6c445-d25b-5ae0-b382-e2a6144d9549',
      name: 'Vivek Sharma',
      aliases: ['vivek', 'vivek sharma', 'विवेक'],
    ),
  };
  static const Duration voiceMaxListen = Duration(seconds: 8);
  static const Duration voicePauseFor = Duration(milliseconds: 1200);
}

class DemoContact {
  final String id;
  final String name;
  final List<String> aliases;
  const DemoContact({required this.id, required this.name, required this.aliases});
}
