import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart';

void main() {
  Future<void> pump(WidgetTester tester, OlivierApp app) async {
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey modifier,
      LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  testWidgets('Ctrl+Right → next track', (tester) async {
    var n = 0;
    await pump(
        tester,
        OlivierApp(
          onNextTrack: () => n++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowRight);
    expect(n, 1);
  });

  testWidgets('Ctrl+Left → previous track', (tester) async {
    var p = 0;
    await pump(
        tester,
        OlivierApp(
          onPreviousTrack: () => p++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowLeft);
    expect(p, 1);
  });

  testWidgets('Ctrl+Up → volume up', (tester) async {
    var up = 0;
    await pump(
        tester,
        OlivierApp(
          onVolumeUp: () => up++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowUp);
    expect(up, 1);
  });

  testWidgets('Ctrl+Down → volume down', (tester) async {
    var down = 0;
    await pump(
        tester,
        OlivierApp(
          onVolumeDown: () => down++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowDown);
    expect(down, 1);
  });

  testWidgets('Shift+Right → seek forward', (tester) async {
    var fwd = 0;
    await pump(
        tester,
        OlivierApp(
          onSeekForward: () => fwd++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowRight);
    expect(fwd, 1);
  });

  testWidgets('Shift+Left → seek backward', (tester) async {
    var back = 0;
    await pump(
        tester,
        OlivierApp(
          onSeekBackward: () => back++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowLeft);
    expect(back, 1);
  });

  testWidgets('chords are suppressed while a text field is focused',
      (tester) async {
    var n = 0, up = 0, fwd = 0;
    await pump(
        tester,
        OlivierApp(
          onNextTrack: () => n++,
          onVolumeUp: () => up++,
          onSeekForward: () => fwd++,
          home: const Scaffold(body: Center(child: TextField())),
        ));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowRight);
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowUp);
    await chord(
        tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowRight);

    expect(n, 0, reason: 'Ctrl+Right must yield word-jump to the field');
    expect(up, 0);
    expect(fwd, 0, reason: 'Shift+Right must yield selection to the field');
  });
}
