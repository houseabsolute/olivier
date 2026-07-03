import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/db.dart';

import '../support/fake_queue_player.dart';

void main() {
  test('savePlayhead persists the live index and position', () async {
    QueueSnapshot? saved;
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);
    await queue.append(['/a.flac', '/b.flac', '/c.flac']);
    player.setCurrentIndex(2);
    player.positionValue = const Duration(seconds: 30);
    saved = null; // drop the append()'s own persist

    await queue.savePlayhead();

    expect(saved, isNotNull);
    expect(saved!.currentIndex, 2);
    expect(saved!.positionMs.toInt(), 30000);
  });

  test('savePlayhead does nothing when the queue is empty', () async {
    QueueSnapshot? saved;
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);

    await queue.savePlayhead();

    expect(saved, isNull);
  });

  test('savePlayhead skips when the player index is unresolvable', () async {
    QueueSnapshot? saved;
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);
    await queue.append(['/a.flac']);
    player.setCurrentIndex(5); // out of range -> currentCanonicalIndex == null
    saved = null;

    await queue.savePlayhead();

    expect(saved, isNull);
  });

  test('a mid-track playhead survives save -> restore', () async {
    final dir = await Directory.systemTemp.createTemp('olivier_playhead');
    addTearDown(() => dir.delete(recursive: true));
    final paths = <String>[
      for (final n in ['a', 'b', 'c'])
        (await File('${dir.path}/$n.flac').writeAsString('x')).path,
    ];

    QueueSnapshot? saved;
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);
    await queue.append(paths);
    player.setCurrentIndex(1);
    player.positionValue = const Duration(seconds: 45);
    await queue.savePlayhead();

    final player2 = FakeQueuePlayer();
    final queue2 = QueueController.withPlayer(player2,
        dbPath: ':memory:', saveQueue: (_) async {});
    await queue2.restoreFromSnapshot(saved!);

    expect(player2.lastInitialIndex, 1);
    expect(player2.lastInitialPosition, const Duration(milliseconds: 45000));
  });
}
