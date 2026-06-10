// Smoke test for the Aurora launcher.
//
// The full app boots an async orchestrator (profiles, notification
// service, wapp scan) that needs platform channels, so this stays a
// lightweight build-only smoke test of the root widget shell. Deeper
// launcher behaviour is exercised by running the app directly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/launcher/launcher.dart';

void main() {
  testWidgets('AuroraApp builds without throwing', (WidgetTester tester) async {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(IwiApp(messengerKey: messengerKey));
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
