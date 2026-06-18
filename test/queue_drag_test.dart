import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/queue_panel.dart';

void main() {
  testWidgets('drag an entity onto the target appends its paths',
      (tester) async {
    final dropped = <String>[];
    final fns = EntityPathFns(
      artistPaths: (mbid) async => ['/m/$mbid-1', '/m/$mbid-2'],
      albumPaths: (r) async => ['/m/$r'],
      trackPath: (id) async => '/m/$id',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            LongPressDraggable<QueueEntityRef>(
              data: const QueueEntityRef.artist('art1'),
              feedback: const Text('drag'),
              child: const SizedBox(width: 100, height: 40, child: Text('src')),
            ),
            QueuePanelDropTarget(
              onEntityDropped: (e) async =>
                  dropped.addAll(await resolveEntityPaths(e, fns)),
              child:
                  const SizedBox(width: 200, height: 80, child: Text('queue')),
            ),
          ],
        ),
      ),
    ));

    final src = tester.getCenter(find.text('src'));
    final dst = tester.getCenter(find.text('queue'));
    final g = await tester.startGesture(src);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await g.moveTo(dst);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(dropped, ['/m/art1-1', '/m/art1-2']);
  });
}
