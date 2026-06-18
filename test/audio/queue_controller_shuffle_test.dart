import 'dart:io';

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

  test('setShuffle bumps the revision Listenable', () async {
    final start = controller.revision.value;
    await controller.setShuffle(true);
    expect(controller.revision.value, start + 1);
    await controller.setShuffle(false);
    expect(controller.revision.value, start + 2);
  });

  // Adaptation note (host-VM test rules): the plan's verbatim test called
  // `loadQueue(dbPath: dbPath)` (real Rust FFI / LD_LIBRARY_PATH). We instead
  // read the last recorded snapshot from `saved` — same substance, no FFI.
  test('toggling shuffle OFF restores canonical order in the player', () async {
    await controller.setShuffle(true);
    await controller.setShuffle(false);

    expect(controller.shuffled, isFalse);
    expect(controller.playOrder, controller.orderedPaths);
    expect(player.sources, ['/a.flac', '/b.flac', '/c.flac', '/d.flac']);

    final snap = saved.last;
    expect(snap!.shuffle, isFalse);
    expect(snap.paths, ['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
  });

  test(
      'shuffled playOrder is a permutation of orderedPaths and the player '
      'matches it', () async {
    await controller.setShuffle(true);
    expect(controller.shuffled, isTrue);
    expect(controller.playOrder.toSet(), controller.orderedPaths.toSet());
    expect(player.sources, controller.playOrder);
  });

  // Persist-while-shuffled must save a CANONICAL currentIndex so that a fresh
  // controller restoring the snapshot resumes on the SAME track. With the old
  // _persist (which saved the player-order index alongside canonical paths)
  // this round-trips to the WRONG track when shuffled.
  test('persist while shuffled round-trips restore to the same canonical track',
      () async {
    // Use real on-disk files so restoreFromSnapshot's File.exists guard keeps
    // them (it drops paths that don't exist).
    final dir = await Directory.systemTemp.createTemp('queue_restore_test');
    addTearDown(() => dir.delete(recursive: true));
    final paths = <String>[];
    for (final name in ['a', 'b', 'c', 'd']) {
      final f = File('${dir.path}/$name.flac');
      await f.writeAsString('x');
      paths.add(f.path);
    }

    await controller.setQueue(paths);
    await controller.setShuffle(true);

    // Advance the fake player to a non-zero player-order position whose
    // canonical track is known, then trigger a persist while there.
    const pi = 2;
    player.setCurrentIndex(pi);
    final expectedCanonicalPath = controller.playOrder[pi];
    // append persists WITHOUT rebuilding, so the player stays on index pi. Use a
    // brand-new unique path so the existing tracks stay unique (unambiguous
    // canonical mapping).
    final extra = File('${dir.path}/extra.flac');
    await extra.writeAsString('x');
    await controller.append([extra.path]);

    // Capture the snapshot the controller just wrote and assert it is
    // canonical-correct (the saved currentIndex addresses the saved paths).
    final snap = saved.last!;
    expect(snap.shuffle, isTrue);
    // The saved canonical currentIndex must address the saved canonical paths
    // and point at the track that was playing.
    expect(snap.paths[snap.currentIndex], expectedCanonicalPath);

    // Restore on a FRESH controller + fresh fake player and confirm it resumes
    // on the same canonical track.
    final freshPlayer = FakeQueuePlayer();
    final fresh = QueueController.withPlayer(freshPlayer,
        dbPath: dbPath, saveQueue: (_) async {});
    await fresh.restoreFromSnapshot(snap);

    final restoredCanonicalIndex = fresh.currentCanonicalIndex;
    expect(restoredCanonicalIndex, isNotNull);
    expect(fresh.orderedPaths[restoredCanonicalIndex!], expectedCanonicalPath);
  });

  // Toggling shuffle must keep the currently-playing track playing, not restart
  // from canonical-0.
  test('setShuffle preserves the currently-playing canonical track', () async {
    // Queue is the 4 tracks from setUp; put the player on canonical track 2.
    // Not shuffled yet, so player index == canonical index.
    player.setCurrentIndex(2);
    expect(controller.currentCanonicalIndex, 2);
    const track2 = '/c.flac';

    await controller.setShuffle(true);
    // The player's current source must still be track 2's path, not track 0.
    expect(player.sources[player.currentIndex!], track2);
    expect(controller.currentCanonicalIndex, 2);

    await controller.setShuffle(false);
    expect(player.sources[player.currentIndex!], track2);
    expect(controller.currentCanonicalIndex, 2);
  });

  // reorder while shuffled (previously untested branch): only the canonical
  // order + persisted snapshot change; the player order stays put.
  test('reorder while shuffled changes canonical order only', () async {
    await controller.setShuffle(true);
    final playOrderBefore = controller.playOrder;
    final sourcesBefore = List.of(player.sources);

    await controller.reorder(0, 3);

    // Canonical order changed: first element moved to the end.
    expect(
        controller.orderedPaths, ['/b.flac', '/c.flac', '/d.flac', '/a.flac']);
    // Player order / sources did NOT change.
    expect(controller.playOrder, playOrderBefore);
    expect(player.sources, sourcesBefore);

    final snap = saved.last;
    expect(snap!.paths, ['/b.flac', '/c.flac', '/d.flac', '/a.flac']);
    expect(snap.shuffle, isTrue);
  });

  // currentCanonicalIndex must be occurrence-aware: with duplicate paths it must
  // return the canonical index of the SPECIFIC occurrence playing, not the first
  // canonical match.
  test('currentCanonicalIndex is duplicate-aware', () async {
    await controller.setQueue(['/a.flac', '/dup.flac', '/b.flac', '/dup.flac']);
    await controller.setShuffle(true);

    // Find the player index of the SECOND '/dup.flac' in the shuffled order.
    final order = controller.playOrder;
    var seen = 0;
    var secondDupPlayerIndex = -1;
    for (var i = 0; i < order.length; i++) {
      if (order[i] == '/dup.flac') {
        if (seen == 1) {
          secondDupPlayerIndex = i;
          break;
        }
        seen++;
      }
    }
    expect(secondDupPlayerIndex, greaterThanOrEqualTo(0));

    player.setCurrentIndex(secondDupPlayerIndex);
    expect(controller.currentCanonicalIndex, 3);
  });
}
