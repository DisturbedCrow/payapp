// Mixed flutter_secure_storage options silently logged users out on every
// cold start: an encrypted-mode call migrates (moves) plain-mode entries such
// as auth_token. Guard the single-configuration rule.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FlutterSecureStorage is only constructed in secure_storage.dart', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('services/secure_storage.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('FlutterSecureStorage(')) {
          offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'use appSecureStorage from lib/services/secure_storage.dart');
  });
}
