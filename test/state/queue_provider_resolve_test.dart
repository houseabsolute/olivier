import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/queue_provider.dart';

import '../support/fake_queue_player.dart';

QueueTrack _qt(String path) =>
    QueueTrack(path: path, title: path, album: '', addedAt: 0);

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  // A player track-advance must update only the current-index highlight from the
  // CACHED tracklist — it must NOT re-run the tracks_for_paths FFI. (The old code
  // invalidated the whole provider on every currentIndexStream emit, which both
  // re-fetched the tracklist on every tick and, in the widget tree, re-subscribed
  // to just_audio's replay index stream — a rebuild storm. The fix caches the
  // tracks and pushes only the index, deduping repeated same-index emits.)
  test(
      'player advance updates the highlight without re-resolving the tracklist',
      () async {
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(
      player,
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    var resolveCount = 0;

    final container = ProviderContainer(
      overrides: [
        queueControllerProvider.overrideWithValue(qc),
        tracksForPathsFnProvider.overrideWithValue((paths) async {
          resolveCount++;
          return [for (final p in paths) _qt(p)];
        }),
      ],
    );
    addTearDown(container.dispose);

    // The panel watches queueProvider; keep it alive so the notifier behaves as
    // it does in the app.
    final keepAlive = container.listen(queueProvider, (_, __) {});
    addTearDown(keepAlive.close);

    await qc
        .append(['/a.flac', '/b.flac', '/c.flac']); // structural → 1 resolve
    await container.read(queueProvider.future);
    await _settle();
    expect(resolveCount, 1);

    // Advance the player. The highlight follows; the tracklist is NOT re-fetched.
    player.setCurrentIndex(1);
    await _settle();
    player.setCurrentIndex(1); // repeat same index → deduped, no state churn
    await _settle();
    player.setCurrentIndex(2);
    await _settle();

    final v = await container.read(queueProvider.future);
    expect(v.currentIndex, 2, reason: 'highlight follows the player');
    expect(v.tracks.map((t) => t.path).toList(),
        ['/a.flac', '/b.flac', '/c.flac']);
    expect(resolveCount, 1,
        reason: 'a track advance must not re-resolve the tracklist (perf)');
  });
}
