import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'secure_storage.dart';
import '../models/user.dart';
import '../config/constants.dart';
import 'api_service.dart';

class AuthService {
  final ApiService _api = ApiService();
  final FlutterSecureStorage _storage = appSecureStorage;

  Future<AppUser> register({
    required String email,
    required String password,
    required String fullName,
    String? phone,
    String role = 'user',
  }) async {
    final response = await _api.post('/api/auth/register', {
      'email': email,
      'password': password,
      'full_name': fullName,
      'phone': phone,
      'role': role,
    });

    final token = response['access_token'];
    await _api.setAuthToken(token);

    final user = AppUser.fromJson(response['user']);
    await _saveUser(user);

    return user;
  }

  Future<AppUser> login({
    required String email,
    required String password,
  }) async {
    final response = await _api.post('/api/auth/login', {
      'email': email,
      'password': password,
    });

    final token = response['access_token'];
    await _api.setAuthToken(token);

    final user = AppUser.fromJson(response['user']);
    await _saveUser(user);

    return user;
  }

  Future<AppUser?> getCurrentUser() async {
    try {
      final response = await _api.get('/api/auth/me');
      final user = AppUser.fromJson(response);
      await _saveUser(user);
      return user;
    } catch (_) {
      return await _getSavedUser();
    }
  }

  Future<void> logout() async {
    await _api.clearAuthToken();
    await _storage.delete(key: AppConstants.userKey);
  }

  Future<bool> isLoggedIn() async {
    final token = await _api.authToken;
    return token != null && token.isNotEmpty;
  }

  Future<void> _saveUser(AppUser user) async {
    await _storage.write(
      key: AppConstants.userKey,
      value: jsonEncode(user.toJson()),
    );
  }

  Future<AppUser?> _getSavedUser() async {
    final data = await _storage.read(key: AppConstants.userKey);
    if (data == null) return null;
    try {
      return AppUser.fromJson(jsonDecode(data));
    } catch (_) {
      return null;
    }
  }
}
