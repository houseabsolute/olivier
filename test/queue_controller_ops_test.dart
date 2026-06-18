import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/db.dart';

import 'support/fake_queue_player.dart';

// Adaptation note: The plan's verbatim test called RustLib.init() and
// loadQueue() (real Rust FFI) to verify persistence. That requires
// LD_LIBRARY_PATH / a loaded cdylib and cannot run under plain `flutter test`.
// Instead, we use a RecordingSaveQueue (same pattern as queue_controller_test.dart)
// to capture what _persist() would write, asserting paths without hitting FFI.

/// Records every snapshot the controller persists.
class RecordingSaveQueue {
  final List<QueueSnapshot> snapshots = [];

  QueueSnapshot? get last => snapshots.isEmpty ? null : snapshots.last;

  Future<void> call(QueueSnapshot snapshot) async {
    snapshots.add(snapshot);
  }
}

void main() {
  const dbPath = '/unused/test.db';

  late FakeQueuePlayer player;
  late RecordingSaveQueue saved;
  late QueueController controller;

  setUp(() {
    player = FakeQueuePlayer();
    saved = RecordingSaveQueue();
    controller = QueueController.withPlayer(player,
        dbPath: dbPath, saveQueue: saved.call);
  });

  test('removeAt drops the path, mirrors the player, persists, bumps revision',
      () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac']);
    final rev0 = controller.revision.value;

    await controller.removeAt(1);

    expect(controller.orderedPaths, ['/a.flac', '/c.flac']);
    expect(player.removedIndexes, [1]);
    expect(player.sources, ['/a.flac', '/c.flac']);
    expect(saved.last!.paths, ['/a.flac', '/c.flac']);
    expect(controller.revision.value, greaterThan(rev0));
  });

  test('reorder moves within orderedPaths, mirrors the player, persists',
      () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac']);

    await controller.reorder(0, 2);

    expect(controller.orderedPaths, ['/b.flac', '/c.flac', '/a.flac']);
    // moveAudioSource(0, 2) mirrored into the fake's source order.
    expect(player.sources, ['/b.flac', '/c.flac', '/a.flac']);
    expect(saved.last!.paths, ['/b.flac', '/c.flac', '/a.flac']);
  });

  test('clear empties the queue, the player, and persists', () async {
    await controller.append(['/a.flac', '/b.flac']);

    await controller.clear();

    expect(controller.orderedPaths, isEmpty);
    expect(controller.playOrder, isEmpty);
    expect(player.sources, isEmpty);
    expect(saved.last!.paths, isEmpty);
  });
}
