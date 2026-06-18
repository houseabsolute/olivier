import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/db.dart';

import 'support/fake_queue_player.dart';

/// Records every snapshot the controller persists, so tests can assert what
/// would be written without touching the Rust cdylib (the real `saveQueue`
/// FFI can't load under plain `flutter test`).
class RecordingSaveQueue {
  final List<QueueSnapshot> snapshots = [];

  QueueSnapshot? get last => snapshots.isEmpty ? null : snapshots.last;

  Future<void> call(QueueSnapshot snapshot) async {
    snapshots.add(snapshot);
  }
}

void main() {
  const dbPath = '/unused/test.db';

  test('append grows the queue, mirrors the player, bumps revision', () async {
    final player = FakeQueuePlayer();
    final saved = RecordingSaveQueue();
    final qc = QueueController.withPlayer(player,
        dbPath: dbPath, saveQueue: saved.call);

    final before = qc.revision.value;
    await qc.append(['/m/a.flac', '/m/b.flac']);

    expect(qc.orderedPaths, ['/m/a.flac', '/m/b.flac']);
    expect(player.sources, ['/m/a.flac', '/m/b.flac']);
    expect(qc.revision.value, greaterThan(before));

    // A second append extends, never replaces.
    await qc.append(['/m/c.flac']);
    expect(qc.orderedPaths, ['/m/a.flac', '/m/b.flac', '/m/c.flac']);
    expect(player.sources, ['/m/a.flac', '/m/b.flac', '/m/c.flac']);
  });

  test('append persists a QueueSnapshot reflecting the paths', () async {
    final saved = RecordingSaveQueue();
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: dbPath,
      saveQueue: saved.call,
    );
    await qc.append(['/m/a.flac', '/m/b.flac']);

    expect(saved.last, isNotNull);
    expect(saved.last!.paths, ['/m/a.flac', '/m/b.flac']);
    expect(saved.last!.shuffle, isFalse);
  });

  test('clear empties the queue, the player, and persistence', () async {
    final player = FakeQueuePlayer();
    final saved = RecordingSaveQueue();
    final qc = QueueController.withPlayer(player,
        dbPath: dbPath, saveQueue: saved.call);
    await qc.append(['/m/a.flac']);
    final before = qc.revision.value;

    await qc.clear();

    expect(qc.orderedPaths, isEmpty);
    expect(qc.playOrder, isEmpty);
    expect(player.sources, isEmpty);
    expect(qc.revision.value, greaterThan(before));

    // The latest persisted snapshot reflects the now-empty queue.
    expect(saved.last, isNotNull);
    expect(saved.last!.paths, isEmpty);
  });
}
