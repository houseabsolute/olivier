import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/main.dart';

import 'support/fake_queue_player.dart';

void main() {
  test('quitWithFlush saves the playhead before exiting', () async {
    final events = <String>[];
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (_) async => events.add('saved'));
    await queue.append(['/a.flac']);
    player.setCurrentIndex(0);
    events.clear(); // drop the append()'s own persist

    await quitWithFlush(queue, exit: () => events.add('exited'));

    expect(events, ['saved', 'exited']);
  });
}
