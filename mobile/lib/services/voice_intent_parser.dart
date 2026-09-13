// Feature G — Hindi / Hinglish voice payment intent parser.
//
// PURE DART. No network, no plugins, no Flutter widgets. Everything in this
// file must run inside a plain `flutter test` with zero platform channels so
// the parser can be exhaustively unit tested (see
// test/voice_intent_parser_test.dart).
//
// The only imports are the app's constant table, which is a `const` data-only
// file, and the pure-Dart SttResult type — neither pulls in any plugin.
//
// Design notes that matter for the demo:
//   * On the phone the recogniser runs with localeId 'hi_IN', which makes
//     Google's engine emit **Devanagari**, e.g. "रमेश को दो सौ रुपये भेजो" or
//     "रमेश को 200 रुपये भेजो". Devanagari is therefore the PRIMARY path, not
//     an exotic edge case; the Roman-Hinglish maps below matter mostly on the
//     'en_IN' fallback locale where the engine romanises.
//   * Every map holds Roman and Devanagari spellings side by side so a mixed
//     ("Hinglish") utterance parses without a language-detection step.

import '../config/constants.dart';
import 'stt/stt_engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public result types
// ─────────────────────────────────────────────────────────────────────────────

/// A parsed "pay someone some money" utterance.
class PayIntent {
  /// Rupee amount, or null when no number could be recovered.
  final double? amount;

  /// The raw (normalised) words that name the payee, e.g. "ramesh".
  /// Feed this to [resolveRecipient]; it is deliberately NOT resolved here so
  /// the parser stays pure.
  final String? recipientQuery;

  /// 0.0 – 1.0. 1.0 == amount + recipient + payment verb all present.
  final double confidence;

  /// The normalised transcript the parse was performed on.
  final String transcript;

  /// Which speech engine produced [transcript] — 'gnani' | 'mock' |
  /// 'on-device' (see `SttProvider`). Null for typed input or a plain
  /// [parse] call. Display-only: shown as a chip on the confirm screen.
  final String? provider;

  const PayIntent({
    this.amount,
    this.recipientQuery,
    required this.confidence,
    required this.transcript,
    this.provider,
  });

  /// True when there is at least a positive amount to show on the confirm
  /// screen. A missing/ambiguous recipient is still actionable — the confirm
  /// screen shows a picker.
  bool get hasAmount => amount != null && amount! > 0;

  @override
  String toString() =>
      'PayIntent(amount: $amount, recipient: $recipientQuery, '
      'confidence: ${confidence.toStringAsFixed(2)}, transcript: "$transcript")';
}

/// A contact that [resolveRecipient] believes the user meant.
class ResolvedRecipient {
  final String id;
  final String name;

  /// 0.0 – 1.0, higher is better. Sorted descending by [resolveRecipient].
  final double score;

  const ResolvedRecipient({
    required this.id,
    required this.name,
    required this.score,
  });

  @override
  String toString() =>
      'ResolvedRecipient($name, $id, ${score.toStringAsFixed(2)})';
}

/// A payee read out of the local `payment_blobs` table. Built by
/// `VoiceService.loadRecentPayees()` so this file keeps zero DB dependencies.
class RecentPayee {
  final String id;
  final String name;
  final DateTime? lastPaidAt;

  const RecentPayee({required this.id, required this.name, this.lastPaidAt});

