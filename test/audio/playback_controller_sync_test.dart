import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';

import '../support/fake_queue_player.dart';

/// Host-VM coverage that the PlaybackController FOLLOWS the live queue: a queue
/// mutation bumps `QueueController.revision`, which must drive a rebuild of the
/// audio_service `queue` + `mediaItem` from the player's actual play order — the
/// exact path that was broken (the now-playing bar showed "Nothing playing").
///
/// What this exercises: a REAL [OlivierAudioHandler] (its `queue`/`mediaItem`
/// BehaviorSubjects come from BaseAudioHandler and work headless; its
/// `player.currentIndex` reads null without the media_kit channel), a real
/// [QueueController] over a [FakeQueuePlayer], and the revision listener →
/// `_syncNowPlayingFromQueue` wiring. The `tracksForPaths` FFI is replaced by an
/// injected fake. (See coverage note at the bottom for what is NOT covered.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OlivierAudioHandler handler;
  late FakeQueuePlayer player;
  late QueueController queue;
  late PlaybackController playback;

  QueueTrack track(String path, {int? id}) => QueueTrack(
        path: path,
        trackId: id,
        title: 'Title $path',
        artist: 'Artist $path',
        album: 'Album $path',
        lengthMs: BigInt.from(1000),
        titleTranslit: null,
        titleTranslate: null,
      );

  setUp(() {
    handler = OlivierAudioHandler();
    player = FakeQueuePlayer();
    queue = QueueController.withPlayer(player,
        dbPath: '/unused/test.db', saveQueue: (_) async {});
    playback = PlaybackController(
      audioHandler: handler,
      queueController: queue,
      dbPath: '/unused/test.db',
      // Resolve metadata straight from the paths — no Rust bridge.
      tracksForPathsFn: (paths) async => [for (final p in paths) track(p)],
    );
  });

  tearDown(() => playback.dispose());

  test(
      'append bumps revision -> queue + mediaItem are populated from playOrder',
      () async {
    await queue.setQueue(['/a.flac', '/b.flac']);
    await pumpEventQueue();

    final q = handler.queue.value;
    expect(q.map((m) => m.id).toList(), ['/a.flac', '/b.flac']);
    // current index is 0 (FakeQueuePlayer seeds it on setAudioSources).
    expect(handler.mediaItem.value?.id, '/a.flac');

    await queue.append(['/c.flac']);
    await pumpEventQueue();

    expect(handler.queue.value.map((m) => m.id).toList(),
        ['/a.flac', '/b.flac', '/c.flac']);
  });

  test('rebuild uses playOrder (shuffled), not the canonical orderedPaths',
      () async {
    await queue.setQueue(['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
    await queue.setShuffle(true);
    await pumpEventQueue();

    // The audio_service queue must mirror the player's shuffled order so index
    // lookups (mediaItem, play tracking) line up 1:1 with the player.
    expect(handler.queue.value.map((m) => m.id).toList(), queue.playOrder);
    expect(handler.queue.value.map((m) => m.id).toList(),
        isNot(orderedEquals(queue.orderedPaths)));
  });

  test('clear empties the now-playing queue', () async {
    await queue.setQueue(['/a.flac', '/b.flac']);
    await pumpEventQueue();
    expect(handler.queue.value, isNotEmpty);

    await queue.clear();
    await pumpEventQueue();

    expect(handler.queue.value, isEmpty);
  });

  test('extras carry the trackId so play tracking can record', () async {
    await queue.setQueue(['/a.flac']);
    await pumpEventQueue();
    // The injected fake gives /a.flac no trackId; give a second track one and
    // confirm it survives the mapping into the now-playing item.
    queue = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/unused/test.db', saveQueue: (_) async {});
    final h2 = OlivierAudioHandler();
    final p2 = PlaybackController(
      audioHandler: h2,
      queueController: queue,
      dbPath: '/unused/test.db',
      tracksForPathsFn: (paths) async => [track(paths.first, id: 99)],
    );
    addTearDown(p2.dispose);

    await queue.setQueue(['/x.flac']);
    await pumpEventQueue();

    expect(h2.mediaItem.value?.extras?['trackId'], 99);
  });
}

// Coverage note: this drives the real revision -> _syncNowPlayingFromQueue ->
// queue/mediaItem path with a real OlivierAudioHandler, proving the wiring that
// was broken now works (queue + mediaItem get populated on every queue change).
//
// What it does NOT cover host-VM:
//  - Index-following: _syncNowPlayingFromQueue reads `audioHandler.player`'s
//    currentIndex. In production that real media_kit AudioPlayer IS the player
//    QueueController wraps, but it can't load sources or advance its index
//    headless (no media_kit channel) — it reads null -> clamps to 0. So these
//    tests assert the index-0 case; the "emit the item at the player's actual
//    index N" branch is verified by reading the code + the manual run.
//  - _enrichWithCoverArt FFI (getApplicationCacheDirectory + extractCover),
//    which needs platform channels (its failure is swallowed here).
