import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'secure_storage.dart';
import '../config/constants.dart';
import 'backend_resolver.dart';
import 'security/certificate_pinning_service.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  final FlutterSecureStorage _storage = appSecureStorage;
  final _pinning = CertificatePinningService();
  String? _authToken;

  http.Client get _client => _pinning.pinnedClient;

  Future<String?> get authToken async {
    _authToken ??= await _storage.read(key: AppConstants.tokenKey);
    return _authToken;
  }

  Future<void> setAuthToken(String token) async {
    _authToken = token;
    await _storage.write(key: AppConstants.tokenKey, value: token);
  }

  Future<void> clearAuthToken() async {
    _authToken = null;
    await _storage.delete(key: AppConstants.tokenKey);
  }

  Future<Map<String, String>> _headers() async {
    final token = await authToken;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> get(String endpoint) async {
    final base = await BackendResolver().baseUrl();
    try {
      final response = await _client
          .get(Uri.parse('$base$endpoint'), headers: await _headers())
          .timeout(const Duration(seconds: 15));
      return _handleResponse(response);
    } on ApiException {
      rethrow;
    } catch (e) {
      // A transport failure usually means the network moved under us — the
      // phone left the Wi-Fi the laptop is on, or the tunnel restarted.
      // Forget the resolved host so the next call re-probes instead of
      // failing against a dead address forever.
      await BackendResolver().invalidate();
      throw ApiException(_transportMessage);
    }
  }

  Future<Map<String, dynamic>> post(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final base = await BackendResolver().baseUrl();
    try {
      final response = await _client
          .post(
            Uri.parse('$base$endpoint'),
            headers: await _headers(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      return _handleResponse(response);
    } on ApiException {
      rethrow;
    } catch (e) {
      await BackendResolver().invalidate();
      throw ApiException(_transportMessage);
    }
  }

  /// Uploads one file as `multipart/form-data` (Feature H2: voice audio).
  ///
  /// Same contract as [post]: goes through the pinned client, a non-2xx reply
  /// surfaces as [ApiException] carrying the HTTP status (so a 503 is
  /// distinguishable from a 400), and any transport failure — including
  /// [timeout], which bounds the upload AND the response body read —
  /// invalidates the resolved backend and throws an [ApiException] with a
  /// null status.
  Future<Map<String, dynamic>> postMultipart(
    String endpoint, {
    Map<String, String> fields = const {},
    required String fileField,
    required String filePath,
    http.MediaType? contentType,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final base = await BackendResolver().baseUrl();
    try {
      final token = await authToken;
      final request = http.MultipartRequest('POST', Uri.parse('$base$endpoint'))
        // No Content-Type here: MultipartRequest sets it with the boundary.
        ..headers.addAll({
          if (token != null) 'Authorization': 'Bearer $token',
        })
        ..fields.addAll(fields)
        ..files.add(await http.MultipartFile.fromPath(
          fileField,
          filePath,
          contentType: contentType,
        ));

      final response = await () async {
        final streamed = await _client.send(request);
        return http.Response.fromStream(streamed);
      }()
          .timeout(timeout);
      if (response.statusCode >= 400) {
        final reason = fallbackReason(response.body);
        if (reason != null) {
          throw ApiException(reason, statusCode: response.statusCode);
        }
      }
      return _handleResponse(response);
    } on ApiException {
      rethrow;
    } catch (e) {
      await BackendResolver().invalidate();
      throw ApiException(_transportMessage);
    }
  }

  /// The `reason` of a `{"fallback": true, "reason": "…"}` error body (the
  /// transcribe endpoint's "use on-device" reply, e.g. `rate_limited`), else
  /// null. Such bodies carry no `detail`, so without this the reason would be
  /// lost as "Request failed".
  @visibleForTesting
  static String? fallbackReason(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['fallback'] == true) {
        final reason = decoded['reason'];
        if (reason is String && reason.isNotEmpty) return reason;
      }
    } catch (_) {/* not JSON */}
    return null;
  }

  /// Shown when no backend could be reached. Says what the user can do, and
  /// reassures them that an offline payment is still possible — which is the
  /// entire point of this app.
  static const String _transportMessage =
      'Could not reach SetuPay. Check your connection — '
      'offline payments still work.';

  Map<String, dynamic> _handleResponse(http.Response response) {
    // Guard against non-JSON responses (HTML error pages from Render/proxy)
    dynamic body;
    try {
      body = jsonDecode(response.body);
    } catch (_) {
      if (response.statusCode == 503 || response.statusCode == 502) {
        throw ApiException(
          'Server is starting up — please wait a moment and try again.',
          statusCode: response.statusCode,
        );
      }
      throw ApiException(
        'Unexpected server response (${response.statusCode}). Please try again.',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body is Map<String, dynamic> ? body : {'data': body};
    }

    final detail = body is Map
        ? (body['detail'] ?? body['message'] ?? 'Request failed')
        : 'Request failed';
    throw ApiException(detail.toString(), statusCode: response.statusCode);
  }
}

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
}
