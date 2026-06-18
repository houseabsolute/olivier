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

QueueTrack _qt(String path) => QueueTrack(path: path, title: path, album: '');

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
}
