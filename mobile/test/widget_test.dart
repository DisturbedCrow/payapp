// Smoke test: the app boots and reaches the splash screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/main.dart';

void main() {
  testWidgets('App builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const OfflinePayApp());
    await tester.pump();
    expect(find.byType(OfflinePayApp), findsOneWidget);
  });
}
