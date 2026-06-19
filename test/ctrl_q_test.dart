import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart';

void main() {
  testWidgets('Ctrl-Q invokes the quit callback', (tester) async {
    var quit = 0;
    await tester.pumpWidget(
      OlivierApp(
        onQuit: () => quit++,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(quit, 1);
  });
}