  @override
  String toString() => 'RecentPayee($name, $id)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Vocabulary
// ─────────────────────────────────────────────────────────────────────────────

/// Plain additive number words (no multipliers). Roman Hinglish + Devanagari +
/// English, all in one table so code-switched speech needs no language guess.
const Map<String, double> _units = {
  // ── Hindi 0–10, Roman ──
  'zero': 0, 'shunya': 0,
  'ek': 1, 'aik': 1,
  'do': 2, 'don': 2,
  'teen': 3, 'tin': 3,
  'char': 4, 'chaar': 4,
  'paanch': 5, 'panch': 5, 'pach': 5, 'paanj': 5,
  'chhe': 6, 'che': 6, 'chah': 6, 'chhah': 6, 'cheh': 6,
  'saat': 7, // see _valueForUnit(): 'saath' is disambiguated by position
  'aath': 8, 'ath': 8, 'aat': 8,
  'nau': 9,
  'das': 10, 'dus': 10, 'dass': 10,
  // ── Hindi teens, Roman ──
  'gyarah': 11, 'gyaarah': 11, 'igarah': 11,
  'barah': 12, 'baarah': 12,
  'terah': 13, 'teraah': 13,
  'chaudah': 14, 'chaudaah': 14,
  'pandrah': 15, 'pandhrah': 15, 'pandarah': 15,
  'solah': 16, 'sola': 16,
  'satrah': 17,
  'atharah': 18, 'attharah': 18,
  'unnees': 19, 'unnis': 19,
  // ── Hindi tens, Roman ──
  'bees': 20, 'bis': 20,
  'pachees': 25, 'pachchees': 25, 'pachis': 25,
  'tees': 30, 'tis': 30,
  'chalis': 40, 'chalees': 40,
  'pachas': 50, 'pachaas': 50, 'pachhas': 50,
  'sattar': 70, 'sattr': 70,
  'assi': 80, 'assee': 80,
  'nabbe': 90, 'nabbey': 90,
  // ── Devanagari 0–10 ──
  'शून्य': 0,
  'एक': 1,
  'दो': 2,
  'तीन': 3,
  'चार': 4,
  'पांच': 5, 'पाँच': 5,
  'छह': 6, 'छे': 6, 'छः': 6,
  'सात': 7,
  'आठ': 8,
  'नौ': 9,
  'दस': 10,
  // ── Devanagari teens ──
  'ग्यारह': 11,
  'बारह': 12,
  'तेरह': 13,
  'चौदह': 14,
  'पंद्रह': 15, 'पन्द्रह': 15,
  'सोलह': 16,
  'सत्रह': 17,
  'अठारह': 18,
  'उन्नीस': 19,
  // ── Devanagari tens ──
  'बीस': 20,
  'पच्चीस': 25,
  'तीस': 30,
  'चालीस': 40,
  'पचास': 50,
  'साठ': 60, // unambiguous in Devanagari (साठ 60 vs सात 7)
  'सत्तर': 70,
  'अस्सी': 80,
  'नब्बे': 90,
  // ── English (Hinglish speakers mix freely) ──
  'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
  'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
  'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14,
  'fifteen': 15, 'sixteen': 16, 'seventeen': 17, 'eighteen': 18,
  'nineteen': 19, 'twenty': 20, 'thirty': 30, 'forty': 40, 'fourty': 40,
  'fifty': 50, 'sixty': 60, 'seventy': 70, 'eighty': 80, 'ninety': 90,
};

/// Multiplicative number words.
const Map<String, double> _multipliers = {
  'sau': 100, 'so': 100, 'सौ': 100,
  'hazaar': 1000, 'hajar': 1000, 'hazar': 1000, 'hajaar': 1000,
  'hazzar': 1000, 'hzar': 1000, 'हजार': 1000, 'हज़ार': 1000,
  'lakh': 100000, 'lac': 100000, 'लाख': 100000,
  'hundred': 100, 'thousand': 1000,
};

/// Fractional prefixes that only make sense in front of a multiplier.
/// "dhai sau" = 2.5 × 100 = 250, "dedh hazaar" = 1.5 × 1000 = 1500.
const Map<String, double> _fractions = {
  'dhai': 2.5, 'dhaai': 2.5, 'ढाई': 2.5,
  'dedh': 1.5, 'ded': 1.5, 'derh': 1.5, 'डेढ': 1.5,
  'sava': 1.25, 'sawa': 1.25, 'सवा': 1.25,
  'paune': 0.75, 'pone': 0.75, 'पौने': 0.75,
  'adha': 0.5, 'aadha': 0.5, 'आधा': 0.5,
};

/// Words that may appear inside a number phrase without contributing a value
/// ("two hundred **and** fifty").
const Set<String> _numberFillers = {'and', 'aur', 'और'};

/// Currency words. Also terminate a number run.
const Set<String> _currencyWords = {
  'rupaye', 'rupaya', 'rupay', 'rupaiya', 'rupiya', 'rupya', 'rupees',
  'rupee', 'rs', 'rupe', '₹',
  'रुपये', 'रुपए', 'रुपया', 'रुपैया', 'रु', 'रूपये', 'रूपए',
  'paisa', 'paise', 'पैसा', 'पैसे',
};

/// Payment verbs. Presence is a confidence boost only — it never blocks a
/// parse (people say "ramesh 200" and mean it).
const Set<String> _verbs = {
  'bhejo', 'bhej', 'bhejna', 'bheje', 'bheja', 'bhejiye', 'bhejdo',
  'bhijwao', 'bhijwa', 'bhejdena', 'bhejde',
  'send', 'sent', 'pay', 'paid', 'transfer', 'give',
  'karo', 'kar', 'kardo', 'karna', 'de', 'dedo', 'dijiye', 'dena', 'du',
  'भेजो', 'भेज', 'भेजना', 'भेजिए', 'भेजिये', 'भिजवाओ', 'भेजें',
  'करो', 'कर', 'करना', 'दे', 'दीजिए', 'देना',
  'ट्रांसफर', 'ट्रान्सफर', 'भुगतान', 'पे',
};

/// Verb stems after which a bare `do` / `दो` is the verb "give", not the
/// number two ("bhej do", "de do", "kar do").
const Set<String> _doVerbStems = {
  'bhej', 'de', 'kar', 'bheja', 'bheje', 'kara',
  'भेज', 'दे', 'कर',
};

/// Postposition marking the payee in Hindi word order ("<payee> ko …").
const Set<String> _koMarkers = {'ko', 'को', 'kau'};

/// English marker; the payee FOLLOWS it ("… to ramesh").
const Set<String> _toMarkers = {'to'};

/// Filler words that are never a payee name.
const Set<String> _stopWords = {
  'please', 'plz', 'jaldi', 'abhi', 'ab', 'ke', 'के', 'ki', 'की', 'ka', 'का',
  'liye', 'लिये', 'लिए', 'mere', 'मेरे', 'my', 'the', 'a', 'an', 'from', 'se',
  'से', 'account', 'khate', 'wallet', 'upi', 'ok', 'okay', 'haan', 'हाँ',
};

// Precomputed lookup of every token that carries numeric meaning.
final Set<String> _allNumberWords = {
  ..._units.keys,
  ..._multipliers.keys,
  ..._fractions.keys,
  'saath', // 7 or 60 depending on position — see _valueForUnit()
};

// ─────────────────────────────────────────────────────────────────────────────
// Normalisation
// ─────────────────────────────────────────────────────────────────────────────

/// Devanagari nukta folding: ज़ → ज, ड़ → ड, हज़ार → हजार, डेढ़ → डेढ.
/// Both the precomposed characters (U+0958–U+095F) and the combining nukta
/// (U+093C) collapse so one map key covers every spelling the engine emits.
const Map<int, int> _nuktaBase = {
  0x0929: 0x0928, // ऩ → न
  0x0931: 0x0930, // ऱ → र
  0x0934: 0x0933, // ऴ → ळ
  0x0958: 0x0915, // क़ → क
  0x0959: 0x0916, // ख़ → ख
  0x095A: 0x0917, // ग़ → ग
  0x095B: 0x091C, // ज़ → ज
  0x095C: 0x0921, // ड़ → ड
  0x095D: 0x0922, // ढ़ → ढ
  0x095E: 0x092B, // फ़ → फ
  0x095F: 0x092F, // य़ → य
};

bool _isAsciiDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x30 && u <= 0x39;
}

