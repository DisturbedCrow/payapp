import 'edge_limit_math.dart';
import 'edge_risk_model.dart';

/// On-device copy for Feature I: the reprice feed's "top factor" and the
/// offline "Why this limit?" explanation.
///
/// The explanation is a port of the backend's `MockExplainer`
/// (backend/app/services/explainer.py): same feature table, same direction
/// flips, same phrasing in English and Hinglish. The only additions are the
/// factors the phone alone can see (unsynced payments, hours since sync,
/// offline spend in the last hour), weighted by their actual exposure.

/// `₹5,000` / `₹1,00,000` — Indian digit grouping, no decimals. Port of the
/// backend's `rupees()`.
String rupees(num amount) {
  final n = amount.round();
  var s = n.abs().toString();
  if (s.length > 3) {
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    s = '${parts.join(',')},$tail';
  }
  return '${n < 0 ? '-' : ''}₹$s';
}

String _normLang(String lang) => lang.toLowerCase().startsWith('hi') ? 'hi' : 'en';

String _num(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

String _syncAge(double hours, String lang) {
  final h = hours < 0 ? 0.0 : hours;
  if (h < 1) {
    final minutes = (h * 60).round();
    return lang == 'hi' ? '$minutes min' : '$minutes min';
  }
  return lang == 'hi' ? '${h.round()} ghante' : '${h.round()} h';
}

/// The human label for the largest contribution to the edge score.
///
///   "2 unsynced offline payments"
///   "3 h since last sync"
///   "₹450 spent offline in the last hour"
///   "trust model baseline (KYC 3, 214 txns)"   (exposure ~0)
String edgeTopFactor({
  required OfflineExposure exposure,
  required int pendingSentCount,
  required double hoursSinceLastSync,
  required double offlineAmountLastHour,
  required RiskFeatures features,
  String lang = 'en',
}) {
  final l = _normLang(lang);
  if (exposure.total < EdgeLimitConfig.negligibleExposure) {
    final kyc = features.kycTier.round();
    final txns = features.transactionCount.round();
    return l == 'hi'
        ? 'trust model baseline (KYC $kyc, $txns payments)'
        : 'trust model baseline (KYC $kyc, $txns txns)';
  }

  if (exposure.pending >= exposure.syncAge &&
      exposure.pending >= exposure.amount) {
    final n = pendingSentCount;
    return l == 'hi'
        ? '$n offline ${n == 1 ? 'payment' : 'payments'} sync baaki'
        : '$n unsynced offline ${n == 1 ? 'payment' : 'payments'}';
  }
  if (exposure.syncAge >= exposure.amount) {
    final age = _syncAge(hoursSinceLastSync, l);
    return l == 'hi' ? '$age se sync nahi' : '$age since last sync';
  }
  final amount = rupees(offlineAmountLastHour);
  return l == 'hi'
      ? 'pichle ghante $amount offline kharch'
      : '$amount spent offline in the last hour';
}

// ── MockExplainer port ────────────────────────────────────────────────

class _Feature {
  final String name;
  final double value;
  final bool raises;
  final double weight;
  const _Feature(this.name, this.value, this.raises, this.weight);
}

// (positive, negative) phrasing per feature. {v} is the value.
const Map<String, Map<String, List<String>>> _phrases = {
  'en': {
    'kyc_tier': ['your KYC is verified to tier {v}', 'your KYC is only at tier {v}'],
    'device_trust_score': ['this phone has a strong trust score', 'this phone is still building trust'],
    'transaction_count': ['you have {v} completed payments behind you', 'you have only {v} payments so far'],
    'account_age_days': ['your account is {v} days old', 'your account is only {v} days old'],
    'avg_transaction_value': ['your payments are steady and predictable', 'we have little spending history yet'],
    'fraud_flags': ['no payment has ever been flagged', '{v} earlier {payment} was flagged'],
    'pending_unsynced_payments': ['everything is synced up', '{v} {payment} {verb} still waiting to sync'],
    'hours_since_last_sync': ['you synced in the last few hours', 'it has been {v} hours since your last sync'],
    'offline_amount_last_hour': ['nothing was spent offline recently', '{amount} was spent offline in the last hour'],
  },
  'hi': {
    'kyc_tier': ['aapka KYC tier {v} tak verified hai', 'aapka KYC abhi sirf tier {v} par hai'],
    'device_trust_score': ['is phone ka trust score strong hai', 'yeh phone abhi trust bana raha hai'],
    'transaction_count': ['aapke {v} payments successfully complete ho chuke hain', 'abhi tak sirf {v} payments hue hain'],
    'account_age_days': ['aapka account {v} din purana hai', 'aapka account abhi sirf {v} din purana hai'],
    'avg_transaction_value': ['aapke payments steady aur predictable hain', 'abhi spending history kam hai'],
    'fraud_flags': ['aaj tak koi payment flag nahi hui', '{v} purani payment flag hui thi'],
    'pending_unsynced_payments': ['sab kuch sync ho chuka hai', '{v} {payment} abhi sync hone ka wait kar rahi {verb}'],
    'hours_since_last_sync': ['aapne abhi kuch ghante pehle sync kiya tha', '{v} ghante se sync nahi hua hai'],
    'offline_amount_last_hour': ['haal mein offline kuch kharch nahi hua', 'pichle ghante mein {amount} offline kharch hue'],
  },
};

const Map<String, List<String>> _bodyTemplates = {
  'en': [
    'Your offline limit is {limit} because {pos} and {neg}.',
    'We set {limit} for offline payments: {pos}, but {neg}.',
    '{limit} is available offline right now — {pos}, though {neg}.',
    'Right now you can spend {limit} without a network. That is because {pos} while {neg}.',
    'Offline you have {limit}. The two things that decided it: {pos}, and {neg}.',
  ],
  'hi': [
    'Aapki offline limit {limit} hai kyunki {pos} aur {neg}.',
    'Humne offline ke liye {limit} set ki hai: {pos}, lekin {neg}.',
    'Abhi {limit} offline available hai — {pos}, magar {neg}.',
    'Bina network ke aap abhi {limit} kharch kar sakte hain. Kyunki {pos} jabki {neg}.',
    'Offline aapke paas {limit} hai. Do cheezein isko decide karti hain: {pos}, aur {neg}.',
  ],
};

const Map<String, Map<String, String>> _tips = {
  'en': {
    'pending_unsynced_payments': 'Get online for a few seconds — syncing your pending payments raises this straight away.',
    'offline_amount_last_hour': 'Get online for a few seconds — syncing your pending payments raises this straight away.',
    'hours_since_last_sync': 'Connect to the internet once today; a fresh sync lifts your limit immediately.',
    'kyc_tier': 'Finish the next KYC step in Profile to unlock a higher offline limit.',
    'fraud_flags': 'Keep paying normally for a few days and the flag stops counting against you.',
    'device_trust_score': 'Keep using this same phone — device trust builds up on its own.',
    'default': 'Sync once a day and complete your KYC — those two lift the limit fastest.',
  },
  'hi': {
    'pending_unsynced_payments': 'Bas kuch second online aa jaiye — pending payments sync hote hi limit badh jayegi.',
    'offline_amount_last_hour': 'Bas kuch second online aa jaiye — pending payments sync hote hi limit badh jayegi.',
    'hours_since_last_sync': 'Aaj ek baar internet se connect kariye; fresh sync se limit turant badhegi.',
    'kyc_tier': 'Profile mein agla KYC step complete kariye, offline limit badh jayegi.',
    'fraud_flags': 'Kuch din normal payments kariye, flag ka asar khatam ho jayega.',
    'device_trust_score': 'Isi phone se payment karte rahiye — device trust apne aap banta hai.',
    'default': 'Din mein ek baar sync kariye aur KYC poora kariye — limit sabse tezi se inhi se badhti hai.',
  },
};

const Map<String, Map<String, String>> _zeroLimit = {
  'en': {
    'headline': 'Offline pay is paused for now',
    'body': 'Offline payments are temporarily paused for your safety, {neg}. Nothing is wrong with your money — your balance is untouched.',
    'tip': 'Connect to the internet once and sync; that usually restores the limit right away.',
  },
  'hi': {
    'headline': 'Offline pay abhi paused hai',
    'body': 'Aapki safety ke liye offline payments filhaal paused hain, {neg}. Paise bilkul safe hain — balance par koi asar nahi.',
    'tip': 'Ek baar internet se connect karke sync kar lijiye, limit aam taur par turant wapas aa jati hai.',
  },
};

/// Port of `build_feature_payload`: real values only, direction flipped when
/// a "raises" feature sits at its floor (and vice versa).
List<_Feature> _featureTable({
  required RiskFeatures f,
  required OfflineExposure exposure,
  required int pendingSentCount,
  required double hoursSinceLastSync,
  required double offlineAmountLastHour,
  required Map<String, double> importances,
}) {
  double w(String modelName) => importances[modelName] ?? 0.1;
  final txns = f.transactionCount.round();
  final out = <_Feature>[
    _Feature('kyc_tier', f.kycTier.roundToDouble(), f.kycTier > 1, w('kyc_tier')),
    _Feature('device_trust_score', (f.deviceTrustScore * 100).round() / 100,
        f.deviceTrustScore >= 0.6, w('device_trust_score')),
    _Feature('transaction_count', txns.toDouble(), txns >= 5, w('transaction_count')),
    _Feature('account_age_days', f.daysSinceRegistration.roundToDouble(),
        f.daysSinceRegistration >= 30, w('days_since_registration')),
    if (f.avgTransactionAmount != 0)
      _Feature('avg_transaction_value', f.avgTransactionAmount.roundToDouble(),
          txns >= 5, w('avg_transaction_amount')),
    _Feature('fraud_flags', f.fraudFlags.roundToDouble(), f.fraudFlags == 0,
        w('fraud_flags')),
    // Offline context, weighted by what it actually added to the edge score.
    if (pendingSentCount > 0)
      _Feature('pending_unsynced_payments', pendingSentCount.toDouble(), false,
          exposure.pending),
    _Feature('hours_since_last_sync', hoursSinceLastSync.floorToDouble(),
        hoursSinceLastSync < 6, exposure.syncAge),
    if (offlineAmountLastHour > 0)
      _Feature('offline_amount_last_hour', offlineAmountLastHour, false,
          exposure.amount),
  ];
  return out;
}

String? _phrase(_Feature? feature, String lang, {required bool positive}) {
  if (feature == null) return null;
  final table = _phrases[lang]![feature.name];
  if (table == null) return null;
  final one = feature.value == 1;
  final payment = one ? 'payment' : 'payments';
  final verb = lang == 'hi' ? (one ? 'hai' : 'hain') : (one ? 'is' : 'are');
  return (positive ? table[0] : table[1])
      .replaceAll('{v}', _num(feature.value))
      .replaceAll('{payment}', payment)
      .replaceAll('{verb}', verb)
      .replaceAll('{amount}', rupees(feature.value));
}

/// Copy produced on the phone. Same shape as the backend's explainer.
class EdgeExplanationText {
  final String headline;
  final String body;
  final String tip;
  const EdgeExplanationText(this.headline, this.body, this.tip);
}

/// The offline "Why this limit?" copy for an edge reprice.
EdgeExplanationText explainEdgeLimit({
  required double limit,
  required RiskFeatures features,
  required int pendingSentCount,
  required double hoursSinceLastSync,
  required double offlineAmountLastHour,
  Map<String, double> importances = const {},
  String lang = 'en',
}) {
  final l = _normLang(lang);
  final exposure = OfflineExposure.of(
    pendingSentCount: pendingSentCount,
    hoursSinceLastSync: hoursSinceLastSync,
    offlineAmountLastHour: offlineAmountLastHour,
  );
  final table = _featureTable(
    f: features,
    exposure: exposure,
    pendingSentCount: pendingSentCount,
    hoursSinceLastSync: hoursSinceLastSync,
    offlineAmountLastHour: offlineAmountLastHour,
    importances: importances,
  );

  _Feature? strongest(bool raises) {
    _Feature? best;
    for (final f in table.where((f) => f.raises == raises)) {
      if (best == null || f.weight.abs() > best.weight.abs()) best = f;
    }
    return best;
  }

  final pos = strongest(true);
  final neg = strongest(false);
  var posText = _phrase(pos, l, positive: true);
  var negText = _phrase(neg, l, positive: false);
  final limitText = rupees(limit);

  if (limit <= 0) {
    final tpl = _zeroLimit[l]!;
    return EdgeExplanationText(
      tpl['headline']!,
      tpl['body']!.replaceAll(
          '{neg}',
          negText ??
              (l == 'hi'
                  ? 'kyunki abhi trust signals kam hain'
                  : 'while we build up trust signals')),
      tpl['tip']!,
    );
  }

  posText ??= l == 'hi' ? 'aapka account active hai' : 'your account is in good standing';
  negText ??= l == 'hi'
      ? 'aur koi risk signal nahi hai'
      : 'nothing is currently working against you';

  // Stable per (limit, lang) so the card does not reshuffle on every rebuild.
  final seed = '${limit.round()}|$l'.codeUnits.fold<int>(0, (a, b) => a + b);
  final variants = _bodyTemplates[l]!;
  final body = variants[seed % variants.length]
      .replaceAll('{limit}', limitText)
      .replaceAll('{pos}', posText)
      .replaceAll('{neg}', negText);
  final tip = _tips[l]![neg?.name ?? 'default'] ?? _tips[l]!['default']!;
  final headline =
      l == 'hi' ? 'Aapki offline limit: $limitText' : 'Your offline limit: $limitText';
  return EdgeExplanationText(headline, body, tip);
}
