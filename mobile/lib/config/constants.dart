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

  // ── Backend API URL ──────────────────────────────────────────
  //
  // There is no single correct address. The same APK has to work for a phone
  // on the venue Wi-Fi, a phone on 5G, a USB-tethered demo device and a
  // developer on the office LAN. BackendResolver probes these and uses the
  // first that answers /health, so the app is not hostage to one host.
  //
  // Pin one explicitly at build time when you need to:
  //   flutter build apk --dart-define=API_URL=https://your-backend
  static const String apiUrlOverride =
      String.fromEnvironment('API_URL', defaultValue: '');

  /// Publicly reachable HTTPS backend — the ONLY candidate that works on
  /// mobile data, which is what most phones will be on. Override at build
  /// time with --dart-define=PUBLIC_API_URL=...
  ///
  /// PROD-TODO: point this at the permanent deployment. The current value is
  /// a Cloudflare quick tunnel to the demo laptop, which changes every time
  /// the tunnel restarts.
  static const String publicApiUrl = String.fromEnvironment(
    'PUBLIC_API_URL',
    defaultValue: 'https://pichunter-commentary-arbitrary-extraordinary.trycloudflare.com',
  );

  /// Same-LAN laptop addresses. Fast when they apply, skipped in ~4s when
  /// they do not. 10.0.2.2 is the Android emulator's route to its host.
  static const List<String> lanApiUrls = [
    'http://192.168.1.11:8000',
    'http://10.0.2.2:8000',
  ];

  /// Best-guess synchronous URL, for the rare caller that cannot await.
  /// Prefer `await BackendResolver().baseUrl()`.
  static String get baseUrl {
    if (apiUrlOverride.isNotEmpty) return apiUrlOverride;
    if (publicApiUrl.isNotEmpty) return publicApiUrl;
    return lanApiUrls.first;
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
    // ── Stage pair ──────────────────────────────────────────
    // Aliases cover what the hi_IN recogniser actually returns: Devanagari
    // first, then Roman. "Jyati" is close enough to the far more common
    // "Jyoti" that Google will often transcribe it that way — both spellings
    // are listed so the payee still resolves, and the fuzzy matcher
    // (Levenshtein <= 2) catches the rest.
    'jyati': DemoContact(
      id: '8061253a-e03b-538b-a8b5-75194294fec1',
      name: 'Jyati Kirana',
      // Deliberately NOT the bare surname 'kirana' — Ramesh Kirana shares it,
      // and an exact hit on a shared surname outranked his full name, so
      // "ramesh kirana" resolved to Jyati. Aliases must be distinguishing.
      aliases: [
        'jyati', 'jyati kirana', 'jyoti', 'jyoti kirana',
        'ज्याति', 'ज्योति', 'जयति', 'ज्याती',
      ],
    ),
    'ashmita': DemoContact(
      id: 'a7996138-97cf-5b93-a039-eb2ed11e7f3c',
      name: 'Ashmita Rao',
      aliases: ['ashmita', 'ashmita rao', 'asmita', 'अश्मिता', 'अस्मिता'],
    ),
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