/// lowercase → Devanagari digits to ASCII → nukta folded → punctuation
/// stripped (except decimal points inside numbers) → whitespace collapsed.
String normaliseTranscript(String raw) {
  var s = raw.toLowerCase().trim();
  if (s.isEmpty) return '';

  // Devanagari digits ०१२३४५६७८९ → 0-9, plus nukta folding, in one pass.
  final folded = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x093C) continue; // combining nukta — drop
    if (r >= 0x0966 && r <= 0x096F) {
      folded.writeCharCode(0x30 + (r - 0x0966));
      continue;
    }
    folded.writeCharCode(_nuktaBase[r] ?? r);
  }
  s = folded.toString();

  // Give the rupee sign its own token: "₹500" → "₹ 500".
  s = s.replaceAll('₹', ' ₹ ');

  // Digit grouping → plain digits. Done BEFORE punctuation handling so the
  // comma never splits the number. One pattern covers Indian grouping
  // ("1,500", "1,50,000", "10,00,000" — what Gnani's ITN emits) and Western
  // ("1,500,000"): a 1–3 digit head, any ",dd" lakh groups, then at least one
  // ",ddd" group. "12,50" (a decimal comma) has no ",ddd" group and is left
  // for the decimal handling below.
  s = s.replaceAllMapped(
    RegExp(r'(?<![\d,])\d{1,3}(?:,\d\d)*(?:,\d\d\d)+(?!\d)'),
    (m) => m[0]!.replaceAll(',', ''),
  );

  // Drop everything that is not a letter, digit, Devanagari, ₹, separator or
  // whitespace.
  s = s.replaceAll(RegExp(r'[^0-9a-zऀ-ॿ₹.,\s]'), ' ');

  // Keep '.' / ',' only when they sit between two digits (a decimal amount);
  // everywhere else they are sentence punctuation.
  final cleaned = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '.' || c == ',') {
      final prevDigit = i > 0 && _isAsciiDigit(s[i - 1]);
      final nextDigit = i + 1 < s.length && _isAsciiDigit(s[i + 1]);
      cleaned.write(prevDigit && nextDigit ? c : ' ');
    } else {
      cleaned.write(c);
    }
  }
  s = cleaned.toString();

  // "rs500" → "rs 500"
  s = s.replaceAllMapped(RegExp(r'\brs(\d)'), (m) => 'rs ${m[1]}');

  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

