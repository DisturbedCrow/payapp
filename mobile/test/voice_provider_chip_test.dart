// Feature H2 — the confirm screen says which speech engine heard the payment.
//
//   flutter test test/voice_provider_chip_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/screens/user/voice_confirm_screen.dart';
import 'package:offline_pay/services/stt/stt_engine.dart';
import 'package:offline_pay/services/voice_intent_parser.dart';

const ramesh = ResolvedRecipient(
  id: 'f30ca7a5-cc00-5efb-a792-e136e834a7aa',
  name: 'Ramesh Kirana',
  score: 1.0,
);

Widget screen(PayIntent intent, {String? provider}) => MaterialApp(
      home: VoiceConfirmScreen(
        intent: intent,
        provider: provider,
        matches: const [ramesh],
        availableLimit: 5000,
        onConfirm: (_, __) {},
        onRerecord: () {},
        onEdit: (_, __) {},
      ),
    );

void main() {
  const chip = ValueKey('voice-provider-chip');

  testWidgets('Gnani result shows the Gnani Prisma chip and the ITN amount',
      (tester) async {
    final intent = parseResult(const SttResult(
      transcript: 'ramesh ko ₹250 bhejo',
      amountEntity: 250,
      provider: SttProvider.gnani,
    ));
    await tester.pumpWidget(screen(intent));
    await tester.pump();
    expect(find.text('🎙 Gnani Prisma'), findsOneWidget);
    expect(find.text('Confirm ₹250'), findsOneWidget);
  });

  testWidgets('explicit provider wins (refine() drops it from the intent)',
      (tester) async {
    await tester.pumpWidget(
        screen(parse('ramesh ko 200 bhejo'), provider: SttProvider.onDevice));
    await tester.pump();
    expect(find.text('🎙 on-device'), findsOneWidget);
  });

  testWidgets('mock provider is labelled mock', (tester) async {
    await tester.pumpWidget(
        screen(parse('ramesh ko 200 bhejo'), provider: SttProvider.mock));
    await tester.pump();
    expect(find.text('🎙 mock'), findsOneWidget);
  });

  testWidgets('no provider -> no chip (typed / legacy callers)',
      (tester) async {
    await tester.pumpWidget(screen(parse('ramesh ko 200 bhejo')));
    await tester.pump();
    expect(find.byKey(chip), findsNothing);
  });
}
