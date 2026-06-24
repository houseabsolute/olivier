import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/volume.dart';

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

  // End-to-end behavior guard: while a text field is focused the chords must not
  // control playback. NOTE: in the widget-test harness the focused EditableText
  // consumes these key events before they reach the root handler, so this proves
  // the user-facing outcome but does NOT exercise the textInputHasFocus() gate
  // (which is real-device defense covered by text_input_focus_test.dart).
  testWidgets('chords do not control playback while a text field is focused',
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

    expect(n, 0);
    expect(up, 0);
    expect(fwd, 0);
  });

  // Exclusivity: a combined Ctrl+Shift+arrow matches neither the Ctrl/Cmd chords
  // (mod && !shift) nor the Shift chords (shift && !mod), so nothing fires. This
  // is sent with no text field focused, so the event reaches the root handler.
  testWidgets('Ctrl+Shift+Right triggers neither next-track nor seek',
      (tester) async {
    var n = 0, fwd = 0;
    await pump(
        tester,
        OlivierApp(
          onNextTrack: () => n++,
          onSeekForward: () => fwd++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(n, 0);
    expect(fwd, 0);
  });

  // Production path: wire the volume callbacks to nudge() exactly as main() does
  // (under a ProviderScope) and confirm Ctrl+Up actually raises the volume.
  testWidgets('Ctrl+Up wired to nudge() raises the volume', (tester) async {
    final applied = <double>[];
    final container = ProviderContainer(overrides: [
      getSettingFnProvider
          .overrideWithValue((key) async => key == volumeKey ? '0.5' : null),
      setSettingFnProvider.overrideWithValue((key, value) async {}),
      setVolumeFnProvider.overrideWithValue((v) async => applied.add(v)),
    ]);
    addTearDown(container.dispose);
    await container.read(volumeProvider.future); // build at 0.5

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: OlivierApp(
        onVolumeUp: () =>
            container.read(volumeProvider.notifier).nudge(volumeStep),
        home: const Scaffold(body: Center(child: Text('body'))),
      ),
    ));
    await tester.pumpAndSettle();
    applied.clear();

    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowUp);

    expect(
        container.read(volumeProvider).value, closeTo(0.5 + volumeStep, 1e-9));
    expect(applied.single, closeTo(0.5 + volumeStep, 1e-9));
  });
}
