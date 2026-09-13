// The dashboard repaints its limit pill from OfflineLimitService.limitChanged.
// A sync saves the server limit after the edge engine has repriced, so every
// write must notify — otherwise the pill kept the offline number after sync.
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/services/offline_limit_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every limit write bumps limitChanged', () async {
    final limits = OfflineLimitService();
    var bumps = 0;
    void listener() => bumps++;
    limits.limitChanged.addListener(listener);
    addTearDown(() => limits.limitChanged.removeListener(listener));

    await limits.updateLimitFromSync(5000);        // server limit saved
    await limits.deductFromLimit(200);             // offline payment
    await limits.updateRemainingOnly(1500);        // edge reprice
    await limits.applyLocalRiskPenalty(2);         // fallback penalty
    await limits.resetRemainingToTotal();          // all settled

    expect(bumps, 5);
    expect(await limits.getAvailableLimit(), 5000);
  });
}
