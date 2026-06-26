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

  test('playAt seeks to the canonical index and plays (not shuffled)',
      () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac']);

    await controller.playAt(2);

    // Not shuffled: canonical index 2 == player index 2. (append to the empty
    // queue first seeks to index 0, so assert playAt's seek is the last one.)
    expect(player.seeks.last.index, 2);
    expect(player.played, isTrue);
  });

  test(
      'removePaths drops all matching entries incl. duplicates, mirrors player',
      () async {
    await controller
        .append(['/a.flac', '/b.flac', '/c.flac', '/b.flac', '/d.flac']);

    await controller.removePaths({'/b.flac', '/d.flac'});

    expect(controller.orderedPaths, ['/a.flac', '/c.flac']);
    expect(controller.playOrder, ['/a.flac', '/c.flac']);
    expect(player.sources, ['/a.flac', '/c.flac']);
    // Descending removal: indices 4 (/d), 3 (/b), 1 (/b).
    expect(player.removedIndexes, [4, 3, 1]);
    expect(saved.last!.paths, ['/a.flac', '/c.flac']);
  });

  test('removePaths that empties the queue clears the player', () async {
    await controller.append(['/a.flac', '/b.flac']);

    await controller.removePaths({'/a.flac', '/b.flac'});

    expect(controller.orderedPaths, isEmpty);
    expect(controller.playOrder, isEmpty);
    expect(player.sources, isEmpty);
  });

  test('removePaths is a no-op for an empty set', () async {
    await controller.append(['/a.flac']);
    final removedBefore = player.removedIndexes.length;

    await controller.removePaths({});

    expect(controller.orderedPaths, ['/a.flac']);
    expect(player.removedIndexes.length, removedBefore);
  });

  test('removePaths keeps canonical + shuffled player order consistent',
      () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
    await controller.setShuffle(true); // _playOrder is now a shuffle of the 4

    await controller.removePaths({'/b.flac', '/d.flac'});

    // Canonical order keeps its order, minus the removed paths.
    expect(controller.orderedPaths, ['/a.flac', '/c.flac']);
    // Player order survives as the same multiset (its shuffled order is random),
    // and the fake player's sources stay 1:1 with it — i.e. no desync.
    expect(controller.playOrder.toSet(), {'/a.flac', '/c.flac'});
    expect(controller.playOrder.length, 2);
    expect(player.sources, controller.playOrder);
  });

  test('replaceLibraryShuffled makes the queue a shuffled list played from top',
      () async {
    await controller.replaceLibraryShuffled(['/a.flac', '/b.flac', '/c.flac']);

    // The canonical (displayed) order is the shuffled track list — same multiset.
    expect(controller.orderedPaths.toSet(), {'/a.flac', '/b.flac', '/c.flac'});
    expect(controller.orderedPaths.length, 3);
    // Not the separate play-order shuffle indirection.
    expect(controller.shuffled, isFalse);
    // Plays from the TOP of that list (canonical index 0), and is playing.
    expect(controller.currentCanonicalIndex, 0);
    expect(player.played, isTrue);
  });

  test('append to an empty queue makes the first added track current',
      () async {
    await controller.append(['/x.flac', '/y.flac']);
    expect(controller.currentCanonicalIndex, 0);
    // Establishes the current via a seek to player index 0.
    expect(player.seeks.where((s) => s.index == 0), isNotEmpty);
  });

  test('append to a non-empty queue does not move the current track', () async {
    await controller.append(['/x.flac']); // empty -> current 0
    final seeksAfterFirst = player.seeks.length;
    await controller.append(['/y.flac']); // non-empty -> no re-seek
    expect(controller.currentCanonicalIndex, 0); // still /x.flac
    expect(player.seeks.length, seeksAfterFirst); // no extra seek
  });
}