final RegExp _digitToken = RegExp(r'^\d+(?:[.,]\d{1,2})?$');

double? _parseDigitToken(String t) {
  if (!_digitToken.hasMatch(t)) return null;
  return double.tryParse(t.replaceAll(',', '.'));
}

// ─────────────────────────────────────────────────────────────────────────────
// Number runs
// ─────────────────────────────────────────────────────────────────────────────

class _NumberRun {
  final double value;
  final int start; // inclusive token index
  final int end; // exclusive token index
  final bool hasDigit;
  const _NumberRun(this.value, this.start, this.end, this.hasDigit);
}

/// `saath` (60) vs `saat` (7).
///
/// Romanised STT output blurs the dental/retroflex distinction, so the same
/// letters can mean either. RULE: `saath` counts as 60 only when it lands in
/// the trailing-tens slot right after a multiplier ("do sau saath" = 260);
/// anywhere else we prefer **7**, which is both the commoner amount and the
/// safer error — the confirm screen is mandatory, so a wrong 7 is caught by a
/// human before any money moves, whereas silently inflating 7 → 60 is not.
double _valueForUnit(String token, {required bool afterMultiplier}) {
  if (token == 'saath' || token == 'sath') return afterMultiplier ? 60 : 7;
  return _units[token]!;
}

