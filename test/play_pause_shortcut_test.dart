import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart';

void main() {
  testWidgets('space toggles play/pause when no text field is focused',
      (tester) async {
    var toggles = 0;
    await tester.pumpWidget(OlivierApp(
      onTogglePlayPause: () => toggles++,
      home: const Scaffold(body: Center(child: Text('body'))),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(toggles, 1);
  });

  testWidgets('space does NOT toggle while a text field is focused',
      (tester) async {
    var toggles = 0;
    await tester.pumpWidget(OlivierApp(
      onTogglePlayPause: () => toggles++,
      home: const Scaffold(body: Center(child: TextField())),
    ));
    await tester.pumpAndSettle();

    // Focus the field; space must be left for typing, not hijacked.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(toggles, 0, reason: 'space must yield to the focused text field');
  });

  testWidgets('Ctrl-Q still triggers quit', (tester) async {
    var quits = 0;
    await tester.pumpWidget(OlivierApp(
      onQuit: () => quits++,
      home: const Scaffold(body: Center(child: Text('body'))),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(quits, 1);
  });
}
