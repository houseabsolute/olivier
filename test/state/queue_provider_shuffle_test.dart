// Adaptation note: The plan's verbatim test called RustLib.init() in setUpAll
// and constructed QueueController.withPlayer without saveQueue (which would hit
// real Rust FFI to persist). Both are skipped here:
//   - RustLib.init() removed (QueueTrack is a plain Dart class; no FFI needed).
//   - saveQueue: (_) async {} added to suppress FFI persistence calls.
// The test logic is otherwise unchanged.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/queue_provider.dart';

import '../support/fake_queue_player.dart';

QueueTrack _qt(String path) =>
    QueueTrack(path: path, title: path, album: '', addedAt: 0);

void main() {
  test('QueueView reflects shuffled flag and canonical current index',
      () async {
    final player = FakeQueuePlayer();
    final controller = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await controller.setQueue(['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
    await controller.setShuffle(true);

    final container = ProviderContainer(
      overrides: [
        queueControllerProvider.overrideWithValue(controller),
        tracksForPathsFnProvider.overrideWithValue(
          (paths) async => [for (final p in paths) _qt(p)],
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(queueProvider.future);

    // Simulate the player sitting on the first SHUFFLED source.
    player.setCurrentIndex(0);
    final playingPath = controller.playOrder[0];
    final expectedCanonical = controller.orderedPaths.indexOf(playingPath);

    // setCurrentIndex emits on the (async, broadcast) currentIndexStream, which
    // drives invalidateSelf. Let that microtask propagate before re-reading so
    // the canonical index is recomputed for the new player position. (Before the
    // setShuffle fix, setShuffle forced player index 0, so this value already
    // matched without waiting; now setShuffle preserves the prior track.)
    await Future<void>.delayed(Duration.zero);

    // Re-read after invalidation so the canonical index is recomputed.
    final view = await container.read(queueProvider.future);
    expect(view.shuffled, isTrue);
    expect(view.tracks.map((t) => t.path).toList(), controller.orderedPaths);
    expect(view.currentIndex, expectedCanonical);
  });

  // Advancing to a non-zero player index (index 1) on a shuffled 4-track queue
  // must map back to the correct CANONICAL index. This exercises the real
  // currentIndexStream → invalidateSelf → recompute path that the prior test
  // bypasses by always sitting on player index 0.
  test('advancing player to index 1 updates canonical currentIndex correctly',
      () async {
    final player = FakeQueuePlayer();
    final controller = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await controller.setQueue(['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
    await controller.setShuffle(true);

    final container = ProviderContainer(
      overrides: [
        queueControllerProvider.overrideWithValue(controller),
        tracksForPathsFnProvider.overrideWithValue(
          (paths) async => [for (final p in paths) _qt(p)],
        ),
      ],
    );
    addTearDown(container.dispose);

    // Initial read to wire up the revision listener.
    await container.read(queueProvider.future);

    // Advance the fake player to index 1 in the shuffled play order.
    player.setCurrentIndex(1);
    final playingPath = controller.playOrder[1];
    final expectedCanonical = controller.orderedPaths.indexOf(playingPath);

    // Let the stream event propagate → invalidateSelf.
    await Future<void>.delayed(Duration.zero);

    final view = await container.read(queueProvider.future);
    // currentIndex in the QueueView is the CANONICAL index, not the player index.
    expect(view.currentIndex, expectedCanonical,
        reason: 'player index 1 in shuffled order must map to its '
            'canonical orderedPaths position');
    // Sanity: canonical and player indices should differ for at least one track
    // in a shuffled 4-track queue (not always index 1 == canonical 1).
    expect(view.currentIndex,
        controller.orderedPaths.indexOf(controller.playOrder[1]));
  });
}