bool _isUnitWord(String t) => _units.containsKey(t) || t == 'saath' || t == 'sath';

/// True when `do` / `दो` at [i] is the verb "give", not the number 2.
bool _isVerbDo(List<String> tokens, int i) {
  final t = tokens[i];
  if (t != 'do' && t != 'दो') return false;
  if (i == 0) return false;
  return _doVerbStems.contains(tokens[i - 1]);
}

/// Greedily consume a number phrase starting at [start]. Returns null when
/// [start] is not the beginning of one.
_NumberRun? _scanNumberRun(List<String> tokens, int start) {
  var j = start;
  double total = 0;
  double current = 0;
  var any = false;
  var hasDigit = false;
  var sawMultiplier = false;
  var lastWasMultiplier = false;
  final plainValues = <double>[];

  while (j < tokens.length) {
    final t = tokens[j];

    if (_isVerbDo(tokens, j)) break;

    final digit = _parseDigitToken(t);
    if (digit != null) {
      // A literal number ends any word-composition immediately after it, but
      // may itself be scaled: "2 hazaar".
      current += digit;
      plainValues.add(digit);
      hasDigit = true;
      any = true;
      lastWasMultiplier = false;
      j++;
      continue;
    }

    final mult = _multipliers[t];
    if (mult != null) {
      current = (current == 0 ? 1 : current) * mult;
      sawMultiplier = true;
      lastWasMultiplier = true;
      any = true;
      if (mult >= 1000) {
        total += current;
        current = 0;
      }
      j++;
      continue;
    }

    final frac = _fractions[t];
    if (frac != null) {
      current += frac;
      any = true;
      lastWasMultiplier = false;
      j++;
      continue;
    }

    if (_isUnitWord(t)) {
      final v = _valueForUnit(t, afterMultiplier: lastWasMultiplier);
      current += v;
      plainValues.add(v);
      any = true;
      lastWasMultiplier = false;
      j++;
      continue;
    }

    if (any && _numberFillers.contains(t)) {
      j++;
      continue;
    }

    break;
  }

  if (!any) return null;

  var value = total + current;

  // Colloquial shorthand: a bare [unit 1-9][round tens] pair with no explicit
  // hundred means unit×100 + tens. "two fifty" = 250, "do pachas" = 250.
  // ("twenty five" is tens-then-unit and stays 25.)
  if (!sawMultiplier && plainValues.length == 2) {
    final a = plainValues[0];
    final b = plainValues[1];
    if (a >= 1 && a <= 9 && a == a.roundToDouble() && b >= 20 && b <= 90 && b % 10 == 0) {
      value = a * 100 + b;
    }
  }

  return _NumberRun(value, start, j, hasDigit);
}

List<_NumberRun> _findNumberRuns(List<String> tokens) {
  final runs = <_NumberRun>[];
  var i = 0;
  while (i < tokens.length) {
    final run = _scanNumberRun(tokens, i);
    if (run != null && run.end > i) {
      runs.add(run);
      i = run.end;
    } else {
      i++;
    }
  }
  return runs;
}

