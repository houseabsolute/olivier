// Adaptation note: The plan's verbatim test called RustLib.init() in setUpAll
// and constructed QueueController.withPlayer without saveQueue (which would hit
// real Rust FFI to persist). Both are skipped here:
//   - RustLib.init() / frb_generated.dart import removed (QueueTrack is a plain
//     Dart class; no FFI needed for these assertions).
//   - saveQueue: (_) async {} added to suppress FFI persistence calls.
// The test logic is otherwise unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import '../support/fake_queue_player.dart';

QueueTrack _qt(String p) =>
    QueueTrack(path: p, title: p, album: '', addedAt: 0);

void main() {
  testWidgets('header Shuffle toggle calls setShuffle and shows active state',
      (tester) async {
    final player = FakeQueuePlayer();
    final controller = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await controller.setQueue(['/a.flac', '/b.flac']);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          getSettingFnProvider.overrideWithValue((key) async => null),
          queueControllerProvider.overrideWithValue(controller),
          tracksForPathsFnProvider.overrideWithValue(
            (paths) async => [for (final p in paths) _qt(p)],
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: QueuePanel())),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.shuffled, isFalse);

    await tester.tap(find.byTooltip('Shuffle'));
    await tester.pumpAndSettle();

    expect(controller.shuffled, isTrue);
    expect(
      find.byWidgetPredicate((w) => w is IconButton && w.isSelected == true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
