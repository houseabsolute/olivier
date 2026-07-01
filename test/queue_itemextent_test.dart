import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

final _tracks = [
  for (var i = 0; i < 8; i++)
    QueueTrack(path: '/$i.flac', title: 'Track $i', album: 'X', addedAt: 0),
];

class _StubQueueNotifier extends QueueNotifier {
  _StubQueueNotifier(this._value);
  final QueueView _value;
  @override
  Future<QueueView> build() async => _value;
}

Future<QueueController> _seededController() async {
  final qc = QueueController.withPlayer(
    FakeQueuePlayer(),
    dbPath: ':memory:',
    saveQueue: (_) async {},
  );
  await qc.append([for (final t in _tracks) t.path]);
  return qc;
}

Widget _app(QueueController qc) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      queueControllerProvider.overrideWithValue(qc),
      queueProvider.overrideWith(
        () => _StubQueueNotifier(
          QueueView(tracks: _tracks, currentIndex: 0, shuffled: false),
        ),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  );
}

void main() {
  testWidgets('expanded queue list sets a fixed itemExtent (O(1) scroll perf)',
      (tester) async {
    final qc = await _seededController();
    await tester.pumpWidget(_app(qc));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand queue'));
    await tester.pumpAndSettle();

    final list =
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    // Without a fixed extent, flinging to the bottom of a huge shuffle-all queue
    // forces every row to be laid out to resolve the scroll offset → UI hang.
    expect(
      list.itemExtent,
      isNotNull,
      reason: 'the expanded queue list must set a fixed itemExtent',
    );
    expect(list.itemExtent, greaterThan(0));
  });
}
