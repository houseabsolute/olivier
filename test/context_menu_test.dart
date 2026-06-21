import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/widgets/context_menu.dart';

void main() {
  testWidgets('shows Add to queue + only the provided optional actions',
      (tester) async {
    QueueEntityRef? added;
    QueueEntityRef? infoed;
    const entity = QueueEntityRef.album('rel-1');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RowContextMenu(
          entity: entity,
          onAddToQueue: (e) => added = e,
          onInfo: (e) => infoed = e,
          child: const SizedBox(width: 200, height: 40, child: Text('row')),
        ),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Re-read tags'), findsNothing); // no onReadTags given
    expect(find.text('Re-fetch from MusicBrainz'), findsNothing);

    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    expect(infoed, entity);
    expect(added, isNull);
  });

  testWidgets('shows Set reading… and invokes onSetReading', (tester) async {
    QueueEntityRef? reading;
    const entity = QueueEntityRef.artist('m-1');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RowContextMenu(
          entity: entity,
          onSetReading: (e) => reading = e,
          child: const SizedBox(width: 200, height: 40, child: Text('row')),
        ),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Set reading…'), findsOneWidget);
    await tester.tap(find.text('Set reading…'));
    await tester.pumpAndSettle();
    expect(reading, entity);
  });

  testWidgets('shows Remove from library and invokes onRemove', (tester) async {
    QueueEntityRef? removed;
    const entity = QueueEntityRef.album('rel-1');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RowContextMenu(
          entity: entity,
          onRemove: (e) => removed = e,
          child: const SizedBox(width: 200, height: 40, child: Text('row')),
        ),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Remove from library'), findsOneWidget);
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();
    expect(removed, entity);
  });
}
