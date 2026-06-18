import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

const _tracks = [
  QueueTrack(
    path: '/a.flac',
    title: '歌舞伎町の女王',
    album: '無罪モラトリアム',
    titleTranslit: 'Kabukicho no Joo',
    titleTranslate: 'Queen of Kabuki-cho',
  ),
  QueueTrack(
    path: '/b.flac',
    title: 'Innocence',
    album: '無罪モラトリアム',
  ),
];

class _StubQueueNotifier extends QueueNotifier {
  _StubQueueNotifier(this._value);
  final QueueView _value;
  @override
  Future<QueueView> build() async => _value;
}

// A real controller seeded so its canonical order + player sources line up
// with the displayed stub _tracks (index 0 == '/a.flac', index 1 == '/b.flac').
// Adaptation: saveQueue is a no-op to avoid the Rust FFI (no cdylib in plain
// `flutter test`); dbPath is still ':memory:' for clarity but is not used.
Future<({QueueController qc, FakeQueuePlayer player})>
    _seededController() async {
  final player = FakeQueuePlayer();
  final qc = QueueController.withPlayer(
    player,
    dbPath: ':memory:',
    saveQueue: (_) async {},
  );
  await qc.append([for (final t in _tracks) t.path]);
  return (qc: qc, player: player);
}

Widget _app(QueueController qc) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      queueControllerProvider.overrideWithValue(qc),
      queueProvider.overrideWith(
        () => _StubQueueNotifier(
          const QueueView(tracks: _tracks, currentIndex: 0, shuffled: false),
        ),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(body: QueuePanel()),
    ),
  );
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Expand queue'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('expanded panel renders a bilingual row per queued track',
      (tester) async {
    final c = await _seededController();
    await tester.pumpWidget(_app(c.qc));
    await tester.pumpAndSettle();
    await _expand(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Kabukicho no Joo · Queen of Kabuki-cho'), findsOneWidget);
    expect(find.text('Innocence'), findsOneWidget);
  });

  testWidgets('× removes that entry from the queue', (tester) async {
    final c = await _seededController();
    await tester.pumpWidget(_app(c.qc));
    await tester.pumpAndSettle();
    await _expand(tester);

    await tester.tap(find.byTooltip('Remove from queue').first);
    await tester.pumpAndSettle();

    // removeAt(0) dropped the first canonical path and issued a player remove.
    expect(c.qc.orderedPaths, ['/b.flac']);
    expect(c.player.removedIndexes, [0]);
  });

  testWidgets('tapping a row jumps to and plays it', (tester) async {
    final c = await _seededController();
    await tester.pumpWidget(_app(c.qc));
    await tester.pumpAndSettle();
    await _expand(tester);

    await tester.tap(find.text('Innocence'));
    await tester.pumpAndSettle();

    // playAt(1) seeked to player index 1 (not shuffled) and started playback.
    expect(c.player.seeks.single.index, 1);
    expect(c.player.played, isTrue);
  });

  testWidgets('Empty clears the queue', (tester) async {
    final c = await _seededController();
    await tester.pumpWidget(_app(c.qc));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Empty queue'));
    await tester.pumpAndSettle();

    // clear() emptied the canonical order and the player sources.
    expect(c.qc.orderedPaths, isEmpty);
    expect(c.player.sources, isEmpty);
  });

  test('reorder index normalization (downward move drops one slot)', () {
    expect(normalizeReorder(0, 3), 2); // move item 0 to bottom of 3-item list
    expect(normalizeReorder(2, 0), 0); // upward move is unchanged
  });

  // Regression: when QueuePanel is mounted as a non-flexed trailing child of a
  // Column (as in BrowserPage), the parent Column gives it unbounded height.
  // The old implementation used Expanded(child: ReorderableListView) inside its
  // own Column, which is illegal under an unbounded main-axis constraint and
  // caused "RenderFlex children have non-zero flex but incoming height
  // constraints are unbounded". This test reproduces that exact constraint.
  testWidgets(
      'expanding panel under unbounded-height parent does not throw '
      'and renders track rows', (tester) async {
    final c = await _seededController();
    // Mirror browser_page.dart's body Column: an Expanded child first (gives
    // the remaining space to the split view), then a bare QueuePanel that gets
    // BoxConstraints(0<=h<=Infinity) — the previously-crashing layout.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          getSettingFnProvider.overrideWithValue((key) async => null),
          queueControllerProvider.overrideWithValue(c.qc),
          queueProvider.overrideWith(
            () => _StubQueueNotifier(
              const QueueView(
                tracks: _tracks,
                currentIndex: 0,
                shuffled: false,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: SizedBox()),
                QueuePanel(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expand(tester);

    expect(tester.takeException(), isNull);
    // The expanded list rows must be present.
    expect(find.text('Kabukicho no Joo · Queen of Kabuki-cho'), findsOneWidget);
    expect(find.text('Innocence'), findsOneWidget);
    // × remove buttons must be present.
    expect(find.byTooltip('Remove from queue'), findsWidgets);
  });
}
