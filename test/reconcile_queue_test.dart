import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/src/rust/db.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

class _RecordingSaveQueue {
  final List<QueueSnapshot> snapshots = [];
  Future<void> call(QueueSnapshot s) async => snapshots.add(s);
}

QueueTrack _t(String path, {required bool present}) => QueueTrack(
      path: path,
      trackId: present ? 1 : null,
      title: path,
      album: '',
      addedAt: 0,
    );

void main() {
  late FakeQueuePlayer player;
  late QueueController controller;

  setUp(() {
    player = FakeQueuePlayer();
    controller = QueueController.withPlayer(player,
        dbPath: '/x', saveQueue: _RecordingSaveQueue().call);
  });

  test('drops queue paths that are gone from the catalog', () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac']);

    await reconcileQueueWithCatalog(
      controller,
      (paths) async => [for (final p in paths) _t(p, present: p != '/b.flac')],
    );

    expect(controller.orderedPaths, ['/a.flac', '/c.flac']);
  });

  test('leaves an all-present queue untouched', () async {
    await controller.append(['/a.flac', '/b.flac']);

    await reconcileQueueWithCatalog(
      controller,
      (paths) async => [for (final p in paths) _t(p, present: true)],
    );

    expect(controller.orderedPaths, ['/a.flac', '/b.flac']);
    expect(player.removedIndexes, isEmpty);
  });
}
