// Tests that index-change events from the player do NOT trigger additional
// FFI (tracksForPaths) calls. The root cause of the UI lock-up was that
// QueueNotifier called invalidateSelf() on every currentIndexStream emit,
// which triggered _resolve() → FFI for the whole queue on every playback
// event. The fix: index changes update the highlight via a cheap in-memory
// state update; only structural mutations (revision changes) trigger resolve.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/queue_provider.dart';

import '../support/fake_queue_player.dart';

QueueTrack _qt(String path) => QueueTrack(path: path, title: path, album: '');

void main() {
  test('index-stream emits do NOT trigger additional FFI resolve calls',
      () async {
    final player = FakeQueuePlayer();
    final controller = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );

    var ffiCallCount = 0;
    final container = ProviderContainer(
      overrides: [
        queueControllerProvider.overrideWithValue(controller),
        tracksForPathsFnProvider.overrideWithValue((paths) async {
          ffiCallCount++;
          return [for (final p in paths) _qt(p)];
        }),
      ],
    );
    addTearDown(container.dispose);

    // Set up queue: 3 tracks; player starts at index 0.
    await controller.setQueue(['/a.flac', '/b.flac', '/c.flac']);

    // Initial read triggers 1 FFI resolve call.
    await container.read(queueProvider.future);
    final countAfterBuild = ffiCallCount;
    expect(countAfterBuild, 1, reason: 'initial build should call FFI once');

    // Emit a duplicate index (same as current) — dedup should prevent any action.
    player.setCurrentIndex(0);
    await Future<void>.delayed(Duration.zero);

    // Emit a real index change to index 1.
    player.setCurrentIndex(1);
    await Future<void>.delayed(Duration.zero);

    // Emit the same index again — dedup should swallow it.
    player.setCurrentIndex(1);
    await Future<void>.delayed(Duration.zero);

    // None of these index emits should have triggered an additional FFI call.
    expect(
      ffiCallCount,
      countAfterBuild,
      reason:
          'currentIndexStream emits must NOT trigger additional FFI resolve calls',
    );

    // But the highlight (currentIndex) must still update to the canonical index.
    final viewAfterAdvance = await container.read(queueProvider.future);
    expect(
      viewAfterAdvance.currentIndex,
      controller.currentCanonicalIndex,
      reason: 'highlight must update to the new canonical index without FFI',
    );

    // A structural mutation (append) MUST trigger exactly one more FFI call.
    await controller.append(['/d.flac']);
    await Future<void>.delayed(Duration.zero);
    final viewAfterAppend = await container.read(queueProvider.future);
    expect(
      ffiCallCount,
      countAfterBuild + 1,
      reason:
          'structural mutation (append) should trigger exactly one FFI call',
    );
    expect(
      viewAfterAppend.tracks.map((t) => t.path).toList(),
      ['/a.flac', '/b.flac', '/c.flac', '/d.flac'],
    );
  });
}
