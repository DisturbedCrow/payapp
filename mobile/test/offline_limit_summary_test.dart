import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/providers/wallet_provider.dart';

void main() {
  group('OfflineLimitSummary', () {
    test('spent + held back by AI + available adds up to the approved limit',
        () {
      // ₹800 paid offline, and the on-device model cut the rest to ₹3,000.
      const s = OfflineLimitSummary(approved: 5000, spent: 800, available: 3000);
      expect(s.heldBackByAi, 1200);
      expect(s.spent + s.heldBackByAi + s.available, s.approved);
    });

    test('nothing held back when only the payments reduced the limit', () {
      const s = OfflineLimitSummary(approved: 5000, spent: 700, available: 4300);
      expect(s.heldBackByAi, 0);
    });

    test('never negative when the server re-issued before pending payments synced',
        () {
      const s = OfflineLimitSummary(approved: 5000, spent: 500, available: 5000);
      expect(s.heldBackByAi, 0);
    });
  });
}
