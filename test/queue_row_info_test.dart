import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/widgets/context_menu.dart';

import 'support/fake_queue_player.dart';

QueueTrack _track(String path, String title) => QueueTrack(
      path: path,
      title: title,
      album: '',
      addedAt: 0,
      lastPlayed: null,
      titleTranslit: null,
      titleTranslate: null,
    );

class _FakeQueue extends QueueNotifier {
  _FakeQueue(this._view);
  final QueueView _view;
  @override
  Future<QueueView> build() async => _view;
}

void main() {
  testWidgets('expanded queue rows are wrapped in RowContextMenu',
      (tester) async {
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await qc.append(['/m/a.flac', '/m/b.flac']);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((_) async => null),
        queueControllerProvider.overrideWithValue(qc),
        queueProvider.overrideWith(
          () => _FakeQueue(QueueView(
            tracks: [_track('/m/a.flac', 'A'), _track('/m/b.flac', 'B')],
            currentIndex: 0,
            shuffled: false,
          )),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    ));
    await tester.pump();
    await tester.pump();

    // Expand the queue
    await tester.tap(find.byTooltip('Expand queue'));
    await tester.pump();
    await tester.pump();

    // Each visible queue row must be wrapped in a RowContextMenu
    expect(find.byType(RowContextMenu), findsWidgets);
  });
}
