import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/db.dart';

import '../support/fake_queue_player.dart';

/// Records every snapshot the controller persists so persistence can be
/// asserted host-VM (no real `loadQueue` FFI / LD_LIBRARY_PATH).
class _RecordingSaveQueue {
  final List<QueueSnapshot> snapshots = [];

  QueueSnapshot? get last => snapshots.isEmpty ? null : snapshots.last;

  Future<void> call(QueueSnapshot snapshot) async {
    snapshots.add(snapshot);
  }
}

// Adaptation note (host-VM test rules): the plan's verbatim Task 21 test seeded
// a real on-disk db and used RustLib.init()/loadQueue() (real Rust FFI) to read
// the persisted snapshot. That requires LD_LIBRARY_PATH / a loaded cdylib and
// cannot run under plain `flutter test`. Following the same pattern as
// test/queue_controller_ops_test.dart, we inject `saveQueue: (_) async {}` and
// assert the player/queue state via the FakeQueuePlayer (`removedIndexes`,
// `sources`) plus `controller.orderedPaths` / `controller.playOrder`. The
// substance is unchanged: drive shuffle, read the actual shuffled order from
// `controller.playOrder`, then assert removeAt removed the right canonical entry
// AND the right player source. A duplicate-path shuffled case is added to lock
// in the occurrence-aware mapping, plus an out-of-range no-op.

void main() {
  const dbPath = '/unused/test.db';

  late FakeQueuePlayer player;
  late _RecordingSaveQueue saved;
  late QueueController controller;

  setUp(() async {
    player = FakeQueuePlayer();
    saved = _RecordingSaveQueue();
    controller = QueueController.withPlayer(player,
        dbPath: dbPath, saveQueue: saved.call);
    await controller.setQueue(['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
  });

  test(
      'removeAt while shuffled removes the right canonical entry AND the '
      'right player source', () async {
    await controller.setShuffle(true);
    final shuffled = controller.playOrder;
    expect(player.sources, shuffled);

    const removedPath = '/b.flac';
    final expectedPlayerIndex = shuffled.indexOf(removedPath);

    await controller.removeAt(1); // canonical index 1 == '/b.flac'

    expect(controller.orderedPaths, ['/a.flac', '/c.flac', '/d.flac']);
    expect(player.removedIndexes, [expectedPlayerIndex]);
    expect(player.sources.contains(removedPath), isFalse);
    expect(player.sources.length, 3);
    expect(controller.playOrder.contains(removedPath), isFalse);
    // The fake's source order stays 1:1 with the controller's play order.
    expect(player.sources, controller.playOrder);
  });

  test(
      'removeAt while shuffled with DUPLICATE paths removes the player source '
      'that corresponds to the chosen canonical occurrence', () async {
    // Canonical order has '/dup.flac' twice (indices 1 and 3).
    await controller.setQueue(['/x.flac', '/dup.flac', '/y.flac', '/dup.flac']);
    await controller.setShuffle(true);

    final shuffledBefore = controller.playOrder;
    expect(player.sources, shuffledBefore);

    // Remove the SECOND '/dup.flac' (canonical index 3). The first '/dup.flac'
    // (canonical index 0 occurrence) must remain. Occurrence-aware mapping must
    // pick the player source for the 2nd occurrence, not naive indexOf (1st).
    //
    // Compute the expected player index: the 2nd '/dup.flac' encountered while
    // scanning the player order left-to-right.
    var seen = 0;
    var expectedPlayerIndex = -1;
    for (var i = 0; i < shuffledBefore.length; i++) {
      if (shuffledBefore[i] == '/dup.flac') {
        if (seen == 1) {
          expectedPlayerIndex = i;
          break;
        }
        seen++;
      }
    }
    expect(expectedPlayerIndex, greaterThanOrEqualTo(0));

    await controller.removeAt(3);

    // Canonical: only the first '/dup.flac' survives.
    expect(controller.orderedPaths, ['/x.flac', '/dup.flac', '/y.flac']);
    expect(player.removedIndexes, [expectedPlayerIndex]);
    // Exactly one '/dup.flac' remains in both player and play order.
    expect(player.sources.where((s) => s == '/dup.flac').length, 1);
    expect(controller.playOrder.where((s) => s == '/dup.flac').length, 1);
    expect(player.sources.length, 3);
    // Player source order stays 1:1 with the controller's play order.
    expect(player.sources, controller.playOrder);
  });

  test('removeAt with an out-of-range index is a no-op', () async {
    await controller.setShuffle(true);
    final before = controller.playOrder;

    await controller.removeAt(-1);
    await controller.removeAt(controller.orderedPaths.length);

    expect(
        controller.orderedPaths, ['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
    expect(controller.playOrder, before);
    expect(player.sources, before);
    expect(player.removedIndexes, isEmpty);
  });

  test('playAt while shuffled jumps to the right track via _playOrder',
      () async {
    await controller.setShuffle(true);
    final shuffled = controller.playOrder;

    const targetPath = '/c.flac';
    final expectedPlayerIndex = shuffled.indexOf(targetPath);

    await controller.playAt(2); // canonical index 2 == '/c.flac'

    expect(player.seeks.length, 1);
    expect(player.seeks.single.position, Duration.zero);
    expect(player.seeks.single.index, expectedPlayerIndex);
    expect(player.played, isTrue);
  });

  test(
      'playAt while shuffled with DUPLICATE paths seeks to the player source '
      'for the chosen canonical occurrence', () async {
    // Canonical order has '/dup.flac' twice (indices 1 and 3).
    await controller.setQueue(['/x.flac', '/dup.flac', '/y.flac', '/dup.flac']);
    await controller.setShuffle(true);

    final shuffled = controller.playOrder;

    // Expect the SECOND '/dup.flac' (canonical index 3) to map to the 2nd
    // '/dup.flac' encountered while scanning the player order left-to-right —
    // occurrence-aware, not naive indexOf (which would pick the 1st).
    var seen = 0;
    var expectedPlayerIndex = -1;
    for (var i = 0; i < shuffled.length; i++) {
      if (shuffled[i] == '/dup.flac') {
        if (seen == 1) {
          expectedPlayerIndex = i;
          break;
        }
        seen++;
      }
    }
    expect(expectedPlayerIndex, greaterThanOrEqualTo(0));

    await controller.playAt(3); // 2nd '/dup.flac'

    expect(player.seeks.length, 1);
    expect(player.seeks.single.position, Duration.zero);
    expect(player.seeks.single.index, expectedPlayerIndex);
    expect(player.played, isTrue);
  });

  test('append while shuffled adds to canonical end AND the player end',
      () async {
    await controller.setShuffle(true);
    final before = controller.playOrder.length;

    await controller.append(['/e.flac']);

    expect(controller.orderedPaths.last, '/e.flac');
    expect(controller.playOrder.length, before + 1);
    expect(controller.playOrder.last, '/e.flac');
    expect(player.sources.last, '/e.flac');

    // Host-VM persistence assertion: read the recorded snapshot the controller
    // persisted (the plan's verbatim test used the real loadQueue FFI here).
    final snap = saved.last;
    expect(snap!.paths.last, '/e.flac');
    expect(snap.shuffle, isTrue);
  });
}
