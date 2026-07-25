import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_view.dart';
import 'package:olivier/widgets/queue_swipe_target.dart';

late ProviderContainer container;

Widget _bar() {
  container = ProviderContainer(
    overrides: [dbPathProvider.overrideWithValue(':memory:')],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(
        bottomNavigationBar: QueueSwipeTarget(
          child: SizedBox(height: 80, child: Center(child: Text('bar'))),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('swiping up opens the queue', (tester) async {
    await tester.pumpWidget(_bar());
    expect(container.read(queueExpandedProvider), isFalse);

    await tester.drag(find.text('bar'), const Offset(0, -100));
    await tester.pumpAndSettle();

    expect(container.read(queueExpandedProvider), isTrue);
  });

  testWidgets('swiping down closes it', (tester) async {
    await tester.pumpWidget(_bar());
    container.read(queueExpandedProvider.notifier).toggle();
    await tester.pumpAndSettle();

    await tester.drag(find.text('bar'), const Offset(0, 100));
    await tester.pumpAndSettle();

    expect(container.read(queueExpandedProvider), isFalse);
  });

  testWidgets('swiping up again leaves it open', (tester) async {
    await tester.pumpWidget(_bar());
    await tester.drag(find.text('bar'), const Offset(0, -100));
    await tester.pumpAndSettle();

    await tester.drag(find.text('bar'), const Offset(0, -100));
    await tester.pumpAndSettle();

    expect(container.read(queueExpandedProvider), isTrue,
        reason: 'up means open, not toggle');
  });

  testWidgets('swiping down when already closed is a no-op', (tester) async {
    await tester.pumpWidget(_bar());

    await tester.drag(find.text('bar'), const Offset(0, 100));
    await tester.pumpAndSettle();

    expect(container.read(queueExpandedProvider), isFalse);
  });

  testWidgets('a short upward drag does not open it', (tester) async {
    await tester.pumpWidget(_bar());

    await tester.drag(find.text('bar'), const Offset(0, -30));
    await tester.pumpAndSettle();

    expect(container.read(queueExpandedProvider), isFalse,
        reason: 'brushing the bar on the way to the play button');
  });

  testWidgets('a tiny downward drag does not close it', (tester) async {
    // The downward threshold is small — Android's gesture zone truncates the
    // drag — but it is not zero.
    await tester.pumpWidget(_bar());
    container.read(queueExpandedProvider.notifier).toggle();
    await tester.pumpAndSettle();

    await tester.drag(find.text('bar'), const Offset(0, 8));
    await tester.pumpAndSettle();

    expect(container.read(queueExpandedProvider), isTrue);
  });

  testWidgets('a downward drag too small to be an upward swipe still closes',
      (tester) async {
    // 30px would not open the queue, but it must close it: the bar has no room
    // to travel further down on a gesture-nav phone.
    await tester.pumpWidget(_bar());
    container.read(queueExpandedProvider.notifier).toggle();
    await tester.pumpAndSettle();

    await tester.drag(find.text('bar'), const Offset(0, 30));
    await tester.pumpAndSettle();

    expect(container.read(queueExpandedProvider), isFalse);
  });

  testWidgets('a horizontal drag is ignored', (tester) async {
    // The bar's seek slider owns horizontal drags; this must not fight it.
    await tester.pumpWidget(_bar());

    await tester.drag(find.text('bar'), const Offset(120, 0));
    await tester.pumpAndSettle();

    expect(container.read(queueExpandedProvider), isFalse);
  });
}