bool _nearCurrency(List<String> tokens, _NumberRun run) {
  for (var k = run.start - 2; k < run.end + 2; k++) {
    if (k < 0 || k >= tokens.length) continue;
    if (k >= run.start && k < run.end) continue;
    if (_currencyWords.contains(tokens[k])) return true;
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Recipient extraction
// ─────────────────────────────────────────────────────────────────────────────

bool _isReserved(String t, int i, Set<int> numberIdx) {
  if (numberIdx.contains(i)) return true;
  if (_allNumberWords.contains(t)) return true;
  if (_currencyWords.contains(t)) return true;
  if (_verbs.contains(t)) return true;
  if (_koMarkers.contains(t) || _toMarkers.contains(t)) return true;
  if (_numberFillers.contains(t) || _stopWords.contains(t)) return true;
  if (_digitToken.hasMatch(t)) return true;
  return false;
}

String? _collect(
  List<String> tokens,
  int from,
  int step,
  Set<int> numberIdx, {
  int max = 2,
}) {
  final picked = <String>[];
  var i = from;
  while (i >= 0 && i < tokens.length && picked.length < max) {
    if (_isReserved(tokens[i], i, numberIdx)) break;
    picked.add(tokens[i]);
    i += step;
  }
  if (picked.isEmpty) return null;
  if (step < 0) {
    return picked.reversed.join(' ');
  }
  return picked.join(' ');
}

String? _extractRecipient(List<String> tokens, Set<int> numberIdx) {
  // 1. Marker-anchored: "<payee> ko …" (Hindi) / "… to <payee>" (English).
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (_koMarkers.contains(t)) {
      final back = _collect(tokens, i - 1, -1, numberIdx);
      if (back != null) return back;
      final fwd = _collect(tokens, i + 1, 1, numberIdx);
      if (fwd != null) return fwd;
    } else if (_toMarkers.contains(t)) {
      final fwd = _collect(tokens, i + 1, 1, numberIdx);
      if (fwd != null) return fwd;
      final back = _collect(tokens, i - 1, -1, numberIdx);
      if (back != null) return back;
    }
  }
  // 2. Fallback: first token that is not a number / verb / currency / filler.
  for (var i = 0; i < tokens.length; i++) {
    if (_isReserved(tokens[i], i, numberIdx)) continue;
    return _collect(tokens, i, 1, numberIdx);
  }
  return null;
}

bool _hasVerb(List<String> tokens) {
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t == 'do' || t == 'दो') {
      if (_isVerbDo(tokens, i)) return true;
      continue; // bare "do" is the number two
    }
    if (_verbs.contains(t)) return true;
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// parse()
// ─────────────────────────────────────────────────────────────────────────────

/// Parses a raw STT transcript into a [PayIntent]. Never throws.
PayIntent parse(String transcript) => _parse(transcript);

/// Parses a finished [SttResult] (Feature G2).
///
/// A positive [SttResult.amountEntity] — the amount the cloud provider
/// extracted itself — wins over whatever digits the transcript contains, so a
/// mis-tokenised "₹1,50,000" can never become ₹1. The payee, verb and
/// confidence still come from the transcript. Never throws.
PayIntent parseResult(SttResult result) {
  final entity = result.amountEntity;
  final usable = entity != null && entity.isFinite && entity > 0;
  return _parse(
    result.transcript,
    amountOverride: usable ? entity : null,
    provider: result.provider,
  );
}

PayIntent _parse(
  String transcript, {
  double? amountOverride,
  String? provider,
}) {
  final normalised = normaliseTranscript(transcript);
  if (normalised.isEmpty) {
    return PayIntent(
      amount: amountOverride,
      recipientQuery: null,
      confidence: amountOverride == null ? 0.0 : 0.5,
      transcript: '',
      provider: provider,
    );
  }

  final tokens = normalised.split(' ');
  final runs = _findNumberRuns(tokens);

  // Token indices consumed by a number phrase — used so the recipient
  // extractor never picks a number word as a name.
  final numberIdx = <int>{};
  for (final r in runs) {
    for (var k = r.start; k < r.end; k++) {
      numberIdx.add(k);
    }
  }

  double? amount;
  if (runs.isNotEmpty) {
    // (a) Literal digits win over spelled-out words.
    final digitRuns = runs.where((r) => r.hasDigit).toList();
    final pool = digitRuns.isNotEmpty ? digitRuns : runs;
    if (pool.length == 1) {
      amount = pool.first.value;
    } else {
      final near = pool.where((r) => _nearCurrency(tokens, r)).toList();
      amount = (near.isNotEmpty ? near.first : pool.first).value;
    }
    if (amount <= 0) amount = null;
  }
  if (amountOverride != null) amount = amountOverride;

  final recipient = _extractRecipient(tokens, numberIdx);
  final verb = _hasVerb(tokens);

  double confidence;
  if (amount == null) {
    confidence = 0.0;
  } else {
    confidence = 1.0;
    if (recipient == null || recipient.isEmpty) confidence -= 0.25;
    if (!verb) confidence -= 0.25;
    if (confidence < 0.0) confidence = 0.0;
    if (confidence > 1.0) confidence = 1.0;
  }

  return PayIntent(
    amount: amount,
    recipientQuery: recipient,
    confidence: confidence,
    transcript: normalised,
    provider: provider,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Recipient resolution
// ─────────────────────────────────────────────────────────────────────────────

/// Classic iterative Levenshtein edit distance (two-row DP).
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var prev = List<int>.generate(b.length + 1, (i) => i);
  var curr = List<int>.filled(b.length + 1, 0);

  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var min = prev[j] + 1; // deletion
      final ins = curr[j - 1] + 1; // insertion
      if (ins < min) min = ins;
      final sub = prev[j - 1] + cost; // substitution
      if (sub < min) min = sub;
      curr[j] = min;
    }
    final swap = prev;
    prev = curr;
    curr = swap;
  }
  return prev[b.length];
}

