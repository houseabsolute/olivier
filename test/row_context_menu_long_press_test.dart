import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/widgets/context_menu.dart';

Widget _wrap({required bool longPressToOpen}) => MaterialApp(
      home: Scaffold(
        body: RowContextMenu(
          entity: const QueueEntityRef.track(1),
          longPressToOpen: longPressToOpen,
          onAddToQueue: (_) {},
          child: const SizedBox(
            width: 200,
            height: 48,
            child: Text('row'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('long press opens the menu when enabled', (tester) async {
    await tester.pumpWidget(_wrap(longPressToOpen: true));

    await tester.longPress(find.text('row'));
    await tester.pumpAndSettle();

    expect(find.text('Add to queue'), findsOneWidget);
  });

  testWidgets('long press does nothing when disabled', (tester) async {
    // The wide layout keeps long-press for drag-to-queue, so the menu must not
    // steal it there.
    await tester.pumpWidget(_wrap(longPressToOpen: false));

    await tester.longPress(find.text('row'));
    await tester.pumpAndSettle();

    expect(find.text('Add to queue'), findsNothing);
  });

  testWidgets('right-click still opens the menu in both modes', (tester) async {
    for (final longPress in [true, false]) {
      await tester.pumpWidget(_wrap(longPressToOpen: longPress));
      final gesture = await tester.startGesture(
          tester.getCenter(find.text('row')),
          buttons: kSecondaryButton);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Add to queue'), findsOneWidget,
          reason: 'longPressToOpen: $longPress');

      // Dismiss before the next iteration.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
  });
}
