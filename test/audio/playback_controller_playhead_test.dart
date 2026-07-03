import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/src/rust/db.dart';

import '../support/fake_queue_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  QueueTrack track(String path) => QueueTrack(
        path: path,
        title: 'Title $path',
        album: 'Album $path',
        addedAt: 0,
      );

  late OlivierAudioHandler handler;
  late FakeQueuePlayer player;
  late QueueController queue;
  late PlaybackController playback;
  QueueSnapshot? saved;

  setUp(() async {
    handler = OlivierAudioHandler();
    player = FakeQueuePlayer();
    saved = null;
    queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);
    playback = PlaybackController(
      audioHandler: handler,
      queueController: queue,
      dbPath: ':memory:',
      tracksForPathsFn: (paths) async => [for (final p in paths) track(p)],
    );
    await queue.append(['/a.flac', '/b.flac']);
    player.setCurrentIndex(1);
    player.positionValue = const Duration(seconds: 10);
    saved = null; // drop the append()'s own persist
  });

  tearDown(() => playback.dispose());

  test('pausing persists the playhead', () {
    playback.onPlayingChanged(false);
    expect(saved, isNotNull);
    expect(saved!.currentIndex, 1);
    expect(saved!.positionMs.toInt(), 10000);
  });

  test('starting playback does NOT persist', () {
    playback.onPlayingChanged(true);
    expect(saved, isNull);
  });

  test('advancing to a new track persists the playhead', () {
    playback.onTrackChanged(1);
    expect(saved, isNotNull);
    expect(saved!.currentIndex, 1);
  });

  test('a transient null index does NOT persist (anti-clobber)', () {
    playback.onTrackChanged(1); // establish a tracked index first
    saved = null;
    playback.onTrackChanged(null); // transient null must not overwrite
    expect(saved, isNull);
  });
}