/// 0.0 (no match) … 1.0 (exact) for one query variant against one candidate.
double _similarity(String q, String cand) {
  if (q.isEmpty || cand.isEmpty) return 0.0;
  if (q == cand) return 1.0;
  if (q.length >= 3 && cand.startsWith(q)) {
    return 0.85 + 0.10 * (q.length / cand.length);
  }
  if (cand.length >= 3 && q.startsWith(cand)) return 0.80;
  if (q.length >= 4 && cand.contains(q)) return 0.70;
  if (q.length >= 3 && cand.length >= 3) {
    final d = levenshtein(q, cand);
    if (d <= 2) return 0.75 - 0.10 * d;
  }
  return 0.0;
}

/// Fuzzily maps a [PayIntent.recipientQuery] onto known contacts.
///
/// Matches case-insensitively against (a) [AppConstants.demoContacts] names
/// and aliases and (b) any [recent] payees read from local storage. A match is
/// a prefix hit OR a Levenshtein distance ≤ 2. Best matches first; empty when
/// nothing is close enough.
List<ResolvedRecipient> resolveRecipient(
  String query, {
  Map<String, DemoContact>? contacts,
  List<RecentPayee> recent = const [],
}) {
  final q = normaliseTranscript(query);
  if (q.isEmpty) return const [];

  // Try the whole phrase and each word: "ramesh kirana" should hit the alias
  // "ramesh kirana" exactly and "ramesh" strongly.
  final variants = <String>{q, ...q.split(' ')}
      .where((v) => v.isNotEmpty && !_stopWords.contains(v))
      .toList();
  if (variants.isEmpty) return const [];

  final best = <String, ResolvedRecipient>{};

  void consider(String id, String name, List<String> candidates, double weight) {
    var score = 0.0;
    for (final raw in candidates) {
      final cand = normaliseTranscript(raw);
      if (cand.isEmpty) continue;
      for (final v in variants) {
        final s = _similarity(v, cand);
        if (s > score) score = s;
      }
    }
    if (score <= 0.0) return;
    score *= weight;
    final existing = best[id];
    if (existing == null || score > existing.score) {
      best[id] = ResolvedRecipient(id: id, name: name, score: score);
    }
  }

  final table = contacts ?? AppConstants.demoContacts;
  for (final entry in table.entries) {
    final c = entry.value;
    consider(c.id, c.name, [entry.key, c.name, ...c.aliases], 1.0);
  }
  for (final p in recent) {
    consider(p.id, p.name, [p.name], 0.95);
  }

  final out = best.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  return out;
}
