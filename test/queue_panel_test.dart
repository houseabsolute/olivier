import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    addedAt: 0,
    titleTranslit: 'Kabukicho no Joo',
    titleTranslate: 'Queen of Kabuki-cho',
  ),
  QueueTrack(
    path: '/b.flac',
    title: 'Innocence',
    album: '無罪モラトリアム',
    addedAt: 0,
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

  // Spec §7: the currently-playing row is visually distinguished with a
  // primaryContainer-colored Material. The stub QueueView has currentIndex == 0,
  // so the first row must carry the highlight and the second row must not.
  testWidgets('current-track row has primaryContainer highlight, others do not',
      (tester) async {
    final c = await _seededController();
    await tester.pumpWidget(_app(c.qc));
    await tester.pumpAndSettle();
    await _expand(tester);

    // Locate the Material widget that wraps each row in the expanded list.
    // Each item is keyed by '${path}#${index}'; the widget builder wraps it in
    // a Material whose `color` is set to primaryContainer for the current row.
    final theme = Theme.of(
      tester.element(find.text('Kabukicho no Joo · Queen of Kabuki-cho')),
    );
    final highlightColor = theme.colorScheme.primaryContainer;

    // Find all Material widgets that are direct wrappers of list items.
    // The highlighted row's Material must have `color == primaryContainer`.
    // We inspect by finding the Text for each row, then climbing to its Material.
    final highlightedRowFinder = find.ancestor(
      of: find.text('Kabukicho no Joo · Queen of Kabuki-cho'),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.color == highlightColor,
      ),
    );
    final unhighlightedRowFinder = find.ancestor(
      of: find.text('Innocence'),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.color == highlightColor,
      ),
    );

    expect(highlightedRowFinder, findsWidgets,
        reason: 'index-0 row must have primaryContainer Material');
    expect(unhighlightedRowFinder, findsNothing,
        reason: 'non-current row must NOT have primaryContainer Material');
  });

  // When the queue is expanded, BrowserPage wraps QueuePanel in Expanded so it
  // fills all available vertical space. This test reproduces that bounded layout
  // to confirm the panel renders its track rows without throwing.
  testWidgets(
      'expanding panel under bounded-height parent does not throw '
      'and renders track rows', (tester) async {
    final c = await _seededController();
    // Mirror browser_page.dart's expanded layout: QueuePanel inside Expanded.
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
                Expanded(child: QueuePanel()),
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

  testWidgets(
      'expanded panel shows a column header and artist/album in their own '
      'columns (not a joined subtitle)', (tester) async {
    const tracks = [
      QueueTrack(
        path: '/a.flac',
        title: 'Kabukicho',
        artist: '椎名林檎',
        album: '無罪モラトリアム',
        addedAt: 0,
      ),
    ];
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await qc.append([for (final t in tracks) t.path]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          getSettingFnProvider.overrideWithValue((key) async => null),
          queueControllerProvider.overrideWithValue(qc),
          queueProvider.overrideWith(
            () => _StubQueueNotifier(
              const QueueView(
                tracks: tracks,
                currentIndex: 0,
                shuffled: false,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: QueuePanel())),
      ),
    );
    await tester.pumpAndSettle();
    await _expand(tester);

    expect(tester.takeException(), isNull);
    // Column header labels are present above the rows.
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    // Artist and album each render as their own cell...
    expect(find.text('椎名林檎'), findsOneWidget);
    expect(find.text('無罪モラトリアム'), findsOneWidget);
    // ...and are NOT combined into the old "Artist — Album" subtitle.
    expect(find.text('椎名林檎 — 無罪モラトリアム'), findsNothing);
  });

  testWidgets(
      'narrow expanded queue drops the meta columns instead of overflowing',
      (tester) async {
    // Between the now-playing header's minimum width and the 560px meta
    // threshold: wide enough that the always-visible header bar fits, narrow
    // enough that the row's Length/Added/Played columns must drop out.
    await tester.binding.setSurfaceSize(const Size(540, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const tracks = [
      QueueTrack(
        path: '/a.flac',
        title: 'Kabukicho',
        artist: '椎名林檎',
        album: '無罪モラトリアム',
        addedAt: 0,
      ),
    ];
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await qc.append([for (final t in tracks) t.path]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          getSettingFnProvider.overrideWithValue((key) async => null),
          queueControllerProvider.overrideWithValue(qc),
          queueProvider.overrideWith(
            () => _StubQueueNotifier(
              const QueueView(
                tracks: tracks,
                currentIndex: 0,
                shuffled: false,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: QueuePanel())),
      ),
    );
    await tester.pumpAndSettle();
    await _expand(tester);

    // No RenderFlex overflow at a narrow panel width.
    expect(tester.takeException(), isNull);
    // The Length/Added/Played meta columns drop out below the threshold...
    expect(find.text('Length'), findsNothing);
    // ...but the title and the new artist/album columns stay.
    expect(find.text('椎名林檎'), findsOneWidget);
    expect(find.text('無罪モラトリアム'), findsOneWidget);
  });

  testWidgets(
      'collapsed header does not overflow at a narrow width and keeps its '
      'controls', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // _app seeds currentIndex 0 over the 2-track stub, so the header has a
    // now-playing track (cover candidate) and an up-next entry — the exact
    // shape that previously overflowed when narrow.
    final c = await _seededController();
    await tester.pumpWidget(_app(c.qc));
    await tester.pumpAndSettle();

    // Collapsed (not expanded): the now-playing header bar must not overflow.
    expect(tester.takeException(), isNull);
    // All controls stay reachable even though the thumbnail is dropped.
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(find.byTooltip('Shuffle entire library'), findsOneWidget);
    expect(find.byTooltip('Empty queue'), findsOneWidget);
    expect(find.byTooltip('Expand queue'), findsOneWidget);
  });

  testWidgets(
      'collapsed header shows the full track count (no ellipsis) when there '
      'is room, even with an up-next', (tester) async {
    // 700px is above the compact threshold, so the count must render in full.
    // Regression guard: when the count flexed equally against the up-next cell,
    // the up-next stole half the slack and ellipsized the count at this width.
    await tester.binding.setSurfaceSize(const Size(700, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final c = await _seededController();
    await tester.pumpWidget(_app(c.qc));
    await tester.pumpAndSettle();

    final count = tester.renderObject<RenderParagraph>(
      find.text('Queue · 2 tracks'),
    );
    expect(count.didExceedMaxLines, isFalse);
  });

  testWidgets('collapsed header with no up-next does not overflow when narrow',
      (tester) async {
    // A single-track queue at currentIndex 0 has a now-playing track but no
    // up-next, exercising the `else Spacer()` branch at a narrow width.
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const tracks = [
      QueueTrack(path: '/solo.flac', title: 'Solo', album: 'X', addedAt: 0),
    ];
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await qc.append([for (final t in tracks) t.path]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          getSettingFnProvider.overrideWithValue((key) async => null),
          queueControllerProvider.overrideWithValue(qc),
          queueProvider.overrideWith(
            () => _StubQueueNotifier(
              const QueueView(
                tracks: tracks,
                currentIndex: 0,
                shuffled: false,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: QueuePanel())),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Expand queue'), findsOneWidget);
  });
}
