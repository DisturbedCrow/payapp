// Feature G6 — the optional "LLM garnish" on top of the voice intent parser.
//
// The deterministic parser in `voice_intent_parser.dart` IS the demo: pure
// Dart, no network, exhaustively unit tested. This file is the garnish — a
// single best-effort call to `POST /api/ai/parse-intent` that can improve a
// low-confidence parse when the phone happens to be online.
//
// It is built so that deleting this file would change nothing about the
// offline demo. Every failure mode — offline, timeout, 401, a hung socket, a
// backend with no API key, a malformed payload — resolves to `null`, which
// the call site reads as "keep the local parse".
//
// Contract, in priority order:
//   1. [refine] NEVER throws and NEVER hangs. Worst case it returns null.
//   2. It only touches the network when the local parse is genuinely unsure
//      (confidence < 0.6) AND connectivity says we are online.
//   3. The whole thing — connectivity probe included — sits inside one
//      `.timeout(...)`, so a half-open socket cannot stall the confirm screen.
//   4. It returns a PayIntent only when the remote answer is strictly better
//      than the local one; anything equal or worse is discarded.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'connectivity_service.dart';
import 'voice_intent_parser.dart';

class VoiceIntentRemote {
  VoiceIntentRemote._();

  /// Backend route (Feature G6). Always answers 200; `parsed_by` says whether
  /// a model actually ran.
  static const String endpoint = '/api/ai/parse-intent';

  /// Below this the deterministic parse is treated as "unsure" and is worth a
  /// network round-trip. At or above it we never leave the device.
  /// Mirrors the threshold in the spec, and `PayIntent.confidence` semantics.
  static const double confidenceFloor = 0.6;

  /// Matches the server-side cap so we never ship a payload the backend will
  /// silently truncate anyway.
  static const int maxTranscriptChars = 500;

  static const Duration _connectivityTimeout = Duration(seconds: 2);

  /// Test seam: replaces the HTTP POST. Given the transcript, returns the
  /// decoded response body. Production leaves this null.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(String)? postOverride;

  /// Test seam: replaces the connectivity probe, which needs a platform
  /// channel and therefore cannot run under `flutter test`. Same trick as
  /// `LimitExplanationService.onlineCheckOverride`.
  @visibleForTesting
  static Future<bool> Function()? onlineCheckOverride;

  /// Clears both seams. Call from `tearDown` so cases cannot leak into
  /// each other through these statics.
  @visibleForTesting
  static void resetOverrides() {
    postOverride = null;
    onlineCheckOverride = null;
  }

  /// Returns an improved [PayIntent], or `null` to keep the local one.
  ///
  /// Never throws. Never runs longer than [timeout].
  static Future<PayIntent?> refine(
    PayIntent local, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      return await _refine(local).timeout(timeout);
    } catch (_) {
      // TimeoutException, ApiException, a plugin channel that is not there,
      // a payload that is not a JSON object — all mean the same thing here.
      return null;
    }
  }

  // ── Internals ───────────────────────────────────────────────────

  static Future<PayIntent?> _refine(PayIntent local) async {
    // 1. The local parser is confident enough — no call, no cost, no risk.
    if (local.confidence >= confidenceFloor) return null;

    final transcript = local.transcript.trim();
    if (transcript.isEmpty) return null;

    // 2. Offline (or connectivity unknown) — the whole point of this app is
    //    that this is a normal state, not an error.
    if (!await _isOnline()) return null;

    final response = await _post(
      transcript.length > maxTranscriptChars
          ? transcript.substring(0, maxTranscriptChars)
          : transcript,
    );

    // `unavailable` == the backend has no model wired up. Anything other than
    // a real LLM parse is not an improvement on the local result.
    if (_string(response['parsed_by']) != 'llm') return null;

    final remoteAmount = _positiveAmount(response['amount']);
    if (remoteAmount == null) return null;

    final remoteConfidence = _confidence(response['confidence']);

    // 3. Strictly better only: the remote found a number the local parse
    //    missed, or it is more sure about the one it found. Equal confidence
    //    loses — the deterministic parser is the one we trust by default.
    final betterThanLocal =
        !local.hasAmount || remoteConfidence > local.confidence;
    if (!betterThanLocal) return null;

    return PayIntent(
      amount: remoteAmount,
      // A remote name is only an improvement if it exists; otherwise keep
      // whatever the local parser recovered.
      recipientQuery: _name(response['recipient_query']) ?? local.recipientQuery,
      confidence: remoteConfidence,
      // The transcript is what the user actually said. The backend echoes it
      // back (possibly truncated); the local one is authoritative.
      transcript: local.transcript,
    );
  }

  static Future<Map<String, dynamic>> _post(String transcript) {
    final override = postOverride;
    if (override != null) return override(transcript);
    return ApiService().post(endpoint, {'transcript': transcript});
  }

  /// Fail-closed: if connectivity cannot be determined, treat the device as
  /// offline and skip the request rather than block on a doomed socket.
  static Future<bool> _isOnline() async {
    final override = onlineCheckOverride;
    if (override != null) {
      try {
        return await override();
      } catch (_) {
        return false;
      }
    }
    try {
      return await ConnectivityService().checkNow().timeout(
            _connectivityTimeout,
          );
    } catch (_) {
      return false;
    }
  }

  // ── Defensive coercion ──────────────────────────────────────────
  // The response is JSON from a model. Assume nothing about its types.

  static String? _string(Object? raw) => raw is String ? raw : null;

  static double? _positiveAmount(Object? raw) {
    final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (value == null || value.isNaN || value.isInfinite) return null;
    if (value <= 0 || value > 1000000) return null;
    return value;
  }

  static double _confidence(Object? raw) {
    final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (value == null || value.isNaN) return 0.0;
    return value.clamp(0.0, 1.0).toDouble();
  }

  static String? _name(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
