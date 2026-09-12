// Smoke test: the app builds and mounts without throwing.
//
// SplashScreen schedules a 2-second Future.delayed in initState before routing,
// so the test pumps past it and settles the animation controller — otherwise
// the test ends with a pending timer and fails.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pay/main.dart';

void main() {
  testWidgets('App builds and reaches a route without throwing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const OfflinePayApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);

    // Drain the splash delay + the fade/scale animation.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });
}
