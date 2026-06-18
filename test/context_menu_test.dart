import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/widgets/context_menu.dart';

void main() {
  testWidgets('right-click shows "Add to queue" and fires callback',
      (tester) async {
    QueueEntityRef? added;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AddToQueueMenu(
          entity: const QueueEntityRef.album('rel-1'),
          onAddToQueue: (e) => added = e,
          child: const SizedBox(width: 200, height: 40, child: Text('row')),
        ),
      ),
    ));

    // Secondary (right) tap opens the menu.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Add to queue'), findsOneWidget);
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(added, isA<AlbumEntity>());
    expect((added! as AlbumEntity).releaseMbid, 'rel-1');
  });
}
