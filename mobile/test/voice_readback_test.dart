// Feature G3.5 — the confirmation readback.
//
// Two things are worth testing off-device: the exact wording (pure function,
// no channel) and the promise that the service degrades to silence instead of
// throwing when `flutter_tts` is not registered — which is precisely the
// situation in this test binding, and also the situation on any demo phone
// without a TTS engine.

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/services/voice_readback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildConfirmationPhrase', () {
    test('Hindi (default) reads the spec sentence', () {
      expect(
        buildConfirmationPhrase(amount: 200, payeeName: 'Ramesh', lang: 'hi'),
        '₹200 Ramesh ko bhejne ke liye confirm karein',
      );
    });

    test('English reads the rupee amount in words order', () {
      expect(
        buildConfirmationPhrase(amount: 200, payeeName: 'Ramesh', lang: 'en'),
        'Confirm to send 200 rupees to Ramesh',
      );
    });

    test('a whole amount has no trailing .0', () {
      final hi =
          buildConfirmationPhrase(amount: 1500, payeeName: 'Vivek', lang: 'hi');
      expect(hi, startsWith('₹1500 '));
      expect(hi, isNot(contains('1500.0')));

      final en =
          buildConfirmationPhrase(amount: 1500, payeeName: 'Vivek', lang: 'en');
      expect(en, 'Confirm to send 1500 rupees to Vivek');
    });

    test('a decimal amount keeps two decimals', () {
      expect(
        buildConfirmationPhrase(
            amount: 200.5, payeeName: 'Ramesh', lang: 'hi'),
        '₹200.50 Ramesh ko bhejne ke liye confirm karein',
      );
      expect(
        buildConfirmationPhrase(
            amount: 99.99, payeeName: 'Ramesh Kirana', lang: 'en'),
        'Confirm to send 99.99 rupees to Ramesh Kirana',
      );
    });

    test('the payee name is trimmed and used verbatim', () {
      expect(
        buildConfirmationPhrase(
            amount: 50, payeeName: '  Ramesh Kirana  ', lang: 'hi'),
        '₹50 Ramesh Kirana ko bhejne ke liye confirm karein',
      );
    });

    test('an unknown language code falls back to the Hinglish wording', () {
      expect(
        buildConfirmationPhrase(amount: 10, payeeName: 'Ramesh', lang: 'ta'),
        '₹10 Ramesh ko bhejne ke liye confirm karein',
      );
    });
  });

  group('VoiceReadbackService with no platform channel', () {
    test('is a singleton and constructs without throwing', () {
      expect(VoiceReadbackService(), isNotNull);
      expect(identical(VoiceReadbackService(), VoiceReadbackService()), isTrue);
    });

    test('speakConfirmation completes silently instead of throwing', () async {
      final service = VoiceReadbackService();
      await expectLater(
        service.speakConfirmation(amount: 200, payeeName: 'Ramesh'),
        completes,
      );
      // No engine was reachable, so the status light stays off.
      expect(service.isAvailable, isFalse);
    });

    test('the English path is equally safe', () async {
      await expectLater(
        VoiceReadbackService()
            .speakConfirmation(amount: 42.5, payeeName: 'Vivek', lang: 'en'),
        completes,
      );
    });

    test('back-to-back calls do not throw', () async {
      final service = VoiceReadbackService();
      await Future.wait([
        service.speakConfirmation(amount: 100, payeeName: 'Ramesh'),
        service.speakConfirmation(amount: 250, payeeName: 'Vivek'),
      ]);
      expect(service.isAvailable, isFalse);
    });

    test('stop() is safe when nothing is speaking', () async {
      await expectLater(VoiceReadbackService().stop(), completes);
    });
  });
}
