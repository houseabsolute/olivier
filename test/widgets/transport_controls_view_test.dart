import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/transport_controls.dart';

Future<void> _pump(
  WidgetTester tester,
  TransportButtons buttons, {
  VoidCallback? onPrev,
  VoidCallback? onPlayPause,
  VoidCallback? onNext,
}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TransportControlsView(
        buttons: buttons,
        onPrev: onPrev ?? () {},
        onPlayPause: onPlayPause ?? () {},
        onNext: onNext ?? () {},
      ),
    ),
  ));
}

IconButton _btn(WidgetTester tester, IconData icon) =>
    tester.widget<IconButton>(find.ancestor(
      of: find.byIcon(icon),
      matching: find.byType(IconButton),
    ));

void main() {
  testWidgets('all enabled: each tap fires its callback', (tester) async {
    var prev = 0, play = 0, next = 0;
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: true,
        playEnabled: true,
        nextEnabled: true,
        showSpinner: false,
        showPauseIcon: false,
      ),
      onPrev: () => prev++,
      onPlayPause: () => play++,
      onNext: () => next++,
    );

    await tester.tap(find.byIcon(Icons.skip_previous));
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.tap(find.byIcon(Icons.skip_next));

    expect(prev, 1);
    expect(play, 1);
    expect(next, 1);
  });

  testWidgets('empty queue: play is disabled and does not toggle (glitch fix)',
      (tester) async {
    var play = 0;
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: false,
        playEnabled: false,
        nextEnabled: false,
        showSpinner: false,
        showPauseIcon: false,
      ),
      onPlayPause: () => play++,
    );

    expect(_btn(tester, Icons.play_arrow).onPressed, isNull);
    expect(_btn(tester, Icons.skip_previous).onPressed, isNull);
    expect(_btn(tester, Icons.skip_next).onPressed, isNull);

    await tester.tap(find.byIcon(Icons.play_arrow), warnIfMissed: false);
    expect(play, 0);
  });

  testWidgets('next disabled at the last track', (tester) async {
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: true,
        playEnabled: true,
        nextEnabled: false,
        showSpinner: false,
        showPauseIcon: false,
      ),
    );
    expect(_btn(tester, Icons.skip_next).onPressed, isNull);
    expect(_btn(tester, Icons.skip_previous).onPressed, isNotNull);
  });

  testWidgets('spinner replaces the play/pause icon when loading',
      (tester) async {
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: true,
        playEnabled: true,
        nextEnabled: true,
        showSpinner: true,
        showPauseIcon: false,
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('shows pause icon when playing', (tester) async {
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: true,
        playEnabled: true,
        nextEnabled: true,
        showSpinner: false,
        showPauseIcon: true,
      ),
    );
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });
}
