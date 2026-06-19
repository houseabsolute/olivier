import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

QueueTrack _qt(String path, String title) => QueueTrack(
      path: path,
      title: title,
      album: 'Album',
      addedAt: 0,
    );

void main() {
  test('queueProvider resolves appended paths into a QueueView', () async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );

    final container = ProviderContainer(
      overrides: [
        queueControllerProvider.overrideWithValue(qc),
        tracksForPathsFnProvider.overrideWithValue(
          (paths) async => [for (final p in paths) _qt(p, 'T:$p')],
        ),
      ],
    );
    addTearDown(container.dispose);

    // Empty queue → empty view.
    final initial = await container.read(queueProvider.future);
    expect(initial.tracks, isEmpty);
    expect(initial.currentIndex, isNull);

    // Append, then the next read of the (invalidated) provider reflects it.
    await qc.append(['/m/a.flac', '/m/b.flac']);
    final after = await container.read(queueProvider.future);
    expect(
        after.tracks.map((t) => t.path).toList(), ['/m/a.flac', '/m/b.flac']);
    expect(after.currentIndex, 0);
    expect(after.shuffled, isFalse);
  });
}
