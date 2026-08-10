import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:catering_app/features/shared/role_picker_screen.dart';

void main() {
  testWidgets('Role picker is host-only; guests are told to scan a QR', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: RolePickerScreen()),
    );

    expect(find.text("I'm hosting an event"), findsOneWidget);
    expect(find.textContaining('scan the QR code'), findsOneWidget);
  });
}
