import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/cover_providers.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

QueueTrack _track(String path, String title) => QueueTrack(
    path: path,
    title: title,
    album: '',
    titleTranslit: null,
    titleTranslate: null);

void main() {
  testWidgets('expanded queue shows a resize handle and persists on drag',
      (tester) async {
    final saved = <String, String>{};

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
        setSettingFnProvider.overrideWithValue((k, v) async => saved[k] = v),
        coverForPathFnProvider.overrideWithValue((_) async => null),
        queueControllerProvider.overrideWithValue(qc),
        shuffleAllTargetProvider.overrideWithValue(qc),
        queueProvider.overrideWith(() => _FakeQueue(QueueView(
              tracks: [_track('/m/a.flac', 'A'), _track('/m/b.flac', 'B')],
              currentIndex: 0,
              shuffled: false,
            ))),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Expand queue'));
    await tester.pump();
    await tester.pump();

    final handle = find.byKey(const ValueKey('queue-resize-handle'));
    expect(handle, findsOneWidget);

    await tester.drag(handle, const Offset(0, -50));
    await tester.pump();

    expect(saved.containsKey('layout.queue_height'), isTrue,
        reason: 'releasing the resize handle should persist the height');
    expect(tester.takeException(), isNull);
  });
}

class _FakeQueue extends QueueNotifier {
  _FakeQueue(this._view);
  final QueueView _view;
  @override
  Future<QueueView> build() async => _view;
}
