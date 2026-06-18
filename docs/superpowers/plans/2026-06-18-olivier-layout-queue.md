# Layout Redesign + Play Queue — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three equal browse columns with a wide Artist column beside a stacked Albums/Tracks pane, and route all playback through one explicit, user-managed play queue that is the single source of truth.

**Architecture:** Layout "C" — a 2-area `MultiSplitView` (wide Artist | right `Column[Albums / Tracks]`) with a collapsible queue panel between the split and the unchanged now-playing bar. The queue is source-of-truth: it is built by **appending** (double-click / drag / right-click "Add to queue") with exactly one queue-replacing action ("Shuffle entire library"); browse clicks only *select*. `QueueController` mutates a canonical `_orderedPaths` and mirrors each change to the just_audio player via incremental, playback-preserving source ops, bumping a `revision` `ValueNotifier`; `queueProvider` resolves the canonical order to bilingual `QueueTrack`s for the panel; new FFI queries supply artist/track/library paths. DB persistence (`queue_item`/`playback_state` via `save_queue`/`load_queue`) is unchanged — each mutator just calls the existing `_persist()`.

**Tech Stack:** Flutter + Riverpod + just_audio 0.10.5 + flutter_rust_bridge + rusqlite

## Implementation decisions (authoritative — override any task step that conflicts)

1. `queueControllerProvider` is `Provider<QueueController>` (concrete) for the entire plan. Do **not** introduce a `QueueOps` interface; panels/menus call `QueueController` methods (`append`/`removeAt`/`reorder`/`clear`/`playAt`) directly through it.
2. `FakeQueuePlayer` (implements the `QueuePlayer` port from Task 5) is declared once in `test/support/fake_queue_player.dart` and imported by every test that needs a headless player. No per-test re-declarations.

---

## File Structure

**Rust**
- `rust/src/catalog/query.rs` (modify) — add `track_path`, `track_paths_for_artist`, `track_paths_for_library` queries (one `MIN(path)` per track).
- `rust/src/api/catalog.rs` (modify) — add FFI wrappers `track_path`, `track_paths_for_artist`, `track_paths_for_library` (each `query::fn(&db::open(&db_path)?, …)`).
- `rust/tests/catalog_test.rs` (modify) — seeded `:memory:` tests for the three new queries.
- `rust/src/frb_generated.rs` (regenerated, commit) — bridge for the three new FFI fns.

**Bridge (generated, commit)**
- `lib/src/rust/api/catalog.dart` + other `lib/src/rust/**` (regenerated) — `trackPath`, `trackPathsForArtist`, `trackPathsForLibrary` Dart bindings.

**Flutter — audio/state**
- `lib/audio/queue_controller.dart` (modify) — add `append`/`removeAt`/`reorder`/`clear`/`playAt`/`replaceLibraryShuffled`, `revision` notifier, `currentCanonicalIndex` getter, `SaveQueueFn` persistence seam, `ShuffleAllTarget` interface; shuffle/duplicate-aware index translation.
- `lib/audio/queue_player.dart` (create) — narrow `QueuePlayer` port + `JustAudioQueuePlayer` adapter so queue logic is unit-testable headless.
- `lib/audio/queue_entity.dart` (create) — `QueueEntityRef` sealed type + `EntityPathFns` + `resolveEntityPaths` shared by menu/double-click/drag.
- `lib/state/queue_provider.dart` (create) — `QueueView` + `QueueNotifier` + `queueProvider` (canonical-order resolution via `tracksForPathsFnProvider`).
- `lib/state/providers.dart` (modify) — add `selectedTrackProvider`, clear track on album change, and FFI seams (`trackPathFnProvider`, `albumFilePathsFnProvider`, `entityPathFnsProvider`, `libraryPathsFnProvider`).

**Flutter — UI**
- `lib/catalog/browser_page.dart` (modify) — 2-pane split + `_RightPane` stack + injectable now-playing bar + mount `QueuePanel`.
- `lib/catalog/queue_panel.dart` (create) — collapsed header (count + up-next) → expanded `ReorderableListView` with reorder/remove/tap-to-play/highlight + Shuffle/Empty/Shuffle-all controls + `QueuePanelDropTarget`.
- `lib/catalog/album_column.dart` (modify) — remove play `IconButton`; add double-click-append + context menu + draggable.
- `lib/catalog/track_column.dart` (modify) — single-click selects, double-click appends; add context menu + draggable.
- `lib/catalog/artist_column.dart` (modify) — double-click appends + context menu + draggable.
- `lib/widgets/context_menu.dart` (create) — reusable right-click `AddToQueueMenu`.
- `lib/audio/playback_controller.dart` (modify) — add `queueControllerProvider` (concrete `Provider<QueueController>`).

**Tests**
- `test/queue_panel_shell_test.dart`, `test/browser_page_layout_test.dart` (Slice 1)
- `test/queue_controller_test.dart`, `test/selected_track_provider_test.dart`, `test/queue_provider_test.dart`, `test/track_column_select_test.dart`, `test/album_column_enqueue_test.dart`, `test/queue_panel_header_test.dart` (Slice 2)
- `test/queue_controller_ops_test.dart`, `test/queue_panel_test.dart` (Slice 3)
- `test/queue_entity_test.dart`, `test/context_menu_test.dart`, `test/queue_drag_test.dart`, `test/shuffle_library_test.dart` (Slice 4)
- `test/support/fake_queue_player.dart`, `test/audio/queue_controller_shuffle_test.dart`, `test/state/queue_provider_shuffle_test.dart`, `test/widgets/queue_panel_shuffle_test.dart` (Slice 5)

> **Reconciliation note (applies throughout):** The locked contracts mandate the narrow `QueuePlayer` port (`lib/audio/queue_player.dart`) as the player seam, and `QueueController.withPlayer(QueuePlayer, …)` as the test constructor. **All tests** inject via `QueueController.withPlayer(FakeQueuePlayer(), …)`, where `FakeQueuePlayer implements QueuePlayer` is declared **once** in the shared support file `test/support/fake_queue_player.dart` (created in Task 5) and imported wherever a headless player is needed — there are no per-test re-declared fakes. The controller references `_player` (not a public `player` field), and the production constructor `QueueController(AudioPlayer, …)` wraps the real player in `JustAudioQueuePlayer`. Where a slice-5 task references `controller.player`, use the `currentCanonicalIndex` getter on `QueueController` instead (the contract names it). External Rust test imports use `use rust_lib_olivier::catalog::query::{…}` (not `crate::`).

---

## Slice 1 — Layout redesign (pure Flutter)

This slice restructures `BrowserPage` into a 2-pane split (wide Artist column beside a right pane that stacks Albums over Tracks), inserts a **collapsed-only** queue-panel shell between the split and the now-playing bar, and makes the now-playing bar injectable so the layout is widget-testable headless. No FFI, no behavior change to album/track clicks (those are Slice 2). The album play `IconButton` removal is owned by Slice 2, so it is **not** touched here.

**Decisions not pinned by CONTRACTS (stated inline):**
- **NowPlayingBar placement:** keep it as `bottomNavigationBar`; put `Column[Expanded(MultiSplitView), QueuePanel()]` in `body`. `bottomNavigationBar` already pins the bar above system insets (verified-working); the spec's diagram shows the queue panel *above* the bar, which this satisfies exactly.
- **NowPlayingBar injection:** `BrowserPage` gains an optional `nowPlaying` widget param defaulting to the real `NowPlayingBar(audioHandler: audioHandler)`. Minimal change to let a headless test render the page without the uninitialized `late` global `audioHandler`.
- **Right pane split:** Artist area `flex: 1, min: 220`; right area `flex: 2, min: 320` (≈33%/67%). The inner `_RightPane` uses `Expanded(AlbumColumn) / Divider(height:1) / Expanded(TrackColumn)` (50/50).
- **QueuePanel (this slice):** a stateless, data-free collapsed shell — header `Text('Queue · 0')`, an expand caret, and disabled Shuffle / Empty / Shuffle-all controls (`onPressed: null`). Real data/wiring is Slice 2.

### Task 1: Make NowPlayingBar injectable into BrowserPage

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/catalog/browser_page.dart`

This is a prerequisite enabling the later layout test to render `BrowserPage` headless. It is a no-op for production (default keeps the real bar).

- [ ] **Step 1: Add an optional `nowPlaying` field to `BrowserPage`.** In `/home/autarch/projects/olivier/lib/catalog/browser_page.dart`, change:

```dart
class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key});

  @override
  ConsumerState<BrowserPage> createState() => _BrowserPageState();
}
```

to:

```dart
class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key, this.nowPlaying});

  /// The bottom transport bar. Injectable so the page can be widget-tested
  /// without the live, uninitialized global [audioHandler]. Defaults to the
  /// real [NowPlayingBar] in production.
  final Widget? nowPlaying;

  @override
  ConsumerState<BrowserPage> createState() => _BrowserPageState();
}
```

- [ ] **Step 2: Use the injected bar (or the real default) for `bottomNavigationBar`.** In `build`, change:

```dart
      bottomNavigationBar: NowPlayingBar(audioHandler: audioHandler),
```

to:

```dart
      bottomNavigationBar:
          widget.nowPlaying ?? NowPlayingBar(audioHandler: audioHandler),
```

- [ ] **Step 3: Confirm it still compiles/analyzes (no test yet — pure refactor).** Run:

```
cd /home/autarch/projects/olivier && mise exec -- dart analyze lib/catalog/browser_page.dart
```

Expect: `No issues found!`. (The `audioHandler` import is still used by the default branch, so no unused-import warning.)

---

### Task 2: Create the collapsed QueuePanel shell

**Files:**
- Create: `/home/autarch/projects/olivier/lib/catalog/queue_panel.dart`
- Test: `/home/autarch/projects/olivier/test/queue_panel_shell_test.dart`

- [ ] **Step 1: Write the failing test first.** Create `/home/autarch/projects/olivier/test/queue_panel_shell_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/queue_panel.dart';

void main() {
  testWidgets('QueuePanel collapsed shell renders header + disabled controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 600, child: QueuePanel()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Header label with the (placeholder) count.
    expect(find.text('Queue · 0'), findsOneWidget);
    // The three header controls + the expand caret are present.
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(find.byTooltip('Empty queue'), findsOneWidget);
    expect(find.byTooltip('Shuffle entire library'), findsOneWidget);
    expect(find.byTooltip('Expand queue'), findsOneWidget);

    // Everything is disabled in this slice (no data/wiring yet).
    final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
    expect(buttons, isNotEmpty);
    for (final b in buttons) {
      expect(b.onPressed, isNull);
    }
  });
}
```

- [ ] **Step 2: Run it — expect a compile failure (the file does not exist yet).** Run:

```
cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_panel_shell_test.dart
```

Expect failure: `Target of URI doesn't exist: 'package:olivier/catalog/queue_panel.dart'` — the test cannot compile because `QueuePanel` does not exist yet.

- [ ] **Step 3: Implement the collapsed shell.** Create `/home/autarch/projects/olivier/lib/catalog/queue_panel.dart`:

```dart
import 'package:flutter/material.dart';

/// Collapsed-only queue panel shell.
///
/// This slice renders the static header (label + disabled controls + expand
/// caret) only; the live count, expansion, and the Shuffle/Empty/Shuffle-all
/// actions are wired in later slices. All controls are intentionally disabled
/// (`onPressed: null`) until then.
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            // Placeholder count — real count arrives with the queue view.
            Text('Queue · 0', style: theme.textTheme.titleSmall),
            const Spacer(),
            const IconButton(
              icon: Icon(Icons.shuffle),
              tooltip: 'Shuffle',
              onPressed: null,
            ),
            const IconButton(
              icon: Icon(Icons.delete_outline),
              tooltip: 'Empty queue',
              onPressed: null,
            ),
            const IconButton(
              icon: Icon(Icons.shuffle_on_outlined),
              tooltip: 'Shuffle entire library',
              onPressed: null,
            ),
            const IconButton(
              icon: Icon(Icons.expand_less),
              tooltip: 'Expand queue',
              onPressed: null,
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run it — expect pass.** Run:

```
cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_panel_shell_test.dart
```

Expect: `All tests passed!`.

- [ ] **Step 5: Commit.**

```
cd /home/autarch/projects/olivier && git add lib/catalog/queue_panel.dart test/queue_panel_shell_test.dart lib/catalog/browser_page.dart && git commit -m "Add collapsed QueuePanel shell + make NowPlayingBar injectable

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Restructure BrowserPage into 2-pane + stacked right pane + queue panel

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/catalog/browser_page.dart`
- Test: `/home/autarch/projects/olivier/test/browser_page_layout_test.dart`

- [ ] **Step 1: Write the failing layout test first.** Create `/home/autarch/projects/olivier/test/browser_page_layout_test.dart`. It overrides every provider `BrowserPage`'s build path reads (data providers + the `language_leads` setting seam + a stub `scanControllerProvider` whose `loadRoots()` is a no-op so the post-frame callback never hits FFI) and injects a stub now-playing bar so the uninitialized global `audioHandler` is never touched. Modeled on `test/catalog_text_scale_test.dart`.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/browser_page.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';

const _artist = Artist(
  mbid: 'a1',
  name: 'Ringo Sheena',
  sortName: 'Sheena, Ringo',
  transliteration: 'Ringo Sheena',
  nameOriginal: '椎名林檎',
);

const _album = Album(
  releaseMbid: 'r1',
  title: '無罪モラトリアム',
  albumArtist: '椎名林檎',
  originalYear: '1999',
  titleTranslit: 'Muzai Moratorium',
  titleTranslate: 'Innocence Moratorium',
);

final _track = Track(
  id: 1,
  disc: 1,
  position: 1,
  title: '歌舞伎町の女王',
  addedAt: 0,
  lengthMs: BigInt.from(258000),
  titleTranslit: 'Kabukicho no Joo',
  titleTranslate: 'Queen of Kabuki-cho',
);

/// A [ScanController] whose [loadRoots] is a no-op, so the page's post-frame
/// hydrate never reaches the real `listRoots` FFI in a headless test.
class _StubScanController extends ScanController {
  @override
  ScanState build() => const ScanState();

  @override
  Future<void> loadRoots() async {}
}

Widget _page(double scale) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      artistsProvider.overrideWith((ref) => [_artist]),
      albumsProvider.overrideWith((ref) => [_album]),
      tracksProvider.overrideWith((ref) => [_track]),
      // Pre-select so the album/track columns render content (not their
      // "Select an artist/album" placeholders).
      selectedArtistProvider
          .overrideWith(() => _PreselectedArtist(_artist.mbid)),
      selectedAlbumProvider
          .overrideWith(() => _PreselectedAlbum(_album.releaseMbid)),
      scanControllerProvider.overrideWith(_StubScanController.new),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          // Inject a trivial now-playing bar so the live global audioHandler
          // is never referenced.
          child: const BrowserPage(
            nowPlaying: SizedBox(height: 56, child: Text('stub-now-playing')),
          ),
        ),
      ),
    ),
  );
}

class _PreselectedArtist extends SelectedArtist {
  _PreselectedArtist(this._mbid);
  final String _mbid;
  @override
  String? build() => _mbid;
}

class _PreselectedAlbum extends SelectedAlbum {
  _PreselectedAlbum(this._mbid);
  final String _mbid;
  @override
  String? build() => _mbid;
}

void main() {
  for (final scale in const [1.0, 1.3]) {
    testWidgets(
        'BrowserPage renders 2-pane + stacked columns + queue panel '
        'without overflow at ${scale}x', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_page(scale));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // Left pane: artist. Right pane stacks album over track.
      expect(find.text('Ringo Sheena'), findsOneWidget);
      expect(find.text('無罪モラトリアム'), findsOneWidget);
      expect(find.text('歌舞伎町の女王'), findsOneWidget);

      // The stacked right pane separates album from track with a Divider.
      expect(find.byType(Divider), findsWidgets);

      // The collapsed queue-panel shell is present, above the now-playing bar.
      expect(find.text('Queue · 0'), findsOneWidget);
      expect(find.text('stub-now-playing'), findsOneWidget);
    });
  }
}
```

- [ ] **Step 2: Run it — expect failure.** Run:

```
cd /home/autarch/projects/olivier && mise exec -- flutter test test/browser_page_layout_test.dart
```

Expect failure: the test cannot yet find the queue panel — `Found 0 widgets with text "Queue · 0"`. (The current `BrowserPage` body is a bare `MultiSplitView` with 3 columns and no `QueuePanel`.)

- [ ] **Step 3: Import `QueuePanel` in `browser_page.dart`.** Add the import beside the other catalog imports in `/home/autarch/projects/olivier/lib/catalog/browser_page.dart`:

```dart
import 'package:olivier/catalog/queue_panel.dart';
```

- [ ] **Step 4: Replace the 3-area split controller with the 2-area split.** In `initState`, change:

```dart
    _splitController = MultiSplitViewController(
      areas: [
        Area(min: 160, builder: (ctx, area) => const ArtistColumn()),
        Area(min: 160, builder: (ctx, area) => const AlbumColumn()),
        Area(min: 240, builder: (ctx, area) => const TrackColumn()),
      ],
    );
```

to:

```dart
    _splitController = MultiSplitViewController(
      areas: [
        // Wide Artist column (≈ 33% default).
        Area(
          flex: 1,
          min: 220,
          builder: (ctx, area) => const ArtistColumn(),
        ),
        // Right pane (≈ 67% default): Albums stacked over Tracks.
        Area(
          flex: 2,
          min: 320,
          builder: (ctx, area) => const _RightPane(),
        ),
      ],
    );
```

- [ ] **Step 5: Wrap the split + queue panel in a `Column` body.** In `build`, change:

```dart
      body: MultiSplitView(controller: _splitController),
      bottomNavigationBar:
          widget.nowPlaying ?? NowPlayingBar(audioHandler: audioHandler),
```

to:

```dart
      body: Column(
        children: [
          Expanded(child: MultiSplitView(controller: _splitController)),
          // Collapsed queue-panel shell between the browse split and the
          // now-playing bar. Data/wiring arrive in later slices.
          const QueuePanel(),
        ],
      ),
      bottomNavigationBar:
          widget.nowPlaying ?? NowPlayingBar(audioHandler: audioHandler),
```

- [ ] **Step 6: Add the `_RightPane` widget** that stacks Albums over Tracks. Append this class at the end of `/home/autarch/projects/olivier/lib/catalog/browser_page.dart`, after the closing brace of `_BrowserPageState`:

```dart
/// The right pane of the browse split: the album list stacked over the track
/// list, separated by a hairline divider. Each list takes half the height.
class _RightPane extends StatelessWidget {
  const _RightPane();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Expanded(child: AlbumColumn()),
        Divider(height: 1),
        Expanded(child: TrackColumn()),
      ],
    );
  }
}
```

- [ ] **Step 7: Run the layout test — expect pass.** Run:

```
cd /home/autarch/projects/olivier && mise exec -- flutter test test/browser_page_layout_test.dart
```

Expect: `All tests passed!` (both the 1.0x and 1.3x cases).

- [ ] **Step 8: Run the existing column tests to confirm no regression** (the columns are unchanged, but they now live inside the new pane):

```
cd /home/autarch/projects/olivier && mise exec -- flutter test test/catalog_text_scale_test.dart
```

Expect: `All tests passed!`.

- [ ] **Step 9: Lint the whole change.** Run:

```
cd /home/autarch/projects/olivier && mise exec -- precious lint --all
```

Expect: clean (no clippy/dart-format/analyze findings). If `dart format` rewrites whitespace, re-stage the formatted files.

- [ ] **Step 10: Commit.**

```
cd /home/autarch/projects/olivier && git add lib/catalog/browser_page.dart test/browser_page_layout_test.dart && git commit -m "Restructure BrowserPage into 2-pane split with stacked right pane and queue panel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

**Slice 1 deliverable:** `BrowserPage` renders a wide resizable Artist column beside a right pane that stacks Albums over Tracks (separated by a divider), with a collapsed, disabled queue-panel shell ("Queue · 0" + Shuffle/Empty/Shuffle-all/expand controls) sitting between the split and the unchanged now-playing bar; a headless widget test proves the full layout renders without overflow at 1.0x and 1.3x text scale. Album/track click behavior is untouched (Slice 2 owns selection + the album play-button removal), and no Rust/FFI changed.

---

## Slice 2 — Queue model: append + selection + item 9

> **Test-strategy decision (not pinned by CONTRACTS):** `QueueController` holds a real just_audio `AudioPlayer` (media_kit backend, cannot run headless). To unit-test the path-list + persistence logic and to drive the column widget tests without an audio backend, this slice introduces the contract-mandated narrow `QueuePlayer` port (`addAudioSource` / `insertAudioSource` / `removeAudioSourceAt` / `moveAudioSource` / `setAudioSources` / `seek` / `play` / `currentIndex` / `position` / `currentIndexStream`) that the real `AudioPlayer` satisfies via `JustAudioQueuePlayer`, plus a `FakeQueuePlayer` for tests. `QueueController`'s production constructor still accepts an `AudioPlayer` (so `main.dart` is unchanged) by wrapping it in the adapter internally; `QueueController.withPlayer(QueuePlayer, …)` is the test seam.

> **Decision:** `queueProvider`/`QueueNotifier`/`QueueView` are added here; the **visual** queue panel body is Slice 3 — here `queue_panel.dart` is replaced with a collapsed header that reads `queueProvider`. The `QueueController` is exposed to Riverpod via a new `queueControllerProvider` (reading `playbackControllerProvider`).

### Task 4: Rust `track_path` FFI query + bridge

**Files:**
- Modify: `/home/autarch/projects/olivier/rust/src/catalog/query.rs`
- Modify: `/home/autarch/projects/olivier/rust/src/api/catalog.rs`
- Test: `/home/autarch/projects/olivier/rust/tests/catalog_test.rs`
- Modify (generated, commit): `/home/autarch/projects/olivier/lib/src/rust/api/catalog.dart`, `/home/autarch/projects/olivier/rust/src/frb_generated.rs` (+ any other regenerated `lib/src/rust/**`)

- [ ] **Step 1: Failing test first.** Add this test to `rust/tests/catalog_test.rs`. Add `track_path` to the existing `use rust_lib_olivier::catalog::query::{…}` import list at the top of the file.

```rust
#[test]
fn track_path_returns_min_path_or_none() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1, 'rel', 1, 1, 'T1')",
        [],
    )
    .unwrap();
    // Track 1 has two files (e.g. the same rip in two formats); track_path must
    // return exactly ONE path — the lexically-first (MIN) — so a double-click
    // enqueues a single entry, consistent with file_paths_for_album.
    for path in ["/m/a1.m4a", "/m/a1.flac"] {
        conn.execute(
            "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES (?1, 0, 0, 1, 0)",
            rusqlite::params![path],
        )
        .unwrap();
    }
    // A track with no files at all.
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2, 'rel', 1, 2, 'T2')",
        [],
    )
    .unwrap();

    assert_eq!(track_path(&conn, 1).unwrap(), Some("/m/a1.flac".to_string()));
    // No files → None (caller appends nothing).
    assert_eq!(track_path(&conn, 2).unwrap(), None);
    // Unknown track id → None.
    assert_eq!(track_path(&conn, 999).unwrap(), None);
}
```

- [ ] **Step 2: Run it — fails to compile.** Command: `cd /home/autarch/projects/olivier/rust && cargo test track_path_returns_min_path_or_none`. Expected failure: `cannot find function 'track_path' in module 'query'` / unresolved import — `track_path` does not exist yet.

- [ ] **Step 3: Implement the query.** Append to `rust/src/catalog/query.rs` (after `file_paths_for_album`). Since `track_id` is an `i64` (`Copy` scalar) it is taken by value.

```rust
/// The single play path for one track — `MIN(f.path)` so a track with several
/// files (same rip in two formats) yields exactly one entry, matching
/// `file_paths_for_album`. `None` when the track has no files or does not exist,
/// so a double-click on such a row enqueues nothing.
pub fn track_path(conn: &Connection, track_id: i64) -> anyhow::Result<Option<String>> {
    let path = conn
        .query_row(
            "SELECT MIN(f.path) FROM file f WHERE f.track_id = ?1",
            [track_id],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    Ok(path)
}
```

- [ ] **Step 4: Add the FFI wrapper.** Append to `rust/src/api/catalog.rs` (after `tracks_for_paths`):

```rust
pub fn track_path(db_path: String, track_id: i64) -> anyhow::Result<Option<String>> {
    query::track_path(&db::open(&db_path)?, track_id)
}
```

- [ ] **Step 5: Run it — passes.** Command: `cd /home/autarch/projects/olivier/rust && cargo test track_path_returns_min_path_or_none`. Expected: `test track_path_returns_min_path_or_none ... ok`.

- [ ] **Step 6: Regenerate the bridge** (an `api/catalog.rs` signature changed). Command: `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`. Verify a `trackPath({required String dbPath, required PlatformInt64 trackId}) -> Future<String?>` function appears in `lib/src/rust/api/catalog.dart`.

- [ ] **Step 7: Lint.** Command: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`. Expected: clean (clippy `-D warnings`, dart-format, analyze).

- [ ] **Step 8: Commit.** `cd /home/autarch/projects/olivier && git add rust/src/catalog/query.rs rust/src/api/catalog.rs rust/tests/catalog_test.rs rust/src/frb_generated.rs lib/src/rust && git commit -m "Add track_path FFI query (MIN path per track) for double-click enqueue"`

---

### Task 5: `QueuePlayer` port + `QueueController.append`/`clear`/`revision`

**Files:**
- Create: `/home/autarch/projects/olivier/lib/audio/queue_player.dart`
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart`
- Create: `/home/autarch/projects/olivier/test/support/fake_queue_player.dart` (the single, shared `FakeQueuePlayer` imported by every later test)
- Test: `/home/autarch/projects/olivier/test/queue_controller_test.dart`

- [ ] **Step 1: Create the player port + adapter.** Create `lib/audio/queue_player.dart`. This is the narrow seam `QueueController` mirrors to; the real `AudioPlayer` is wrapped by `JustAudioQueuePlayer`.

```dart
import 'package:just_audio/just_audio.dart';

/// Narrow port over the just_audio [AudioPlayer] operations the queue mutators
/// need. Exists so the queue logic (path bookkeeping + persistence + the
/// incremental, playback-preserving source ops) can be unit-tested without a
/// real media_kit backend, which cannot run headless.
abstract class QueuePlayer {
  Future<void> addAudioSource(AudioSource source);
  Future<void> insertAudioSource(int index, AudioSource source);
  Future<void> removeAudioSourceAt(int index);
  Future<void> moveAudioSource(int from, int to);
  Future<void> setAudioSources(
    List<AudioSource> sources, {
    int? initialIndex,
    Duration initialPosition,
  });
  Future<void> seek(Duration position, {int? index});
  Future<void> play();
  int? get currentIndex;
  Duration get position;
  Stream<int?> get currentIndexStream;
}

/// Adapts a real [AudioPlayer] to [QueuePlayer]; used in production.
class JustAudioQueuePlayer implements QueuePlayer {
  JustAudioQueuePlayer(this.player);
  final AudioPlayer player;

  @override
  Future<void> addAudioSource(AudioSource source) =>
      player.addAudioSource(source);

  @override
  Future<void> insertAudioSource(int index, AudioSource source) =>
      player.insertAudioSource(index, source);

  @override
  Future<void> removeAudioSourceAt(int index) =>
      player.removeAudioSourceAt(index);

  @override
  Future<void> moveAudioSource(int from, int to) =>
      player.moveAudioSource(from, to);

  @override
  Future<void> setAudioSources(
    List<AudioSource> sources, {
    int? initialIndex,
    Duration initialPosition = Duration.zero,
  }) =>
      player.setAudioSources(
        sources,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
      );

  @override
  Future<void> seek(Duration position, {int? index}) =>
      player.seek(position, index: index);

  @override
  Future<void> play() => player.play();

  @override
  int? get currentIndex => player.currentIndex;

  @override
  Duration get position => player.position;

  @override
  Stream<int?> get currentIndexStream => player.currentIndexStream;
}
```

- [ ] **Step 2a: Create the shared `FakeQueuePlayer` support file.** This is the ONE place `FakeQueuePlayer` is declared; every test that needs a headless player imports it (no per-test re-declarations). Create `test/support/fake_queue_player.dart`. It mirrors the incremental ops into `sources` and records the cross-slice signals (remove/seek calls, a settable `currentIndex`, and a `currentIndexStream`) the shuffle tests drive:

```dart
import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/queue_player.dart';

/// Shared [QueuePlayer] test double. A real just_audio AudioPlayer needs the
/// media_kit platform channel and cannot run under headless `flutter test`, so
/// unit tests inject this. It mirrors the incremental ops into [sources] and
/// records remove/seek calls plus a settable current index so the queue logic
/// (including the Slice-5 shuffle index translation) can be asserted.
class FakeQueuePlayer implements QueuePlayer {
  /// The fake's view of the player's source order, mutated by the incremental
  /// ops so tests can assert it ended up 1:1 with QueueController._playOrder.
  final List<String> sources = [];

  /// Every removeAudioSourceAt(index) the controller issued, in order.
  final List<int> removedIndexes = [];

  /// Every seek(position, index:) the controller issued, in order.
  final List<({Duration position, int? index})> seeks = [];

  bool played = false;

  int? _currentIndex = 0;
  final _indexCtrl = StreamController<int?>.broadcast();

  String _path(AudioSource s) => (s as UriAudioSource).uri.toFilePath();

  @override
  int? get currentIndex => _currentIndex;

  /// Test hook: simulate the player advancing to a source position.
  void setCurrentIndex(int? i) {
    _currentIndex = i;
    _indexCtrl.add(i);
  }

  @override
  Stream<int?> get currentIndexStream => _indexCtrl.stream;

  @override
  Future<void> addAudioSource(AudioSource source) async {
    sources.add(_path(source));
  }

  @override
  Future<void> insertAudioSource(int index, AudioSource source) async {
    sources.insert(index, _path(source));
  }

  @override
  Future<void> removeAudioSourceAt(int index) async {
    removedIndexes.add(index);
    sources.removeAt(index);
  }

  @override
  Future<void> moveAudioSource(int from, int to) async {
    final p = sources.removeAt(from);
    sources.insert(to, p);
  }

  @override
  Future<void> setAudioSources(
    List<AudioSource> list, {
    int? initialIndex,
    Duration initialPosition = Duration.zero,
  }) async {
    sources
      ..clear()
      ..addAll(list.map(_path));
    setCurrentIndex(list.isEmpty ? null : (initialIndex ?? 0));
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    seeks.add((position: position, index: index));
    if (index != null) setCurrentIndex(index);
  }

  @override
  Future<void> play() async {
    played = true;
  }

  @override
  Duration get position => Duration.zero;
}
```

  > Note: `AudioSource.file(p)` constructs a `UriAudioSource` whose `.uri.toFilePath()` recovers the path, so the fake records the appended/inserted source paths.

- [ ] **Step 2b: Failing test first.** Create `test/queue_controller_test.dart`. It imports the shared `FakeQueuePlayer`, exercises `append`/`clear`/`revision`, and verifies (a) `orderedPaths` grows, (b) the fake's source list mirrors it, (c) `revision` bumps, and (d) the persisted `QueueSnapshot` (read back through the real `saveQueue`/`loadQueue` FFI against a temp on-disk db) reflects the appended paths.

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/queue.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:path/path.dart' as p;

import 'support/fake_queue_player.dart';

void main() {
  late Directory tmp;
  late String dbPath;

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('olivier_queue_test');
    dbPath = p.join(tmp.path, 'test.db');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('append grows the queue, mirrors the player, bumps revision', () async {
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(player, dbPath: dbPath);

    final before = qc.revision.value;
    await qc.append(['/m/a.flac', '/m/b.flac']);

    expect(qc.orderedPaths, ['/m/a.flac', '/m/b.flac']);
    expect(player.sources, ['/m/a.flac', '/m/b.flac']);
    expect(qc.revision.value, greaterThan(before));

    // A second append extends, never replaces.
    await qc.append(['/m/c.flac']);
    expect(qc.orderedPaths, ['/m/a.flac', '/m/b.flac', '/m/c.flac']);
    expect(player.sources, ['/m/a.flac', '/m/b.flac', '/m/c.flac']);
  });

  test('append persists a QueueSnapshot the FFI can read back', () async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(), dbPath: dbPath);
    await qc.append(['/m/a.flac', '/m/b.flac']);

    final snap = await loadQueue(dbPath: dbPath);
    expect(snap, isNotNull);
    expect(snap!.paths, ['/m/a.flac', '/m/b.flac']);
    expect(snap.shuffle, isFalse);
  });

  test('clear empties the queue, the player, and persistence', () async {
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(player, dbPath: dbPath);
    await qc.append(['/m/a.flac']);
    final before = qc.revision.value;

    await qc.clear();

    expect(qc.orderedPaths, isEmpty);
    expect(qc.playOrder, isEmpty);
    expect(player.sources, isEmpty);
    expect(qc.revision.value, greaterThan(before));

    // loadQueue returns null when no rows remain.
    expect(await loadQueue(dbPath: dbPath), isNull);
  });
}
```

- [ ] **Step 3: Run it — fails.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_controller_test.dart`. Expected failure: compile error — `QueueController` has no `withPlayer` constructor, no `append`, no `clear`, no `revision`.

- [ ] **Step 4: Refit `QueueController` onto the port.** Edit `lib/audio/queue_controller.dart`. Replace the import block + constructor + fields:

  Replace:
  ```dart
  import 'dart:developer' as developer;
  import 'dart:io';

  import 'package:just_audio/just_audio.dart';
  import 'package:olivier/src/rust/api/queue.dart';
  import 'package:olivier/src/rust/db.dart';

  /// Holds the canonical ordered list and rebuilds the player's sources on
  /// shuffle (engine shuffle is ignored by the media_kit backend on Linux).
  class QueueController {
    QueueController(this.player, {required this.dbPath});
    final AudioPlayer player;
    final String dbPath;

    List<String> _orderedPaths = [];
  ```
  with:
  ```dart
  import 'dart:developer' as developer;
  import 'dart:io';

  import 'package:flutter/foundation.dart';
  import 'package:just_audio/just_audio.dart';
  import 'package:olivier/audio/queue_player.dart';
  import 'package:olivier/src/rust/api/queue.dart';
  import 'package:olivier/src/rust/db.dart';

  /// Holds the canonical ordered list and rebuilds the player's sources on
  /// shuffle (engine shuffle is ignored by the media_kit backend on Linux).
  class QueueController {
    QueueController(AudioPlayer player, {required this.dbPath})
        : _player = JustAudioQueuePlayer(player);

    /// Test seam: inject a [QueuePlayer] (fake) directly.
    @visibleForTesting
    QueueController.withPlayer(this._player, {required this.dbPath});

    final QueuePlayer _player;
    final String dbPath;

    /// Bumped after every mutation so the queue view can rebuild.
    final ValueNotifier<int> revision = ValueNotifier(0);

    List<String> _orderedPaths = [];
  ```

- [ ] **Step 5: Repoint existing `player.` calls at `_player`.** The existing body references `player.setAudioSources`, `player.currentIndex`, `player.position`. Update each:
  - In `_rebuild`, change `await player.setAudioSources(` to `await _player.setAudioSources(`.
  - In `_persist`, change `currentIndex: player.currentIndex ?? 0,` to `currentIndex: _player.currentIndex ?? 0,` and `positionMs: BigInt.from(player.position.inMilliseconds),` to `positionMs: BigInt.from(_player.position.inMilliseconds),`.

  > **Note for callers:** `PlaybackController` and `restoreNowPlaying` read `queueController.playOrder` (unchanged getter) and call `audioHandler.player` directly, not `queueController.player`, so removing the public `player` field does not break them. Confirm with a project-wide grep in Step 7.

- [ ] **Step 6: Add `append` and `clear` (and bump revision in `setQueue`/`setShuffle`).** Insert these methods after `setShuffle` in `lib/audio/queue_controller.dart`:

```dart
  /// Append paths to the END of the queue without interrupting playback. Each
  /// path is added to the canonical order and mirrored to the player via the
  /// incremental `addAudioSource` op (no rebuild → current track keeps playing).
  /// When not shuffled, `_playOrder` stays equal to `_orderedPaths`; when
  /// shuffled, new paths join the tail of both (they were not part of the
  /// earlier shuffle, which is acceptable — a reshuffle is a deliberate reset).
  Future<void> append(List<String> paths) async {
    for (final path in paths) {
      _orderedPaths.add(path);
      _playOrder.add(path);
      await _player.addAudioSource(AudioSource.file(path));
    }
    await _persist();
    revision.value++;
  }

  /// Empty the whole queue and stop driving the player.
  Future<void> clear() async {
    _orderedPaths = [];
    _playOrder = [];
    await _player.setAudioSources([]);
    await _persist();
    revision.value++;
  }
```

  Then add `revision.value++;` as the last statement of `setQueue` (after `await _persist();`) and of `setShuffle` (after `await _persist();`).

- [ ] **Step 7: Verify no other caller used the removed public `player` field.** Command: `cd /home/autarch/projects/olivier && grep -rn 'queueController\.player' lib/`. Expected: no matches (callers use `audioHandler.player`, not `queueController.player`). If any `queueController.player` remains, it is a real break to fix before proceeding.

- [ ] **Step 8: Run it — passes.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_controller_test.dart`. Expected: all three tests pass.

- [ ] **Step 9: Lint.** Command: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`. Expected: clean.

- [ ] **Step 10: Commit.** `cd /home/autarch/projects/olivier && git add lib/audio/queue_player.dart lib/audio/queue_controller.dart test/support/fake_queue_player.dart test/queue_controller_test.dart && git commit -m "Add QueueController.append/clear + revision via a testable QueuePlayer port"`

---

### Task 6: `selectedTrackProvider` + `queueControllerProvider`

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/state/providers.dart`
- Modify: `/home/autarch/projects/olivier/lib/audio/playback_controller.dart`
- Test: `/home/autarch/projects/olivier/test/selected_track_provider_test.dart`

- [ ] **Step 1: Failing test first.** Create `test/selected_track_provider_test.dart`, modeled on `language_leads_provider_test.dart`. It also asserts that selecting a new album clears the track selection.

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/providers.dart';

void main() {
  test('selectedTrackProvider holds and clears a track id', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(selectedTrackProvider), isNull);

    container.read(selectedTrackProvider.notifier).select(42);
    expect(container.read(selectedTrackProvider), 42);

    container.read(selectedTrackProvider.notifier).clear();
    expect(container.read(selectedTrackProvider), isNull);
  });

  test('selecting an album clears the track selection', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(selectedTrackProvider.notifier).select(7);
    expect(container.read(selectedTrackProvider), 7);

    container.read(selectedAlbumProvider.notifier).select('rel-x');
    expect(container.read(selectedTrackProvider), isNull);
  });
}
```

- [ ] **Step 2: Run it — fails.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/selected_track_provider_test.dart`. Expected failure: `selectedTrackProvider` is undefined.

- [ ] **Step 3: Add `SelectedTrack` + provider.** In `lib/state/providers.dart`, add after the `selectedAlbumProvider` definition. The track key is the catalog track id (`int`).

```dart
// --- Selected track ---

class SelectedTrack extends Notifier<int?> {
  @override
  int? build() => null;

  void select(int? trackId) {
    state = trackId;
  }

  void clear() {
    state = null;
  }
}

final selectedTrackProvider =
    NotifierProvider<SelectedTrack, int?>(SelectedTrack.new);
```

- [ ] **Step 4: Clear track selection when the album changes.** In `lib/state/providers.dart`, in `SelectedAlbum.select`, change:
  ```dart
    void select(String? releaseMbid) {
      state = releaseMbid;
    }
  ```
  to:
  ```dart
    void select(String? releaseMbid) {
      state = releaseMbid;
      // A new album resets the track highlight (mirrors artist→album).
      ref.read(selectedTrackProvider.notifier).clear();
    }
  ```

- [ ] **Step 5: Run it — passes.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/selected_track_provider_test.dart`. Expected: both tests pass.

- [ ] **Step 6: Expose the QueueController to Riverpod.** In `lib/audio/playback_controller.dart`, after the `playbackControllerProvider` definition, add:

```dart
/// Exposes the [QueueController] held by the [PlaybackController] so queue
/// panels and enqueue menus can call its ops directly.
final queueControllerProvider = Provider<QueueController>(
  (ref) => ref.watch(playbackControllerProvider).queueController,
);
```

  `PlaybackController.queueController` is already a public final field (line 26), and `QueueController` is already imported in this file (line 8), so no other change is needed there.

- [ ] **Step 7: Lint + the wider test suite still green.** Commands: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all` then `cd /home/autarch/projects/olivier && mise exec -- flutter test`. Expected: clean lint; all tests pass (the new `select` clearing must not break existing album/track tests).

- [ ] **Step 8: Commit.** `cd /home/autarch/projects/olivier && git add lib/state/providers.dart lib/audio/playback_controller.dart test/selected_track_provider_test.dart && git commit -m "Add selectedTrackProvider + queueControllerProvider; clear track on album change"`

---

### Task 7: `QueueView` + `queueProvider` (canonical-order resolution)

**Files:**
- Create: `/home/autarch/projects/olivier/lib/state/queue_provider.dart`
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart`
- Test: `/home/autarch/projects/olivier/test/queue_provider_test.dart`

> **Decision:** `queueProvider` is reactive to `controller.revision` and re-resolves `orderedPaths → List<QueueTrack>` via the `tracksForPaths` FFI. The FFI call goes through a `TracksForPathsFn` seam provider (same pattern as `getSettingFnProvider`). `currentIndex` in `QueueView` is the canonical index = index in `orderedPaths` of `playOrder[player.currentIndex ?? 0]`, exposed via the contract-named `QueueController.currentCanonicalIndex` getter so the notifier doesn't reach into the player. Listening to `player.currentIndexStream` is wired live; in this slice the test drives revision changes (the stream wiring is asserted in Slice 5).

- [ ] **Step 1: Create `QueueView` + `QueueNotifier` + `queueProvider`.** Create `lib/state/queue_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/catalog.dart' as catalog;
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

/// Immutable snapshot of the queue for the panel to render, in canonical order.
class QueueView {
  const QueueView({
    required this.tracks,
    required this.currentIndex,
    required this.shuffled,
  });

  final List<QueueTrack> tracks;

  /// Canonical index (into [tracks]) of the currently-playing entry, or null
  /// when the queue is empty / nothing is current.
  final int? currentIndex;
  final bool shuffled;

  static const empty =
      QueueView(tracks: <QueueTrack>[], currentIndex: null, shuffled: false);
}

/// FFI seam so [QueueNotifier] is unit-testable without the real bridge.
typedef TracksForPathsFn = Future<List<QueueTrack>> Function(List<String> paths);

final tracksForPathsFnProvider = Provider<TracksForPathsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (paths) => catalog.tracksForPaths(dbPath: db, paths: paths);
});

class QueueNotifier extends AsyncNotifier<QueueView> {
  QueueController get _controller => ref.read(queueControllerProvider);

  @override
  Future<QueueView> build() async {
    final controller = _controller;

    // Re-resolve whenever the controller mutates the queue.
    void onRevision() => ref.invalidateSelf();
    controller.revision.addListener(onRevision);
    ref.onDispose(() => controller.revision.removeListener(onRevision));

    return _resolve();
  }

  Future<QueueView> _resolve() async {
    final controller = _controller;
    final paths = controller.orderedPaths;
    if (paths.isEmpty) return QueueView.empty;

    final tracks = await ref.read(tracksForPathsFnProvider)(paths);
    return QueueView(
      tracks: tracks,
      currentIndex: controller.currentCanonicalIndex,
      shuffled: controller.shuffled,
    );
  }
}

final queueProvider =
    AsyncNotifierProvider<QueueNotifier, QueueView>(QueueNotifier.new);
```

- [ ] **Step 2: Add the canonical-index getter to `QueueController`.** In `lib/audio/queue_controller.dart`, add after the `playOrder` getter:

```dart
  /// Canonical index (into [orderedPaths]) of the entry the player is currently
  /// on. Equals `player.currentIndex` when not shuffled; when shuffled it maps
  /// the player's current source back through `_playOrder`. Null when empty.
  int? get currentCanonicalIndex {
    if (_orderedPaths.isEmpty) return null;
    final pi = _player.currentIndex ?? 0;
    if (pi < 0 || pi >= _playOrder.length) return null;
    final idx = _orderedPaths.indexOf(_playOrder[pi]);
    return idx < 0 ? null : idx;
  }
```

- [ ] **Step 3: Failing test first.** Create `test/queue_provider_test.dart`. It drives a real `QueueController.withPlayer(FakeQueuePlayer())` (the shared fake from Task 5), overrides `queueControllerProvider` and `tracksForPathsFnProvider`, and asserts the `QueueView` reflects appended tracks and refreshes on revision bump.

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

QueueTrack _qt(String path, String title) => QueueTrack(
      path: path,
      title: title,
      album: 'Album',
    );

void main() {
  test('queueProvider resolves appended paths into a QueueView', () async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(), dbPath: '/x.db');

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
    expect(after.tracks.map((t) => t.path).toList(),
        ['/m/a.flac', '/m/b.flac']);
    expect(after.currentIndex, 0);
    expect(after.shuffled, isFalse);
  });
}
```

  Note: `queueControllerProvider` is overridden directly with the test `QueueController`, so `PlaybackController`/`playbackControllerProvider` is never read here.

- [ ] **Step 4: Run it — fails or passes.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_provider_test.dart`. If Steps 1–2 are not yet applied, it fails to compile on the missing `queue_provider.dart` / `currentCanonicalIndex`.

- [ ] **Step 5: (Implementation already in Steps 1–2.)** Ensure `lib/state/queue_provider.dart` and the `currentCanonicalIndex` getter are in place.

- [ ] **Step 6: Run it — passes.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_provider_test.dart`. Expected: the test passes.

- [ ] **Step 7: Lint.** Command: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`. Expected: clean.

- [ ] **Step 8: Commit.** `cd /home/autarch/projects/olivier && git add lib/state/queue_provider.dart lib/audio/queue_controller.dart test/queue_provider_test.dart && git commit -m "Add QueueView + queueProvider resolving the canonical queue via tracks_for_paths"`

---

### Task 8: Track column — single-click selects, double-click appends (item 9)

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/state/providers.dart`
- Modify: `/home/autarch/projects/olivier/lib/catalog/track_column.dart`
- Test: `/home/autarch/projects/olivier/test/track_column_select_test.dart`

- [ ] **Step 1: Failing test first.** Create `test/track_column_select_test.dart`. It verifies (a) single tap selects the track (no `playTrack` call — the test does NOT override `playbackControllerProvider`, so any call would throw, caught by `takeException`) and (b) a double tap calls the `trackPath` FFI seam then `QueueController.append`, growing the queue. The `trackPath` FFI is wrapped behind a seam provider added in Step 3.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

import 'support/fake_queue_player.dart';

final _track = Track(id: 7, disc: 1, position: 1, title: 'Song', addedAt: 0);

class _StubAlbum extends SelectedAlbum {
  _StubAlbum(this._initial);
  final String _initial;
  @override
  String? build() => _initial;
}

ProviderScope _app(QueueController qc) => ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
        queueControllerProvider.overrideWithValue(qc),
        trackPathFnProvider.overrideWithValue((id) async => '/m/song.flac'),
      ],
      child: const MaterialApp(
        home: Scaffold(
            body: SizedBox(width: 320, height: 600, child: TrackColumn())),
      ),
    );

void main() {
  testWidgets('single tap selects the track and does not play', (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(), dbPath: '/x.db');
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      tracksProvider.overrideWith((ref) => [_track]),
      selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
      queueControllerProvider.overrideWithValue(qc),
      trackPathFnProvider.overrideWithValue((id) async => '/m/song.flac'),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: TrackColumn()),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1. Song'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // no playbackController read
    expect(container.read(selectedTrackProvider), 7);
    expect(qc.orderedPaths, isEmpty); // selection must not enqueue
  });

  testWidgets('double tap resolves the path and appends to the queue',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(), dbPath: '/x.db');
    await tester.pumpWidget(_app(qc));
    await tester.pumpAndSettle();

    final row = find.text('1. Song');
    await tester.tap(row);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(qc.orderedPaths, ['/m/song.flac']);
  });
}
```

  > **Decision:** the test seam `trackPathFnProvider` (added Step 3) wraps the `trackPath` FFI so the widget test never hits the bridge. The double-tap test pumps `kDoubleTapMinTime` between taps so `onDoubleTap` fires.

- [ ] **Step 2: Run it — fails.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/track_column_select_test.dart`. Expected failure: `trackPathFnProvider` undefined and `track_column.dart` still calls `playTrack`.

- [ ] **Step 3: Add the `trackPath` FFI seam.** In `lib/state/providers.dart`, add near the other FFI seams (after `setSettingFnProvider`). `providers.dart` already imports `package:olivier/src/rust/api/catalog.dart`, so `trackPath` is in scope after regen.

```dart
// Resolves one track's single play path (MIN path); seam for testability.
typedef TrackPathFn = Future<String?> Function(int trackId);

final trackPathFnProvider = Provider<TrackPathFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (trackId) => trackPath(dbPath: db, trackId: trackId);
});
```

- [ ] **Step 4: Rewrite the track row to select + double-click-append.** In `lib/catalog/track_column.dart`'s `_TrackList.build`, add the selection watch right after `final leads = ...`:

```dart
    final selectedTrack = ref.watch(selectedTrackProvider);
```

  Then in `itemBuilder` replace:
  ```dart
        final track = tracks[index];
        return InkWell(
          key: ValueKey(track.id),
          onTap: () {
            if (releaseMbid == null) return;
            ref.read(playbackControllerProvider).playTrack(
                  releaseMbid,
                  albumTitle,
                  index,
                );
          },
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
  ```
  with:
  ```dart
        final track = tracks[index];
        final trackId = track.id;
        final isSelected = selectedTrack == trackId;
        return InkWell(
          key: ValueKey(track.id),
          onTap: () =>
              ref.read(selectedTrackProvider.notifier).select(trackId),
          onDoubleTap: () async {
            final path = await ref.read(trackPathFnProvider)(trackId);
            if (path == null) return;
            await ref.read(queueControllerProvider).append([path]);
          },
          child: Container(
            color: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
  ```

  > After this change `releaseMbid`/`albumObj`/`albumTitle` (lines 35–37) are unused. Remove those three now-dead locals to satisfy `analyze`; keep `leads`.

- [ ] **Step 5: Run it — passes.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/track_column_select_test.dart`. Expected: both tests pass.

- [ ] **Step 6: Lint.** Command: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`. Expected: clean (no unused-import / dead-local warnings).

- [ ] **Step 7: Commit.** `cd /home/autarch/projects/olivier && git add lib/state/providers.dart lib/catalog/track_column.dart test/track_column_select_test.dart && git commit -m "Track rows: single-click selects, double-click appends (item 9)"`

---

### Task 9: Album column — remove play button, double-click appends album

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/state/providers.dart`
- Modify: `/home/autarch/projects/olivier/lib/catalog/album_column.dart`
- Test: `/home/autarch/projects/olivier/test/album_column_enqueue_test.dart`

- [ ] **Step 1: Failing test first.** Create `test/album_column_enqueue_test.dart`. Asserts (a) no `Icons.play_arrow` button is present, (b) double-clicking an album resolves its file paths via a seam and appends them all.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

import 'support/fake_queue_player.dart';

const _album = Album(
  releaseMbid: 'rel-1',
  title: 'Album One',
  albumArtist: 'Artist',
);

void main() {
  testWidgets('album rows have no play button', (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(), dbPath: '/x.db');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        albumsProvider.overrideWith((ref) => [_album]),
        queueControllerProvider.overrideWithValue(qc),
        albumFilePathsFnProvider
            .overrideWithValue((mbid) async => ['/m/a.flac', '/m/b.flac']),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('double-tapping an album appends its tracks', (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(), dbPath: '/x.db');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        albumsProvider.overrideWith((ref) => [_album]),
        queueControllerProvider.overrideWithValue(qc),
        albumFilePathsFnProvider
            .overrideWithValue((mbid) async => ['/m/a.flac', '/m/b.flac']),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();

    final row = find.text('Album One');
    await tester.tap(row);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(qc.orderedPaths, ['/m/a.flac', '/m/b.flac']);
  });
}
```

- [ ] **Step 2: Run it — fails.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/album_column_enqueue_test.dart`. Expected failure: `albumFilePathsFnProvider` undefined; and (once defined) the play-arrow `findsNothing` assertion fails because the `IconButton` still exists.

- [ ] **Step 3: Add the album-paths FFI seam.** In `lib/state/providers.dart`, after `trackPathFnProvider`. `albumFilePaths` is already exported from the catalog FFI imported at the top of `providers.dart`.

```dart
// Resolves an album's file paths (one per track, disc/position order); seam.
typedef AlbumFilePathsFn = Future<List<String>> Function(String releaseMbid);

final albumFilePathsFnProvider = Provider<AlbumFilePathsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (releaseMbid) => albumFilePaths(dbPath: db, releaseMbid: releaseMbid);
});
```

- [ ] **Step 4: Remove the play button, add double-click-append.** In `lib/catalog/album_column.dart`:
  - Keep the `import 'package:olivier/audio/playback_controller.dart';` (it now provides `queueControllerProvider`).
  - On the `InkWell` (line 43), add `onDoubleTap`:
    ```dart
        return InkWell(
          key: ValueKey(album.releaseMbid),
          onTap: () {
            ref.read(selectedAlbumProvider.notifier).select(album.releaseMbid);
            // Store the full album object so the track column can access title.
            ref.read(selectedAlbumObjectProvider.notifier).select(album);
          },
          onDoubleTap: () async {
            final paths =
                await ref.read(albumFilePathsFnProvider)(album.releaseMbid);
            if (paths.isEmpty) return;
            await ref.read(queueControllerProvider).append(paths);
          },
    ```
  - Delete the `IconButton(...)` and its trailing comma from the `Row` `children` (lines 67–81), leaving just the `Expanded(child: BilingualText(...))`. After removal the `Row` has a single child; that is fine.

- [ ] **Step 5: Run it — passes.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/album_column_enqueue_test.dart`. Expected: both tests pass.

- [ ] **Step 6: Confirm no remaining play-arrow / playAlbum reference from browse columns.** Command: `cd /home/autarch/projects/olivier && grep -rn 'playAlbum\|playTrack\|Icons.play_arrow' lib/catalog`. Expected: no matches (item 9 satisfied structurally). `playAlbum`/`playTrack` remain only in `playback_controller.dart` for internal/restore use.

- [ ] **Step 7: Lint + full suite.** Commands: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all` then `cd /home/autarch/projects/olivier && mise exec -- flutter test`. Expected: clean; all tests pass.

- [ ] **Step 8: Commit.** `cd /home/autarch/projects/olivier && git add lib/state/providers.dart lib/catalog/album_column.dart test/album_column_enqueue_test.dart && git commit -m "Album rows: remove play button, double-click appends the album (items 9, 10)"`

---

### Task 10: Queue panel collapsed header (count + up-next)

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/catalog/queue_panel.dart`
- Test: `/home/autarch/projects/olivier/test/queue_panel_header_test.dart`

> **Decision:** This task ships the collapsed header (`Queue · {N} tracks · up next: {title}`) reading `queueProvider`; the expand caret/toggle and the expanded `ReorderableListView` body (and the Shuffle/Empty/Shuffle-all wiring) are Slices 3–5. The caret is a disabled placeholder so the layout is final. "Up next" = the entry after `currentIndex` in canonical order, or the first track when nothing is current yet. This replaces the Slice 1 collapsed shell (`QueuePanel` becomes a `ConsumerWidget`). The panel is already mounted in `browser_page.dart` from Slice 1, so no `browser_page.dart` change is needed here.

- [ ] **Step 1: Failing test first.** Create `test/queue_panel_header_test.dart`. Overrides `queueProvider` with a fixed `QueueView` (via a stub notifier) and asserts the header text.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

QueueTrack _qt(String title) =>
    QueueTrack(path: '/m/$title', title: title, album: 'Album');

class _StubQueue extends QueueNotifier {
  _StubQueue(this._view);
  final QueueView _view;
  @override
  Future<QueueView> build() async => _view;
}

Widget _app(QueueView view) => ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        queueProvider.overrideWith(() => _StubQueue(view)),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    );

void main() {
  testWidgets('header shows the real count and up-next title', (tester) async {
    await tester.pumpWidget(_app(QueueView(
      tracks: [_qt('One'), _qt('Two'), _qt('Three')],
      currentIndex: 0,
      shuffled: false,
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 tracks'), findsOneWidget);
    // current is index 0 → "up next" is the following entry, "Two".
    expect(find.textContaining('Two'), findsOneWidget);
  });

  testWidgets('empty queue header shows 0 tracks and no up-next',
      (tester) async {
    await tester.pumpWidget(_app(QueueView.empty));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 tracks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run it — fails.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_panel_header_test.dart`. Expected failure: the current `QueuePanel` is the Slice-1 `StatelessWidget` shell with the placeholder `'Queue · 0'` text, so `find.textContaining('3 tracks')` finds nothing and `queueProvider.overrideWith` has no effect.

- [ ] **Step 3: Implement the collapsed header.** Replace the contents of `lib/catalog/queue_panel.dart` (the Slice-1 shell) with a `ConsumerWidget`. Bilingual rendering of the up-next title is Slice 3; here a plain `Text` of the original title is enough for the header summary.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/queue_provider.dart';

/// Collapsible queue panel between the browse split and the now-playing bar.
/// This slice renders only the collapsed header (count + up-next); the expanded
/// reorderable list and the Shuffle/Empty/Shuffle-all controls land in later
/// slices.
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(queueProvider);
    final view = queueAsync.valueOrNull ?? QueueView.empty;
    final count = view.tracks.length;

    final upNext = _upNext(view);
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.queue_music, size: 20),
            const SizedBox(width: 8),
            Text('Queue · $count tracks', style: theme.textTheme.bodyMedium),
            if (upNext != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '· up next: $upNext',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ] else
              const Spacer(),
            // Expand caret — wired to expand/collapse in slice 3.
            IconButton(
              icon: const Icon(Icons.expand_less),
              tooltip: 'Expand queue',
              onPressed: null,
            ),
          ],
        ),
      ),
    );
  }

  /// The title of the entry that plays after the current one (or the first entry
  /// when nothing is current yet); null when the queue is empty or at its end.
  String? _upNext(QueueView view) {
    if (view.tracks.isEmpty) return null;
    final current = view.currentIndex;
    final nextIndex = current == null ? 0 : current + 1;
    if (nextIndex >= view.tracks.length) return null;
    return view.tracks[nextIndex].title;
  }
}
```

  > **Reconciliation note:** the Slice-1 `queue_panel_shell_test.dart` asserted the disabled Shuffle/Empty/Shuffle-all tooltips on the static shell. Those controls move into the expanded/header wiring in Slices 3–5; delete `test/queue_panel_shell_test.dart` in this task (its assertions are superseded by `queue_panel_header_test.dart` and the Slice-3/4/5 panel tests) and drop it from the commit.

- [ ] **Step 4: Run it — passes.** Command: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_panel_header_test.dart`. Expected: both tests pass.

- [ ] **Step 5: Lint + full suite + build.** Commands: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`; `cd /home/autarch/projects/olivier && mise exec -- flutter test`; `cd /home/autarch/projects/olivier && mise exec -- flutter build linux --debug`. Expected: clean lint; all tests pass; build succeeds.

- [ ] **Step 6: Commit.** `cd /home/autarch/projects/olivier && git add lib/catalog/queue_panel.dart test/queue_panel_header_test.dart && git rm test/queue_panel_shell_test.dart && git commit -m "Add collapsed queue-panel header (count + up-next) wired to queueProvider"`

---

**Slice 2 deliverable:** Clicking a track or album in the browse columns only *selects* it (highlighted, no playback anywhere in the browse area — item 9 holds structurally); the album row's play button is gone. Double-clicking a track resolves its single path via the new `track_path` FFI and appends it; double-clicking an album appends all its tracks — both via `QueueController.append`, which mirrors to the player incrementally (no playback interruption), persists a `QueueSnapshot`, and bumps a `revision` notifier. `queueProvider` resolves the canonical queue to `QueueTrack`s and the collapsed queue-panel header shows the live track count and up-next title.

---

## Slice 3 — Queue panel operations

> **Builds on Slices 1–2:** `queue_panel.dart` (collapsed header reading `queueProvider`), `queueProvider`/`QueueView`/`QueueNotifier`, `queueControllerProvider`, `QueueController.append` + `revision` + `clear`, and the `QueuePlayer` port + `FakeQueuePlayer` test pattern all exist. This slice adds `removeAt`/`reorder`/`playAt` and expands the panel into a `ReorderableListView`.
>
> **Reconciliation note:** the Slice-3 draft introduced a `SaveQueueFn` seam and a `FakeAudioPlayer extends AudioPlayer`. Per the locked contracts, persistence is captured instead through the `QueuePlayer` port + a temp `:memory:`/on-disk db via `dbPath` (as in Slice 2's `queue_controller_test.dart`), and the fake is `FakeQueuePlayer implements QueuePlayer`. No `SaveQueueFn` seam and no `FakeAudioPlayer` are added; the ops tests assert `orderedPaths`, `playOrder`, the fake's recorded ops, and the persisted snapshot via `loadQueue`. No Rust/FFI change in this slice → no bridge regen.

### Task 11: QueueController.removeAt / reorder / clear ops + tests

> `clear` already exists from Slice 2; this task adds `removeAt`/`reorder` and an ops test that also re-verifies `clear`. Each mutates `_orderedPaths`, mirrors to the player via the incremental ops (not-shuffled path only — **shuffled index translation is finished in Slice 5**), calls `_persist()`, then bumps `revision`.

**Files:**
- Test: `/home/autarch/projects/olivier/test/queue_controller_ops_test.dart` (Create)
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart`

- [ ] **Step 1: Write the failing unit test first.** Create `/home/autarch/projects/olivier/test/queue_controller_ops_test.dart`. It injects the shared `FakeQueuePlayer` via `QueueController.withPlayer`, asserts the recorded incremental ops (`sources`, `removedIndexes`, `seeks`, `played`), and captures the persisted `QueueSnapshot` through the real `loadQueue` FFI against a temp on-disk db, so the not-shuffled mirroring is asserted.

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/queue.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:path/path.dart' as p;

import 'support/fake_queue_player.dart';

void main() {
  setUpAll(() async => RustLib.init());

  late Directory tmp;
  late String dbPath;
  late FakeQueuePlayer player;
  late QueueController controller;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('olivier_queue_ops');
    dbPath = p.join(tmp.path, 'test.db');
    player = FakeQueuePlayer();
    controller = QueueController.withPlayer(player, dbPath: dbPath);
  });

  tearDown(() async => tmp.delete(recursive: true));

  test('removeAt drops the path, mirrors the player, persists, bumps revision',
      () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac']);
    final rev0 = controller.revision.value;

    await controller.removeAt(1);

    expect(controller.orderedPaths, ['/a.flac', '/c.flac']);
    expect(player.removedIndexes, [1]);
    expect(player.sources, ['/a.flac', '/c.flac']);
    final snap = await loadQueue(dbPath: dbPath);
    expect(snap!.paths, ['/a.flac', '/c.flac']);
    expect(controller.revision.value, greaterThan(rev0));
  });

  test('reorder moves within orderedPaths, mirrors the player, persists',
      () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac']);

    await controller.reorder(0, 2);

    expect(controller.orderedPaths, ['/b.flac', '/c.flac', '/a.flac']);
    // moveAudioSource(0, 2) mirrored into the fake's source order.
    expect(player.sources, ['/b.flac', '/c.flac', '/a.flac']);
    final snap = await loadQueue(dbPath: dbPath);
    expect(snap!.paths, ['/b.flac', '/c.flac', '/a.flac']);
  });

  test('clear empties the queue, the player, and persists', () async {
    await controller.append(['/a.flac', '/b.flac']);

    await controller.clear();

    expect(controller.orderedPaths, isEmpty);
    expect(controller.playOrder, isEmpty);
    expect(player.sources, isEmpty);
    expect(await loadQueue(dbPath: dbPath), isNull);
  });
}
```

- [ ] **Step 2: Run it — watch it fail.** Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_controller_ops_test.dart`. Expected failure: compile error / `NoSuchMethodError` — `removeAt` and `reorder` are not defined on `QueueController` yet (only `append`/`clear`/`setQueue`/`setShuffle` exist).

- [ ] **Step 3: Implement `removeAt`, `reorder` in `queue_controller.dart`.** Add these methods after `append`. Each mirrors the player with the incremental op so playback is not interrupted, persists, then bumps `revision`. The shuffled branches are written for completeness but the **index-translation correctness for shuffle is finished in Slice 5** — the not-shuffled path is the one this slice tests.

```dart
  /// Remove the entry at [index] in the DISPLAYED canonical order.
  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _orderedPaths.length) return;
    final path = _orderedPaths.removeAt(index);
    if (!_shuffled) {
      // Player order == canonical order, so the indices line up.
      _playOrder.removeAt(index);
      await _player.removeAudioSourceAt(index);
    } else {
      // Shuffled: find this path's position in the independent play order.
      // (Duplicate paths + shuffle edge cases are finished in Slice 5.)
      final playerIndex = _playOrder.indexOf(path);
      if (playerIndex >= 0) {
        _playOrder.removeAt(playerIndex);
        await _player.removeAudioSourceAt(playerIndex);
      }
    }
    await _persist();
    revision.value++;
  }

  /// Move the entry at [from] to [to] within the canonical order.
  Future<void> reorder(int from, int to) async {
    if (from < 0 || from >= _orderedPaths.length) return;
    final path = _orderedPaths.removeAt(from);
    final dest = to.clamp(0, _orderedPaths.length);
    _orderedPaths.insert(dest, path);
    if (!_shuffled) {
      _playOrder
        ..removeAt(from)
        ..insert(dest, path);
      await _player.moveAudioSource(from, dest);
    }
    // When shuffled, _playOrder is independent of the canonical order, so only
    // the canonical list + persistence change here (Slice 5 owns shuffle ops).
    await _persist();
    revision.value++;
  }
```

  Note on `reorder`'s `to`: `ReorderableListView` reports `newIndex` as the slot *before* removal (so a downward move's target is one past the final resting slot). The widget-side adapter (Task 12) normalizes that; here `reorder` takes already-normalized canonical indices, and `_player.moveAudioSource(from, dest)` matches just_audio's own from/to semantics.

- [ ] **Step 4: Run it — watch it pass.** Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_controller_ops_test.dart`. Expected: all three tests pass.

- [ ] **Step 5: Lint.** Run: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`. Expected: passes.

- [ ] **Step 6: Commit.** `cd /home/autarch/projects/olivier && git add lib/audio/queue_controller.dart test/queue_controller_ops_test.dart && git commit -m "Add QueueController removeAt/reorder with unit tests"`

---

### Task 12: QueueController.playAt — jump-to-and-play

> `playAt(index)` takes a canonical index, maps it to the player index via `_playOrder`, seeks to it, and plays. Not-shuffled path: canonical index == player index. The shuffled mapping is exercised in Slice 5; here the not-shuffled mapping is asserted.

**Files:**
- Test: `/home/autarch/projects/olivier/test/queue_controller_ops_test.dart` (Modify — add a test)
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart`

- [ ] **Step 1: Add the failing test.** Append inside `main()` in `test/queue_controller_ops_test.dart`:

```dart
  test('playAt seeks to the canonical index and plays (not shuffled)',
      () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac']);

    await controller.playAt(2);

    // Not shuffled: canonical index 2 == player index 2.
    expect(player.seeks.single.index, 2);
    expect(player.played, isTrue);
  });
```

- [ ] **Step 2: Run it — watch it fail.** Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_controller_ops_test.dart`. Expected failure: `NoSuchMethodError` — `playAt` not defined on `QueueController`.

- [ ] **Step 3: Implement `playAt`.** Add to `queue_controller.dart`:

```dart
  /// Jump to and play the entry at canonical [index].
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _orderedPaths.length) return;
    final path = _orderedPaths[index];
    // Map canonical -> player index (== index when not shuffled).
    final playerIndex = _shuffled ? _playOrder.indexOf(path) : index;
    if (playerIndex < 0) return;
    await _player.seek(Duration.zero, index: playerIndex);
    await _player.play();
  }
```

  (No `_persist()`/`revision` bump: `playAt` does not mutate the queue contents; the current-index change is persisted by the existing position/index write-back path.)

- [ ] **Step 4: Run it — watch it pass.** Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_controller_ops_test.dart`. Expected: all four tests pass.

- [ ] **Step 5: Lint.** Run: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`. Expected: passes.

- [ ] **Step 6: Commit.** `cd /home/autarch/projects/olivier && git add lib/audio/queue_controller.dart test/queue_controller_ops_test.dart && git commit -m "Add QueueController.playAt jump-to-and-play"`

---

### Task 13: Expanded queue panel — ReorderableListView with remove / reorder / tap-to-play / highlight

> `queue_panel.dart` gains its expanded body: a `ReorderableListView` of `queueProvider.tracks` rendered with `BilingualText`, each row carrying a drag handle, an `×` remove button, an `onTap` to jump, and current-track highlight; the header `Empty` control clears the queue. The panel reaches the `QueueController` through `queueControllerProvider`.
>
> **Decision (not pinned by CONTRACTS):** the widget test overrides `queueProvider` with a stub `QueueView` and overrides `queueControllerProvider` with a REAL `QueueController` backed by the shared headless `FakeQueuePlayer` (the `QueuePlayer` port + `FakeQueuePlayer` exist from Task 5). `queueControllerProvider` stays the concrete `Provider<QueueController>` from Task 6 — no extra interface is introduced (per the authoritative implementation decisions). The panel calls `QueueController` methods (`removeAt`/`reorder`/`clear`/`playAt`) through it; the test asserts those actions took effect by checking the recorded calls on the `FakeQueuePlayer` (`removedIndexes`/`seeks`/`played`/`sources`) and/or `qc.orderedPaths`.

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/catalog/queue_panel.dart`
- Test: `/home/autarch/projects/olivier/test/queue_panel_test.dart` (Create)

- [ ] **Step 1: Confirm the provider stays concrete.** No change to `queue_controller.dart` or `playback_controller.dart` is needed here: `queueControllerProvider` is already the concrete `Provider<QueueController>` from Task 6, and `removeAt`/`reorder`/`clear`/`playAt` are `QueueController` methods the panel calls directly through it. (No extra interface is introduced — per the authoritative implementation decisions.)

- [ ] **Step 2: Write the failing widget test.** Create `/home/autarch/projects/olivier/test/queue_panel_test.dart`. It overrides `queueProvider` with a fixed `QueueView` and overrides `queueControllerProvider` with a real `QueueController.withPlayer(FakeQueuePlayer(), dbPath: ':memory:')`, pumps the panel, expands it via the caret, and asserts rows render, `×` issues a `removeAudioSourceAt` (and drops the canonical path), a row tap issues a `seek`+`play`, and the header `Empty` issues `setAudioSources([])` (clearing `orderedPaths`).

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/src/rust/frb_generated.dart';
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
Future<({QueueController qc, FakeQueuePlayer player})> _seededController() async {
  final player = FakeQueuePlayer();
  final qc = QueueController.withPlayer(player, dbPath: ':memory:');
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
  setUpAll(() async => RustLib.init());

  testWidgets('expanded panel renders a bilingual row per queued track',
      (tester) async {
    final c = await _seededController();
    await tester.pumpWidget(_app(c.qc));
    await tester.pumpAndSettle();
    await _expand(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Kabukicho no Joo · Queen of Kabuki-cho'),
        findsOneWidget);
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
}
```

  Note: the reorder gesture is hard to drive reliably via synthetic drags in a unit test; this task asserts the reorder *callback* wiring with a focused test in Step 5 instead of a drag simulation. The four tests above cover render / remove / tap / Empty.

- [ ] **Step 3: Run it — watch it fail.** Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_panel_test.dart`. Expected failure: the panel currently has no expand toggle, no expanded `ReorderableListView`, no `×`/row-tap wiring, and no enabled `Empty` button — finds fail / `onPressed` is null.

- [ ] **Step 4: Implement the expanded panel body in `queue_panel.dart`.** Convert `QueuePanel` to a `ConsumerStatefulWidget` with an `_expanded` bool. Render the header row (count + up-next + Shuffle/Empty/Shuffle-all placeholders + expand/collapse caret); when `_expanded`, render `Expanded(child: _expandedList(...))` below it. The header `Empty` button becomes enabled and calls `ref.read(queueControllerProvider).clear()`; the expand caret toggles `_expanded` (tooltip `'Expand queue'` when collapsed, `'Collapse queue'` when expanded). The Shuffle and Shuffle-all controls stay as placeholders here (wired in Slices 4–5). Add the list builder:

```dart
  Widget _expandedList(BuildContext context, WidgetRef ref, QueueView view) {
    final leads = ref.watch(languageLeadsProvider);
    final controller = ref.read(queueControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    return ReorderableListView.builder(
      itemCount: view.tracks.length,
      onReorder: (oldIndex, newIndex) {
        // ReorderableListView reports newIndex as the pre-removal slot; for a
        // downward move that's one past the final resting slot. Normalize to a
        // canonical destination index before handing to the controller.
        ref
            .read(queueControllerProvider)
            .reorder(oldIndex, normalizeReorder(oldIndex, newIndex));
      },
      itemBuilder: (context, i) {
        final t = view.tracks[i];
        final selected = i == view.currentIndex;
        return Material(
          key: ValueKey('${t.path}#$i'),
          color: selected ? scheme.primaryContainer : Colors.transparent,
          child: InkWell(
            onTap: () => controller.playAt(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: BilingualText(
                      original: t.title,
                      translit: t.titleTranslit,
                      translate: t.titleTranslate,
                      leads: leads,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Remove from queue',
                    onPressed: () => controller.removeAt(i),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
```

  Add imports `package:olivier/widgets/bilingual_text.dart`, `package:olivier/state/providers.dart` (for `languageLeadsProvider`), and `package:olivier/audio/playback_controller.dart` (for `queueControllerProvider`) to `queue_panel.dart`. Give the header `Empty` control `tooltip: 'Empty queue', onPressed: () => ref.read(queueControllerProvider).clear()`.

- [ ] **Step 5: Add a focused reorder-normalization function + test.** Add a top-level function in `queue_panel.dart` (used by `onReorder` above):

```dart
int normalizeReorder(int oldIndex, int newIndex) =>
    newIndex > oldIndex ? newIndex - 1 : newIndex;
```

  Append to `test/queue_panel_test.dart`:

```dart
  test('reorder index normalization (downward move drops one slot)', () {
    expect(normalizeReorder(0, 3), 2); // move item 0 to bottom of 3-item list
    expect(normalizeReorder(2, 0), 0); // upward move is unchanged
  });
```

- [ ] **Step 6: Run it — watch it pass.** Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_panel_test.dart`. Expected: all panel tests pass; `tester.takeException()` is null (no overflow).

- [ ] **Step 7: Confirm Empty also clears now-playing.** Per the spec, Empty clears the queue *and* now-playing. `QueueController.clear()` empties the player's sources (`setAudioSources([])`), which drives `currentIndexStream` to `null` and clears the now-playing bar via the existing `PlaybackController` subscription (`_subscribeIndex`'s `if (i == null …) return;` guard stops emitting a stale media item). No extra teardown is added — clearing the player sources is the single source of truth. Add a one-line code comment in `clear()` noting this, then re-run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_controller_ops_test.dart test/queue_panel_test.dart`.

- [ ] **Step 8: Lint + full test sweep.** Run: `cd /home/autarch/projects/olivier && mise exec -- precious lint --all && mise exec -- flutter test`. Expected: lint clean; all tests pass.

- [ ] **Step 9: Commit.** `cd /home/autarch/projects/olivier && git add lib/catalog/queue_panel.dart test/queue_panel_test.dart && git commit -m "Expand queue panel: reorder, remove, tap-to-play, current highlight, Empty"`

---

**Slice 3 deliverable:** The queue panel's expand caret reveals a `ReorderableListView` of the canonical queue (bilingual titles, current track highlighted); dragging a row's handle reorders it, the `×` removes one entry, tapping a row jumps to and plays it, and the header `Empty` clears the whole queue and now-playing — all via `QueueController.removeAt`/`reorder`/`playAt`/`clear`, each persisting the updated `QueueSnapshot` and preserving uninterrupted playback (not-shuffled path; shuffled index translation lands in Slice 5), verified by headless unit tests (fake player + persisted snapshot) and a provider-override widget test.

---

## Slice 4 — Enqueue by entity: menus, drag, Shuffle-all

> **Decisions not pinned by CONTRACTS (stated inline):**
> - `queueControllerProvider` is the concrete `Provider<QueueController>` (from Task 6), so `append` is available directly via `ref.read(queueControllerProvider).append(...)`. Panels/menus call `QueueController` methods (`append`/`removeAt`/`reorder`/`clear`/`playAt`) straight through the provider.
> - The library-paths FFI seam is `libraryPathsFnProvider` (mirroring `getSettingFnProvider`) so the Shuffle-all dialog/widget tests can override it.
> - The shared context menu and drag payload model an entity as a small sealed `QueueEntityRef`; resolution to paths happens in one place (`resolveEntityPaths`) so menu, double-click, and drop share it.
> - `track_path` (Slice 2) already exists in the bridge by the time this slice runs and is reused for the track entity.

### Task 14: FFI `track_paths_for_artist` (Rust query + api + bridge)

**Files:**
- Modify: `/home/autarch/projects/olivier/rust/src/catalog/query.rs`
- Modify: `/home/autarch/projects/olivier/rust/src/api/catalog.rs`
- Test: `/home/autarch/projects/olivier/rust/tests/catalog_test.rs`
- Modify (generated): `/home/autarch/projects/olivier/lib/src/rust/**`, `/home/autarch/projects/olivier/rust/src/frb_generated.rs`

- [ ] **Step 1: Write the failing query test first.** Add to `rust/tests/catalog_test.rs`. It seeds two albums for one artist (with `release_group.first_release_date` set so album order is year-then-title), each with two tracks out of disc/position order, and asserts the flattened path order is album-order then disc/position. Add `track_paths_for_artist` to the `use rust_lib_olivier::catalog::query::{…}` import at the top.

```rust
#[test]
fn track_paths_for_artist_ordered_album_then_disc_position() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('art', 'Artist', 'Artist')",
        [],
    )
    .unwrap();
    // Newer album (2000) and older album (1999); insert newer first so ordering
    // is actually exercised.
    conn.execute(
        "INSERT INTO release_group(mbid, title, first_release_date) VALUES ('rg-new', 'New', '2000-01-01')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release_group(mbid, title, first_release_date) VALUES ('rg-old', 'Old', '1999-01-01')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, release_group_mbid, album_artist_mbid, title, date)
         VALUES ('rel-new', 'rg-new', 'art', 'New', '2000-01-01')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, release_group_mbid, album_artist_mbid, title, date)
         VALUES ('rel-old', 'rg-old', 'art', 'Old', '1999-01-01')",
        [],
    )
    .unwrap();
    // New album: tracks inserted position 2 then 1.
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (12, 'rel-new', 1, 2, 'N2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (11, 'rel-new', 1, 1, 'N1')",
        [],
    )
    .unwrap();
    // Old album: positions 2 then 1.
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2, 'rel-old', 1, 2, 'O2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1, 'rel-old', 1, 1, 'O1')",
        [],
    )
    .unwrap();
    for (path, tid) in [
        ("/m/new2.flac", 12),
        ("/m/new1.flac", 11),
        ("/m/old2.flac", 2),
        ("/m/old1.flac", 1),
    ] {
        conn.execute(
            "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES (?1, 0, 0, ?2, 0)",
            rusqlite::params![path, tid],
        )
        .unwrap();
    }

    let paths = track_paths_for_artist(&conn, "art").unwrap();
    // Old album (1999) first, then New (2000); within each, disc/position order.
    assert_eq!(
        paths,
        vec![
            "/m/old1.flac",
            "/m/old2.flac",
            "/m/new1.flac",
            "/m/new2.flac",
        ]
    );
}

#[test]
fn track_paths_for_artist_is_one_per_track() {
    // A track with two files must contribute one MIN(path), like file_paths_for_album.
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('art', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'art', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1, 'rel', 1, 1, 'T1')",
        [],
    )
    .unwrap();
    for (path, tid) in [("/m/a1.flac", 1), ("/m/a1.m4a", 1)] {
        conn.execute(
            "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES (?1, 0, 0, ?2, 0)",
            rusqlite::params![path, tid],
        )
        .unwrap();
    }
    let paths = track_paths_for_artist(&conn, "art").unwrap();
    assert_eq!(paths, vec!["/m/a1.flac"]);
}
```

- [ ] **Step 2: Run it — expect failure.** `cd /home/autarch/projects/olivier/rust && cargo test track_paths_for_artist`. Expected: compile error `cannot find function track_paths_for_artist in this scope`.

- [ ] **Step 3: Implement the query.** Append to `rust/src/catalog/query.rs`. The album ordering clause matches `albums_for_artist` so artist-enqueue order matches the album browse order; tracks within an album go by disc/position; one `MIN(f.path)` per track.

```rust
/// One absolute file path per track for every release by one album-artist, in the
/// album browse order (original-year then title, case-insensitive — matching
/// `albums_for_artist`) and within each album by disc then position. One path per
/// track (`MIN(path)`), so an artist enqueue lines up with the displayed albums.
pub fn track_paths_for_artist(
    conn: &Connection,
    album_artist_mbid: &str,
) -> anyhow::Result<Vec<String>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT MIN(f.path)
         FROM release r
         JOIN track t ON t.release_mbid = r.mbid
         JOIN file f ON f.track_id = t.id
         LEFT JOIN release_group rg ON rg.mbid = r.release_group_mbid
         WHERE r.album_artist_mbid = ?1
         GROUP BY t.id
         ORDER BY COALESCE(rg.first_release_date, r.date, '9999'),
                  r.title COLLATE NOCASE, t.disc, t.position",
    )?;
    let rows = stmt.query_map([album_artist_mbid], |r| r.get::<_, String>(0))?;
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}
```

- [ ] **Step 4: Add the FFI wrapper.** Append to `rust/src/api/catalog.rs`:

```rust
pub fn track_paths_for_artist(
    db_path: String,
    album_artist_mbid: String,
) -> anyhow::Result<Vec<String>> {
    query::track_paths_for_artist(&db::open(&db_path)?, &album_artist_mbid)
}
```

- [ ] **Step 5: Run it — expect pass.** `cd /home/autarch/projects/olivier/rust && cargo test track_paths_for_artist`. Expected: both new tests pass.

- [ ] **Step 6: Regenerate the bridge** (api signature changed): `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`. Confirm `trackPathsForArtist` now exists: `grep -n "trackPathsForArtist" /home/autarch/projects/olivier/lib/src/rust/api/catalog.dart`.

- [ ] **Step 7: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`.

- [ ] **Step 8: Commit.** `cd /home/autarch/projects/olivier && git add rust/src/catalog/query.rs rust/src/api/catalog.rs rust/tests/catalog_test.rs rust/src/frb_generated.rs lib/src/rust && git commit -m "Add track_paths_for_artist FFI for artist enqueue"`

---

### Task 15: FFI `track_paths_for_library` (Rust query + api + bridge)

**Files:**
- Modify: `/home/autarch/projects/olivier/rust/src/catalog/query.rs`
- Modify: `/home/autarch/projects/olivier/rust/src/api/catalog.rs`
- Test: `/home/autarch/projects/olivier/rust/tests/catalog_test.rs`
- Modify (generated): `/home/autarch/projects/olivier/lib/src/rust/**`, `/home/autarch/projects/olivier/rust/src/frb_generated.rs`

- [ ] **Step 1: Write the failing test first.** Add to `rust/tests/catalog_test.rs` (add `track_paths_for_library` to the `use rust_lib_olivier::catalog::query::{…}` import). It asserts full coverage (one path per track across two artists) and that a multi-file track contributes exactly one path. Order is deterministic but asserted as a sorted set.

```rust
#[test]
fn track_paths_for_library_covers_every_track_one_per_track() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('a1', 'A1', 'A1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('a2', 'A2', 'A2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r1', 'a1', 'Alb1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r2', 'a2', 'Alb2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1, 'r1', 1, 1, 'T1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2, 'r2', 1, 1, 'T2')",
        [],
    )
    .unwrap();
    // Track 1 has two files; it must still contribute exactly one path.
    for (path, tid) in [("/m/a.flac", 1), ("/m/a.m4a", 1), ("/m/b.flac", 2)] {
        conn.execute(
            "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES (?1, 0, 0, ?2, 0)",
            rusqlite::params![path, tid],
        )
        .unwrap();
    }

    let mut paths = track_paths_for_library(&conn).unwrap();
    paths.sort();
    assert_eq!(paths, vec!["/m/a.flac", "/m/b.flac"]);

    // Empty library → empty result.
    let empty = open(":memory:").unwrap();
    assert!(track_paths_for_library(&empty).unwrap().is_empty());
}
```

- [ ] **Step 2: Run it — expect failure.** `cd /home/autarch/projects/olivier/rust && cargo test track_paths_for_library`. Expected: compile error `cannot find function track_paths_for_library in this scope`.

- [ ] **Step 3: Implement the query.** Append to `rust/src/catalog/query.rs`. Deterministic order: by track id (simplest stable key; the queue is shuffled afterward anyway).

```rust
/// One absolute file path per track for the entire catalog, in a deterministic
/// order (by track id). Used by "Shuffle entire library", which shuffles the
/// playback order afterward, so the on-disk order only needs to be stable, not
/// musically meaningful. One path per track (`MIN(path)`).
pub fn track_paths_for_library(conn: &Connection) -> anyhow::Result<Vec<String>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT MIN(f.path) FROM track t JOIN file f ON f.track_id = t.id
         GROUP BY t.id ORDER BY t.id",
    )?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}
```

- [ ] **Step 4: Add the FFI wrapper.** Append to `rust/src/api/catalog.rs`:

```rust
pub fn track_paths_for_library(db_path: String) -> anyhow::Result<Vec<String>> {
    query::track_paths_for_library(&db::open(&db_path)?)
}
```

- [ ] **Step 5: Run it — expect pass.** `cd /home/autarch/projects/olivier/rust && cargo test track_paths_for_library`. Expected: pass.

- [ ] **Step 6: Regenerate the bridge.** `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`. Confirm: `grep -n "trackPathsForLibrary" /home/autarch/projects/olivier/lib/src/rust/api/catalog.dart`.

- [ ] **Step 7: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`.

- [ ] **Step 8: Commit.** `cd /home/autarch/projects/olivier && git add rust/src/catalog/query.rs rust/src/api/catalog.rs rust/tests/catalog_test.rs rust/src/frb_generated.rs lib/src/rust && git commit -m "Add track_paths_for_library FFI for Shuffle entire library"`

---

### Task 16: Entity ref + path resolver (shared by menu, double-click, drag)

**Files:**
- Create: `/home/autarch/projects/olivier/lib/audio/queue_entity.dart`
- Modify: `/home/autarch/projects/olivier/lib/state/providers.dart`
- Test: `/home/autarch/projects/olivier/test/queue_entity_test.dart`

- [ ] **Step 1: Write the failing resolver test first.** Create `test/queue_entity_test.dart`. It supplies the three FFI fns via `EntityPathFns` and asserts each entity kind resolves to the right paths via `resolveEntityPaths`.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';

void main() {
  final fns = EntityPathFns(
    artistPaths: (mbid) async => ['/m/$mbid-1', '/m/$mbid-2'],
    albumPaths: (releaseMbid) async => ['/m/$releaseMbid-a'],
    trackPath: (id) async => id == 7 ? '/m/track7' : null,
  );

  test('artist entity resolves via artistPaths', () async {
    final paths = await resolveEntityPaths(
      const QueueEntityRef.artist('art1'),
      fns,
    );
    expect(paths, ['/m/art1-1', '/m/art1-2']);
  });

  test('album entity resolves via albumPaths', () async {
    final paths = await resolveEntityPaths(
      const QueueEntityRef.album('rel1'),
      fns,
    );
    expect(paths, ['/m/rel1-a']);
  });

  test('track entity resolves via trackPath; missing → empty', () async {
    expect(
      await resolveEntityPaths(const QueueEntityRef.track(7), fns),
      ['/m/track7'],
    );
    expect(
      await resolveEntityPaths(const QueueEntityRef.track(99), fns),
      isEmpty,
    );
  });
}
```

- [ ] **Step 2: Run it — expect failure.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_entity_test.dart`. Expected: `Target of URI doesn't exist: 'package:olivier/audio/queue_entity.dart'`.

- [ ] **Step 3: Implement the entity ref and resolver.** Create `lib/audio/queue_entity.dart`.

```dart
import 'package:flutter/foundation.dart';

/// A draggable / right-clickable reference to a browse entity that can be
/// resolved to a list of track file paths and appended to the queue.
@immutable
sealed class QueueEntityRef {
  const QueueEntityRef();
  const factory QueueEntityRef.artist(String albumArtistMbid) = ArtistEntity;
  const factory QueueEntityRef.album(String releaseMbid) = AlbumEntity;
  const factory QueueEntityRef.track(int trackId) = TrackEntity;
}

class ArtistEntity extends QueueEntityRef {
  const ArtistEntity(this.albumArtistMbid);
  final String albumArtistMbid;
}

class AlbumEntity extends QueueEntityRef {
  const AlbumEntity(this.releaseMbid);
  final String releaseMbid;
}

class TrackEntity extends QueueEntityRef {
  const TrackEntity(this.trackId);
  final int trackId;
}

/// The FFI seams needed to turn an entity into paths. Bundled so widget tests
/// can supply fakes without touching the real bridge.
class EntityPathFns {
  const EntityPathFns({
    required this.artistPaths,
    required this.albumPaths,
    required this.trackPath,
  });

  final Future<List<String>> Function(String albumArtistMbid) artistPaths;
  final Future<List<String>> Function(String releaseMbid) albumPaths;
  final Future<String?> Function(int trackId) trackPath;
}

/// Resolve one entity to the ordered list of file paths it contributes.
Future<List<String>> resolveEntityPaths(
  QueueEntityRef entity,
  EntityPathFns fns,
) async {
  switch (entity) {
    case ArtistEntity(:final albumArtistMbid):
      return fns.artistPaths(albumArtistMbid);
    case AlbumEntity(:final releaseMbid):
      return fns.albumPaths(releaseMbid);
    case TrackEntity(:final trackId):
      final p = await fns.trackPath(trackId);
      return p == null ? <String>[] : <String>[p];
  }
}
```

- [ ] **Step 4: Run it — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_entity_test.dart`. Expected: 3 tests pass.

- [ ] **Step 5: Add the Riverpod seam providers.** Append to `lib/state/providers.dart`. Add `import 'package:olivier/audio/queue_entity.dart';` at the top; `trackPathsForArtist`, `albumFilePaths`, `trackPath`, `trackPathsForLibrary` are all in scope from the existing `package:olivier/src/rust/api/catalog.dart` import after regen.

```dart
// --- Entity → paths FFI seams (overridable in tests) ---

final entityPathFnsProvider = Provider<EntityPathFns>((ref) {
  final db = ref.watch(dbPathProvider);
  return EntityPathFns(
    artistPaths: (mbid) =>
        trackPathsForArtist(dbPath: db, albumArtistMbid: mbid),
    albumPaths: (releaseMbid) =>
        albumFilePaths(dbPath: db, releaseMbid: releaseMbid),
    trackPath: (id) => trackPath(dbPath: db, trackId: id),
  );
});

/// The whole-library paths seam used by "Shuffle entire library".
typedef LibraryPathsFn = Future<List<String>> Function();

final libraryPathsFnProvider = Provider<LibraryPathsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return () => trackPathsForLibrary(dbPath: db);
});
```

- [ ] **Step 6: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`.

- [ ] **Step 7: Commit.** `cd /home/autarch/projects/olivier && git add lib/audio/queue_entity.dart lib/state/providers.dart test/queue_entity_test.dart && git commit -m "Add QueueEntityRef + path-resolution seams for enqueue"`

---

### Task 17: Reusable right-click "Add to queue" context menu + double-click artist

**Files:**
- Create: `/home/autarch/projects/olivier/lib/widgets/context_menu.dart`
- Modify: `/home/autarch/projects/olivier/lib/catalog/artist_column.dart`
- Modify: `/home/autarch/projects/olivier/lib/catalog/album_column.dart`
- Modify: `/home/autarch/projects/olivier/lib/catalog/track_column.dart`
- Test: `/home/autarch/projects/olivier/test/context_menu_test.dart`

- [ ] **Step 1: Write the failing widget test first.** Create `test/context_menu_test.dart`. It wraps a single row in the menu helper, right-clicks (secondary tap) it, taps "Add to queue", and asserts the callback fires with the entity.

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/widgets/context_menu.dart';

void main() {
  testWidgets('right-click shows "Add to queue" and fires callback',
      (tester) async {
    QueueEntityRef? added;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AddToQueueMenu(
          entity: const QueueEntityRef.album('rel-1'),
          onAddToQueue: (e) => added = e,
          child: const SizedBox(width: 200, height: 40, child: Text('row')),
        ),
      ),
    ));

    // Secondary (right) tap opens the menu.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Add to queue'), findsOneWidget);
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(added, isA<AlbumEntity>());
    expect((added! as AlbumEntity).releaseMbid, 'rel-1');
  });
}
```

- [ ] **Step 2: Run it — expect failure.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/context_menu_test.dart`. Expected: `Target of URI doesn't exist: 'package:olivier/widgets/context_menu.dart'`.

- [ ] **Step 3: Implement the menu helper.** Create `lib/widgets/context_menu.dart`. Uses `onSecondaryTapDown` to capture the pointer position and `showMenu`; the single entry calls back with the entity.

```dart
import 'package:flutter/material.dart';
import 'package:olivier/audio/queue_entity.dart';

/// Wraps [child] so a right-click (secondary tap) opens a context menu with an
/// "Add to queue" entry for [entity]. Other menu entries (re-read tags, info,
/// per-entity re-fetch) are separate backlog items that add to the same menu.
class AddToQueueMenu extends StatelessWidget {
  const AddToQueueMenu({
    super.key,
    required this.entity,
    required this.onAddToQueue,
    required this.child,
  });

  final QueueEntityRef entity;
  final ValueChanged<QueueEntityRef> onAddToQueue;
  final Widget child;

  Future<void> _show(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'add',
          child: Text('Add to queue'),
        ),
      ],
    );
    if (selected == 'add') onAddToQueue(entity);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) => _show(context, d.globalPosition),
      child: child,
    );
  }
}
```

- [ ] **Step 4: Run it — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/context_menu_test.dart`. Expected: pass.

- [ ] **Step 5: Add the shared `_enqueue` helper + wire the artist column.** In `lib/catalog/artist_column.dart`, add imports and wrap the row in `AddToQueueMenu` + add a double-tap that appends the artist. Add imports at the top:

```dart
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/context_menu.dart';
```

  Add this top-level helper (it resolves via the seam and appends through the concrete controller):

```dart
Future<void> _enqueue(WidgetRef ref, QueueEntityRef entity) async {
  final paths = await resolveEntityPaths(
    entity,
    ref.read(entityPathFnsProvider),
  );
  if (paths.isEmpty) return;
  await ref.read(playbackControllerProvider).queueController.append(paths);
}
```

  Replace the `InkWell(...)` returned in `itemBuilder` with:

```dart
        final entity = QueueEntityRef.artist(artist.mbid);
        return AddToQueueMenu(
          entity: entity,
          onAddToQueue: (e) => _enqueue(ref, e),
          child: InkWell(
            key: ValueKey(artist.mbid),
            onTap: () =>
                ref.read(selectedArtistProvider.notifier).select(artist.mbid),
            onDoubleTap: () => _enqueue(ref, entity),
            child: Container(
              color: isSelected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: BilingualText(
                original: artist.nameOriginal ?? artist.name,
                translit: artist.transliteration,
                translate: null, // names get a reading only (spec §6)
                leads: leads,
              ),
            ),
          ),
        );
```

- [ ] **Step 6: Wire the menu into the album column.** In `lib/catalog/album_column.dart`, wrap the row in `AddToQueueMenu` for `QueueEntityRef.album(album.releaseMbid)`. (Slice 2 already removed the play `IconButton` and added the album double-tap append; this adds only the right-click menu.) Add the same top-level `_enqueue` helper and add imports `package:olivier/audio/queue_entity.dart`, `package:olivier/widgets/context_menu.dart` (and the already-present `playback_controller.dart`):

```dart
        final entity = QueueEntityRef.album(album.releaseMbid);
        return AddToQueueMenu(
          entity: entity,
          onAddToQueue: (e) => _enqueue(ref, e),
          child: InkWell(
            key: ValueKey(album.releaseMbid),
            // ... existing onTap / onDoubleTap / Container child unchanged ...
          ),
        );
```

- [ ] **Step 7: Wire the menu into the track column.** In `lib/catalog/track_column.dart`, wrap the row in `AddToQueueMenu` for `QueueEntityRef.track(track.id)`, add imports `package:olivier/audio/queue_entity.dart`, `package:olivier/widgets/context_menu.dart`, `package:olivier/audio/playback_controller.dart`, and the top-level `_enqueue` helper:

```dart
        final entity = QueueEntityRef.track(track.id);
        return AddToQueueMenu(
          entity: entity,
          onAddToQueue: (e) => _enqueue(ref, e),
          child: InkWell(
            key: ValueKey(track.id),
            // ... existing selection onTap / onDoubleTap / Container child unchanged ...
          ),
        );
```

- [ ] **Step 8: Run the column tests — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/catalog_text_scale_test.dart test/context_menu_test.dart test/track_column_select_test.dart test/album_column_enqueue_test.dart`. Expected: pass (wrapping in `AddToQueueMenu` must not introduce overflow or break existing text-scale/selection assertions).

- [ ] **Step 9: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`.

- [ ] **Step 10: Commit.** `cd /home/autarch/projects/olivier && git add lib/widgets/context_menu.dart lib/catalog/artist_column.dart lib/catalog/album_column.dart lib/catalog/track_column.dart test/context_menu_test.dart && git commit -m "Add 'Add to queue' context menu + double-click artist enqueue"`

---

### Task 18: Drag rows onto the queue panel (DragTarget enqueue)

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/catalog/artist_column.dart`
- Modify: `/home/autarch/projects/olivier/lib/catalog/album_column.dart`
- Modify: `/home/autarch/projects/olivier/lib/catalog/track_column.dart`
- Modify: `/home/autarch/projects/olivier/lib/catalog/queue_panel.dart`
- Test: `/home/autarch/projects/olivier/test/queue_drag_test.dart`

- [ ] **Step 1: Write the failing drag test first.** Create `test/queue_drag_test.dart`. It builds a `LongPressDraggable<QueueEntityRef>` source and the real `QueuePanelDropTarget` (extracted into `queue_panel.dart`), performs a long-press drag, and asserts the dropped entity is resolved + appended.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/queue_panel.dart';

void main() {
  testWidgets('drag an entity onto the target appends its paths',
      (tester) async {
    final dropped = <String>[];
    final fns = EntityPathFns(
      artistPaths: (mbid) async => ['/m/$mbid-1', '/m/$mbid-2'],
      albumPaths: (r) async => ['/m/$r'],
      trackPath: (id) async => '/m/$id',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            LongPressDraggable<QueueEntityRef>(
              data: const QueueEntityRef.artist('art1'),
              feedback: const Text('drag'),
              child: const SizedBox(width: 100, height: 40, child: Text('src')),
            ),
            QueuePanelDropTarget(
              onEntityDropped: (e) async =>
                  dropped.addAll(await resolveEntityPaths(e, fns)),
              child: const SizedBox(
                  width: 200, height: 80, child: Text('queue')),
            ),
          ],
        ),
      ),
    ));

    final src = tester.getCenter(find.text('src'));
    final dst = tester.getCenter(find.text('queue'));
    final g = await tester.startGesture(src);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await g.moveTo(dst);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(dropped, ['/m/art1-1', '/m/art1-2']);
  });
}
```

- [ ] **Step 2: Run it — expect failure.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_drag_test.dart`. Expected: undefined `QueuePanelDropTarget`.

- [ ] **Step 3: Implement the drop target widget.** Add to `lib/catalog/queue_panel.dart` (add `import 'package:olivier/audio/queue_entity.dart';`). It wraps the panel body in a `DragTarget<QueueEntityRef>` that highlights on hover and calls back on drop:

```dart
/// Wraps the queue panel so a dragged browse entity dropped onto it is resolved
/// and appended. Used around both the collapsed header and the expanded list.
class QueuePanelDropTarget extends StatelessWidget {
  const QueuePanelDropTarget({
    super.key,
    required this.onEntityDropped,
    required this.child,
  });

  final ValueChanged<QueueEntityRef> onEntityDropped;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<QueueEntityRef>(
      onAcceptWithDetails: (d) => onEntityDropped(d.data),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Container(
          decoration: hovering
              ? BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                )
              : null,
          child: child,
        );
      },
    );
  }
}
```

  In `QueuePanel.build`, wrap the outer panel widget (the `Material`/`Column` from Slice 3) in `QueuePanelDropTarget`, resolving + appending through the concrete controller:

```dart
    return QueuePanelDropTarget(
      onEntityDropped: (entity) async {
        final paths = await resolveEntityPaths(
          entity,
          ref.read(entityPathFnsProvider),
        );
        if (paths.isEmpty) return;
        await ref.read(playbackControllerProvider).queueController.append(paths);
      },
      child: /* existing collapsible panel widget from slice 3 */,
    );
```

  Add `import 'package:olivier/state/providers.dart';` (for `entityPathFnsProvider`) and ensure `package:olivier/audio/playback_controller.dart` is imported (already present from Slice 3 for `queueControllerProvider`).

- [ ] **Step 4: Make the browse rows draggable.** In each of `artist_column.dart`, `album_column.dart`, `track_column.dart`, wrap the existing `AddToQueueMenu(...)` return in a `LongPressDraggable<QueueEntityRef>` carrying the same entity. For the artist column:

```dart
        final entity = QueueEntityRef.artist(artist.mbid);
        return LongPressDraggable<QueueEntityRef>(
          data: entity,
          feedback: Material(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(artist.nameOriginal ?? artist.name),
            ),
          ),
          child: AddToQueueMenu(
            entity: entity,
            onAddToQueue: (e) => _enqueue(ref, e),
            child: /* existing InkWell ... */,
          ),
        );
```

  Do the same for the album row (`feedback` shows `album.title`, data `QueueEntityRef.album(album.releaseMbid)`) and the track row (`feedback` shows `track.title`, data `QueueEntityRef.track(track.id)`).

  > **Decision:** `LongPressDraggable` (not plain `Draggable`) is used so it does not fight the rows' `onTap`/`onDoubleTap`/scroll gestures — consistent with the spec's "Draggable/LongPressDraggable" wording.

- [ ] **Step 5: Run it — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_drag_test.dart`. Expected: pass.

- [ ] **Step 6: Run the broader column/panel tests.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/catalog_text_scale_test.dart test/context_menu_test.dart test/queue_drag_test.dart test/queue_panel_test.dart`. Expected: all pass (draggable wrapping must not reintroduce overflow).

- [ ] **Step 7: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`.

- [ ] **Step 8: Commit.** `cd /home/autarch/projects/olivier && git add lib/catalog/artist_column.dart lib/catalog/album_column.dart lib/catalog/track_column.dart lib/catalog/queue_panel.dart test/queue_drag_test.dart && git commit -m "Add drag-browse-rows-onto-queue-panel enqueue"`

---

### Task 19: "Shuffle entire library" header control (replace + shuffle + confirm)

**Files:**
- Modify: `/home/autarch/projects/olivier/lib/catalog/queue_panel.dart`
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart`
- Test: `/home/autarch/projects/olivier/test/shuffle_library_test.dart`

> **Decision:** rather than spin up a real `AudioPlayer`, this test exercises the dialog/seam logic by extracting the action into a top-level `shuffleEntireLibrary(BuildContext, WidgetRef)` and asserting via a recording fake injected through a narrow `ShuffleAllTarget` interface. `ShuffleAllTarget` is declared in `lib/audio/queue_controller.dart` (keeps `audio/` free of `catalog/` imports); `QueueController implements ShuffleAllTarget` — its `replaceLibraryShuffled` (added in Task 20, but its signature is fixed here) already matches. A fake records `replaceLibraryShuffled(paths)`.
>
> **Reconciliation:** `replaceLibraryShuffled` is the contract's only replace method. It is **implemented in Slice 5 (Task 24)** as `await setQueue(paths); await setShuffle(true); _player.play();`. This task wires the UI + interface + provider; if `replaceLibraryShuffled` does not yet exist on `QueueController` when this task runs, add the method here with that body (it composes already-existing `setQueue`/`setShuffle`).

- [ ] **Step 1: Write the failing widget test first.** Create `test/shuffle_library_test.dart`. Two cases: (a) empty queue → tapping the control replaces+shuffles immediately (no dialog); (b) non-empty queue → a confirm dialog showing the count appears, and confirming triggers `replaceLibraryShuffled` with the library paths.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

class _FakeController implements ShuffleAllTarget {
  List<String>? replaced;
  @override
  Future<void> replaceLibraryShuffled(List<String> paths) async {
    replaced = paths;
  }
}

class _FakeQueueNotifier extends QueueNotifier {
  _FakeQueueNotifier(this._count);
  final int _count;
  @override
  Future<QueueView> build() async => QueueView(
        tracks: [
          for (var i = 0; i < _count; i++)
            QueueTrack(path: '/q/$i', title: 'T$i', album: 'A'),
        ],
        currentIndex: _count == 0 ? null : 0,
        shuffled: false,
      );
}

Widget _host(_FakeController fake, {required int queueCount}) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      libraryPathsFnProvider.overrideWithValue(
        () async => ['/m/1', '/m/2', '/m/3'],
      ),
      shuffleAllTargetProvider.overrideWithValue(fake),
      queueProvider.overrideWith(() => _FakeQueueNotifier(queueCount)),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  );
}

void main() {
  testWidgets('empty queue: Shuffle all replaces immediately, no dialog',
      (tester) async {
    final fake = _FakeController();
    await tester.pumpWidget(_host(fake, queueCount: 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Shuffle entire library'));
    await tester.pumpAndSettle();

    expect(find.text('Shuffle entire library?'), findsNothing);
    expect(fake.replaced, ['/m/1', '/m/2', '/m/3']);
  });

  testWidgets('non-empty queue: confirm dialog shows count, confirm replaces',
      (tester) async {
    final fake = _FakeController();
    await tester.pumpWidget(_host(fake, queueCount: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Shuffle entire library'));
    await tester.pumpAndSettle();

    // Dialog states the count of library tracks that will replace the queue.
    expect(find.textContaining('3 tracks'), findsOneWidget);
    expect(fake.replaced, isNull);

    await tester.tap(find.text('Shuffle'));
    await tester.pumpAndSettle();
    expect(fake.replaced, ['/m/1', '/m/2', '/m/3']);
  });
}
```

- [ ] **Step 2: Run it — expect failure.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/shuffle_library_test.dart`. Expected: undefined `ShuffleAllTarget`, `shuffleAllTargetProvider`, and `find.byTooltip('Shuffle entire library')` finds nothing wired.

- [ ] **Step 3: Add the seam interface + the `replaceLibraryShuffled` method.** In `lib/audio/queue_controller.dart`, add the interface and make the controller implement it:

```dart
/// The single method "Shuffle entire library" needs from the queue controller.
/// Narrowed to an interface so the action is unit-testable with a fake.
abstract interface class ShuffleAllTarget {
  Future<void> replaceLibraryShuffled(List<String> paths);
}
```

  Change the class declaration to implement it: `class QueueController implements ShuffleAllTarget {`. Add the method (the contract's only replace):

```dart
  /// The ONE queue-replacing action: replace the queue with [paths], turn
  /// shuffle on, and start playing. Used by "Shuffle entire library".
  Future<void> replaceLibraryShuffled(List<String> paths) async {
    await setQueue(paths);
    await setShuffle(true);
    await _player.play();
  }
```

  In `lib/catalog/queue_panel.dart`, add the provider (defaults to the real controller):

```dart
final shuffleAllTargetProvider = Provider<ShuffleAllTarget>((ref) {
  return ref.read(playbackControllerProvider).queueController;
});
```

  Ensure `queue_panel.dart` imports `package:olivier/audio/queue_controller.dart` (for `ShuffleAllTarget`) and `package:olivier/state/providers.dart` (for `libraryPathsFnProvider`).

- [ ] **Step 4: Implement the action + header control.** In `lib/catalog/queue_panel.dart`, add the action function; the dialog appears only when the queue is non-empty:

```dart
Future<void> shuffleEntireLibrary(BuildContext context, WidgetRef ref) async {
  final paths = await ref.read(libraryPathsFnProvider)();
  if (paths.isEmpty) return;

  final queueIsEmpty =
      ref.read(queueProvider).valueOrNull?.tracks.isEmpty ?? true;
  if (!queueIsEmpty) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Shuffle entire library?'),
        content: Text(
          'This replaces the current queue with ${paths.length} tracks '
          'and shuffles playback.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Shuffle'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }

  await ref.read(shuffleAllTargetProvider).replaceLibraryShuffled(paths);
}
```

  Wire the header "Shuffle entire library" placeholder control (from Slice 3's header) to call it:

```dart
            IconButton(
              icon: const Icon(Icons.shuffle_on_outlined),
              tooltip: 'Shuffle entire library',
              onPressed: () => shuffleEntireLibrary(context, ref),
            ),
```

- [ ] **Step 5: Run it — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/shuffle_library_test.dart`. Expected: both cases pass.

- [ ] **Step 6: Run the whole Dart suite.** `cd /home/autarch/projects/olivier && mise exec -- flutter test`. Expected: all tests pass.

- [ ] **Step 7: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`.

- [ ] **Step 8: Build check.** `cd /home/autarch/projects/olivier && mise exec -- flutter build linux --debug`. Expected: build succeeds.

- [ ] **Step 9: Commit.** `cd /home/autarch/projects/olivier && git add lib/catalog/queue_panel.dart lib/audio/queue_controller.dart test/shuffle_library_test.dart && git commit -m "Add 'Shuffle entire library' control with non-empty confirm dialog"`

---

**Slice 4 deliverable:** Every browse entity can be appended three ways — right-click → "Add to queue", double-click (artist joins album/track for a uniform double-click rule), and long-press-drag onto the queue panel — each resolving artist → `track_paths_for_artist`, album → `album_file_paths`, track → `track_path` and calling `QueueController.append` without interrupting playback; the queue panel header's "Shuffle entire library" replaces the queue with all library tracks (`track_paths_for_library`), enables shuffle, and starts playback, prompting a count-bearing confirm dialog only when the queue is non-empty.

---

## Slice 5 — Shuffle toggle

> **Builds on Slices 2–4:** `QueueController` has `append`/`removeAt`/`playAt`/`reorder`/`clear`/`replaceLibraryShuffled` and `revision`; `queueProvider`/`QueueView`/`QueueNotifier` and `queueControllerProvider`; the queue-panel header with the Shuffle placeholder. This slice generalizes the shuffled-order math (canonical ↔ player index, duplicate-aware), wires the header Shuffle toggle, and proves the behavior.
>
> **Reconciliation note:** the seam is the `QueuePlayer` port — so the shared `test/support/fake_queue_player.dart` (created in Task 5) is `FakeQueuePlayer implements QueuePlayer`, every shuffle test imports it, the controller is built via `QueueController.withPlayer(fake, …)`, and the notifier uses `controller.currentCanonicalIndex` (the contract getter, already added in Slice 2) rather than reaching into the player. `_persist`/`saveQueue` is asserted against a temp on-disk db via `dbPath`.

### Task 20: Confirm the shared `FakeQueuePlayer` records the shuffle-relevant ops

**Files:**
- (Verify only) `/home/autarch/projects/olivier/test/support/fake_queue_player.dart`

> The single shared `FakeQueuePlayer implements QueuePlayer` was already created in **Task 5** at `test/support/fake_queue_player.dart` with the full recording surface the shuffle tests need — `sources` (the mirrored source order), `removedIndexes` (every `removeAudioSourceAt`), `seeks` (every `seek`), `played`, a settable `currentIndex` via `setCurrentIndex(...)`, and a broadcast `currentIndexStream`. This task does **not** re-create the file; it only confirms that surface is present (and extends it if some shuffle-specific recording is somehow still missing) before the shuffle tasks import it.

- [ ] **Step 1: Verify the shared fake already exposes what the shuffle tests need.** Confirm `test/support/fake_queue_player.dart` (from Task 5) declares the single `FakeQueuePlayer` test double and exposes `sources`, `removedIndexes`, `seeks`, `played`, `setCurrentIndex(int?)`, and a real `currentIndexStream` (a `StreamController.broadcast()`). It does (see Task 5, Step 2a). If any of these are missing, add them here — but do NOT declare a second `FakeQueuePlayer` anywhere.

- [ ] **Step 2: Lint the support file.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all` — expect a clean pass (no analyzer errors in `test/support/`).

- [ ] **Step 3: No commit needed.** The shared fake was committed in Task 5; this task adds no new file. (Commit only if Step 1 found a genuinely missing record and you extended the file: `cd /home/autarch/projects/olivier && git add test/support/fake_queue_player.dart && git commit -m "Extend shared FakeQueuePlayer with missing shuffle recording"`.)

---

### Task 21: Generalize `removeAt` for the shuffled case (canonical↔player index, duplicate-aware)

**Files:**
- Test: `/home/autarch/projects/olivier/test/audio/queue_controller_shuffle_test.dart` (Create)
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart`

- [ ] **Step 1: Write the failing test (removeAt while shuffled).** Create `test/audio/queue_controller_shuffle_test.dart`. It seeds a real on-disk db so `_persist`/`saveQueue` works, drives shuffle, reads `controller.playOrder` to learn the actual shuffled order, then asserts `removeAt` removed the right canonical entry AND the right player source.

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/queue.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:path/path.dart' as p;

import '../support/fake_queue_player.dart';

void main() {
  setUpAll(() async => RustLib.init());

  late Directory tmp;
  late String dbPath;
  late FakeQueuePlayer player;
  late QueueController controller;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('olivier_queue_shuffle');
    dbPath = p.join(tmp.path, 'test.db');
    player = FakeQueuePlayer();
    controller = QueueController.withPlayer(player, dbPath: dbPath);
    await controller.setQueue(['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
  });

  tearDown(() async => tmp.delete(recursive: true));

  test('removeAt while shuffled removes the right canonical entry AND the '
      'right player source', () async {
    await controller.setShuffle(true);
    final shuffled = controller.playOrder;
    expect(player.sources, shuffled);

    const removedPath = '/b.flac';
    final expectedPlayerIndex = shuffled.indexOf(removedPath);

    await controller.removeAt(1); // canonical index 1 == '/b.flac'

    expect(controller.orderedPaths, ['/a.flac', '/c.flac', '/d.flac']);
    expect(player.removedIndexes, [expectedPlayerIndex]);
    expect(player.sources.contains(removedPath), isFalse);
    expect(player.sources.length, 3);
    expect(controller.playOrder.contains(removedPath), isFalse);

    final snap = await loadQueue(dbPath: dbPath);
    expect(snap!.paths, ['/a.flac', '/c.flac', '/d.flac']);
    expect(snap.shuffle, isTrue);
  });
}
```

- [ ] **Step 2: Run it — expect failure.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/audio/queue_controller_shuffle_test.dart`. Expected failure: the Slice-3 `removeAt` shuffled branch uses `_playOrder.indexOf(path)` (first match) and is not occurrence-aware; assert against `player.removedIndexes == [expectedPlayerIndex]` may still pass for unique paths, but the duplicate-aware refactor below makes the single code path correct. (If it already passes for this unique-path case, note it and proceed to wire the occurrence-aware version for the duplicate guarantee.)

- [ ] **Step 3: Implement the occurrence-aware `removeAt` (covers shuffled + duplicates).** In `lib/audio/queue_controller.dart`, replace the Slice-3 `removeAt` with a single implementation. A path can be queued more than once (spec §3); map by occurrence so the correct duplicate is removed:

```dart
  /// Remove the entry at [index] in the DISPLAYED canonical order
  /// (_orderedPaths), keeping playback uninterrupted. When not shuffled the
  /// player source index equals the canonical index; when shuffled we translate
  /// through _playOrder. Occurrence-aware so duplicate paths are handled.
  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _orderedPaths.length) return;
    final playerIndex = _playerIndexForCanonical(index);
    final path = _orderedPaths.removeAt(index);
    if (playerIndex >= 0 && playerIndex < _playOrder.length) {
      _playOrder.removeAt(playerIndex);
      await _player.removeAudioSourceAt(playerIndex);
    }
    assert(path.isNotEmpty);
    await _persist();
    revision.value++;
  }

  /// Maps a canonical _orderedPaths index to the matching player source index in
  /// _playOrder, accounting for the same path appearing multiple times. Returns
  /// the same index when not shuffled (orders are in sync).
  int _playerIndexForCanonical(int index) {
    final path = _orderedPaths[index];
    var occurrence = 0;
    for (var i = 0; i < index; i++) {
      if (_orderedPaths[i] == path) occurrence++;
    }
    var seen = 0;
    for (var i = 0; i < _playOrder.length; i++) {
      if (_playOrder[i] == path) {
        if (seen == occurrence) return i;
        seen++;
      }
    }
    return index; // fallback: orders are in sync
  }
```

- [ ] **Step 4: Run it — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/audio/queue_controller_shuffle_test.dart`. Expected: the removeAt test passes.

- [ ] **Step 5: Re-run the not-shuffled ops test** to confirm no regression: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_controller_ops_test.dart`. Expected: still green (not-shuffled `_playerIndexForCanonical` returns `index`).

- [ ] **Step 6: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all` — clean.

- [ ] **Step 7: Commit.** `cd /home/autarch/projects/olivier && git add lib/audio/queue_controller.dart test/audio/queue_controller_shuffle_test.dart && git commit -m "Make QueueController.removeAt shuffle- and duplicate-aware"`

---

### Task 22: Generalize `playAt` and `append` for the shuffled case

**Files:**
- Test: `/home/autarch/projects/olivier/test/audio/queue_controller_shuffle_test.dart` (Modify)
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart`

- [ ] **Step 1: Add failing tests (playAt + append while shuffled).** Append two tests to `test/audio/queue_controller_shuffle_test.dart`:

```dart
  test('playAt while shuffled jumps to the right track via _playOrder',
      () async {
    await controller.setShuffle(true);
    final shuffled = controller.playOrder;

    const targetPath = '/c.flac';
    final expectedPlayerIndex = shuffled.indexOf(targetPath);

    await controller.playAt(2); // canonical index 2 == '/c.flac'

    expect(player.seeks.length, 1);
    expect(player.seeks.single.position, Duration.zero);
    expect(player.seeks.single.index, expectedPlayerIndex);
    expect(player.played, isTrue);
  });

  test('append while shuffled adds to canonical end AND the player end',
      () async {
    await controller.setShuffle(true);
    final before = controller.playOrder.length;

    await controller.append(['/e.flac']);

    expect(controller.orderedPaths.last, '/e.flac');
    expect(controller.playOrder.length, before + 1);
    expect(controller.playOrder.last, '/e.flac');
    expect(player.sources.last, '/e.flac');

    final snap = await loadQueue(dbPath: dbPath);
    expect(snap!.paths.last, '/e.flac');
    expect(snap.shuffle, isTrue);
  });
```

- [ ] **Step 2: Run them — expect failure.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/audio/queue_controller_shuffle_test.dart`. Expected: the Slice-3 `playAt` shuffled branch uses `_playOrder.indexOf(path)` (first match, not occurrence-aware) — fine for unique paths but inconsistent with `removeAt`; refactor to the shared helper. `append` from Slice 2 already mirrors `_playOrder.add(p)`, so that test likely passes — note any that already pass.

- [ ] **Step 3: Refactor `playAt` to the shared helper.** In `lib/audio/queue_controller.dart`, replace the Slice-3 `playAt` so it uses `_playerIndexForCanonical`:

```dart
  /// Jump to and play the entry at canonical [index]. Translates the canonical
  /// index to the player's source index via _playOrder (identity when not
  /// shuffled, occurrence-aware for duplicates).
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _orderedPaths.length) return;
    final playerIndex = _playerIndexForCanonical(index);
    await _player.seek(Duration.zero, index: playerIndex);
    await _player.play();
  }
```

- [ ] **Step 4: Confirm `append` mirrors `_playOrder`.** Verify the Slice-2 `append` adds to both `_orderedPaths` and `_playOrder` and calls `_player.addAudioSource` (it does). No change needed unless the mirroring is missing.

- [ ] **Step 5: Run them — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/audio/queue_controller_shuffle_test.dart`. Expected: all tests pass.

- [ ] **Step 6: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all` — clean.

- [ ] **Step 7: Commit.** `cd /home/autarch/projects/olivier && git add lib/audio/queue_controller.dart test/audio/queue_controller_shuffle_test.dart && git commit -m "Make QueueController.playAt shuffle/duplicate-aware via shared mapping helper"`

---

### Task 23: `setShuffle`/`setQueue` revision bumps + toggling OFF restores canonical order

**Files:**
- Test: `/home/autarch/projects/olivier/test/audio/queue_controller_shuffle_test.dart` (Modify)
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart`

> Slice 2 already added `revision` and appended `revision.value++` to `setQueue`/`setShuffle`. This task adds coverage proving those bumps and
the restore-on-off behavior.

- [ ] **Step 1: Add tests (revision bump + restore-on-off + permutation invariant).** Append to `test/audio/queue_controller_shuffle_test.dart`:

```dart
  test('setShuffle bumps the revision Listenable', () async {
    final start = controller.revision.value;
    await controller.setShuffle(true);
    expect(controller.revision.value, start + 1);
    await controller.setShuffle(false);
    expect(controller.revision.value, start + 2);
  });

  test('toggling shuffle OFF restores canonical order in the player', () async {
    await controller.setShuffle(true);
    await controller.setShuffle(false);

    expect(controller.shuffled, isFalse);
    expect(controller.playOrder, controller.orderedPaths);
    expect(player.sources, ['/a.flac', '/b.flac', '/c.flac', '/d.flac']);

    final snap = await loadQueue(dbPath: dbPath);
    expect(snap!.shuffle, isFalse);
    expect(snap.paths, ['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
  });

  test('shuffled playOrder is a permutation of orderedPaths and the player '
      'matches it', () async {
    await controller.setShuffle(true);
    expect(controller.shuffled, isTrue);
    expect(controller.playOrder.toSet(), controller.orderedPaths.toSet());
    expect(player.sources, controller.playOrder);
  });
```

- [ ] **Step 2: Run them — expect pass (or fix the bump).** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/audio/queue_controller_shuffle_test.dart`. Expected: pass. If the revision bump on `setShuffle`/`setQueue` is missing (Slice 2 was supposed to add it), add `revision.value++;` as the last statement of `setShuffle` and `setQueue`. `_rebuild` already restores canonical order when `_shuffled` is false, so toggling OFF needs no further change.

- [ ] **Step 3: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all` — clean.

- [ ] **Step 4: Commit.** `cd /home/autarch/projects/olivier && git add lib/audio/queue_controller.dart test/audio/queue_controller_shuffle_test.dart && git commit -m "Cover setShuffle/setQueue revision bumps and shuffle-off restore"`

---

### Task 24: `QueueView.shuffled` + canonical current-index highlight (shuffled)

**Files:**
- Test: `/home/autarch/projects/olivier/test/state/queue_provider_shuffle_test.dart` (Create)
- Modify: `/home/autarch/projects/olivier/lib/state/queue_provider.dart`
- Modify: `/home/autarch/projects/olivier/lib/audio/queue_controller.dart` (if the `currentIndexStream` listener is not yet wired)

> The contract's `currentCanonicalIndex` getter (added in Slice 2) already maps `_orderedPaths.indexOf(_playOrder[player.currentIndex ?? 0])`. This task adds a test that, with shuffle ON, the `QueueView.currentIndex` is the *canonical* index of the playing track and `QueueView.shuffled` is true, and ensures `QueueNotifier` re-emits when the player advances (listens to `player.currentIndexStream`, exposed via `QueueController`).

- [ ] **Step 1: Add a `currentIndexStream` getter to `QueueController` (if absent).** So the notifier can re-emit on track advance without reaching into the player, add to `lib/audio/queue_controller.dart`:

```dart
  /// The player's current-source-index stream, surfaced so the queue view can
  /// recompute the canonical highlight when the track advances.
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
```

- [ ] **Step 2: Write the failing provider test.** Create `test/state/queue_provider_shuffle_test.dart`. It overrides `tracksForPathsFnProvider` + `queueControllerProvider` with a controller backed by the shared `FakeQueuePlayer`, drives shuffle on, simulates the player advancing, and asserts `QueueView.shuffled` is true and `currentIndex` is the canonical index.

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:olivier/state/queue_provider.dart';

import '../support/fake_queue_player.dart';

QueueTrack _qt(String path) =>
    QueueTrack(path: path, title: path, album: '');

void main() {
  setUpAll(() async => RustLib.init());

  test('QueueView reflects shuffled flag and canonical current index',
      () async {
    final player = FakeQueuePlayer();
    final controller = QueueController.withPlayer(player, dbPath: ':memory:');
    await controller.setQueue(['/a.flac', '/b.flac', '/c.flac', '/d.flac']);
    await controller.setShuffle(true);

    final container = ProviderContainer(
      overrides: [
        queueControllerProvider.overrideWithValue(controller),
        tracksForPathsFnProvider.overrideWithValue(
          (paths) async => [for (final p in paths) _qt(p)],
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(queueProvider.future);

    // Simulate the player sitting on the first SHUFFLED source.
    player.setCurrentIndex(0);
    final playingPath = controller.playOrder[0];
    final expectedCanonical = controller.orderedPaths.indexOf(playingPath);

    // Re-read after invalidation so the canonical index is recomputed.
    final view = await container.read(queueProvider.future);
    expect(view.shuffled, isTrue);
    expect(view.tracks.map((t) => t.path).toList(), controller.orderedPaths);
    expect(view.currentIndex, expectedCanonical);
  });
}
```

  > Note: `queueControllerProvider` is already the concrete `Provider<QueueController>` from Task 6, so `overrideWithValue(controller)` type-checks and `QueueNotifier`'s reads of `orderedPaths`/`currentCanonicalIndex`/`shuffled`/`currentIndexStream` (all `QueueController` members) resolve directly — no provider re-typing or interface cast is needed. This task's substantive work is the `currentIndexStream` getter (if absent), the canonical-index assertions, and the `currentIndexStream` listener wired into `QueueNotifier.build()` in Step 4.

- [ ] **Step 3: Run it — expect failure.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/state/queue_provider_shuffle_test.dart`. Expected failure: if `QueueNotifier` set `currentIndex` from a player index rather than `currentCanonicalIndex`, or `shuffled` was not surfaced, the assertions fail. (No provider-type error is possible: `queueControllerProvider` is already concrete from Task 6.)

- [ ] **Step 4: Wire the canonical index + stream listener.** No provider re-typing is required — `queueControllerProvider` is already the concrete `Provider<QueueController>` (Task 6), so the notifier's reads of `orderedPaths`/`currentCanonicalIndex`/`shuffled`/`currentIndexStream` already type-check. In `lib/state/queue_provider.dart` ensure `_resolve()` uses `controller.currentCanonicalIndex` and `controller.shuffled` (already so from Slice 2), and add a `currentIndexStream` listener in `build()` that re-emits the view (re-invoking `_resolve` or, to avoid re-hitting the FFI, recompute only the index) on advance:

```dart
  @override
  Future<QueueView> build() async {
    final controller = _controller;

    void onRevision() => ref.invalidateSelf();
    controller.revision.addListener(onRevision);
    ref.onDispose(() => controller.revision.removeListener(onRevision));

    final sub = controller.currentIndexStream.listen((_) => ref.invalidateSelf());
    ref.onDispose(sub.cancel);

    return _resolve();
  }
```

- [ ] **Step 5: Run it — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/state/queue_provider_shuffle_test.dart`. Expected: pass.

- [ ] **Step 6: Re-run the affected earlier tests.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_panel_test.dart test/queue_provider_test.dart`. Expected: pass (these already use the concrete `queueControllerProvider`).

- [ ] **Step 7: Lint.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all` — clean.

- [ ] **Step 8: Commit.** `cd /home/autarch/projects/olivier && git add lib/state/queue_provider.dart lib/audio/queue_controller.dart test/state/queue_provider_shuffle_test.dart && git commit -m "Drive QueueView.shuffled + canonical current-index from _playOrder; re-emit on advance"`

---

### Task 25: Wire the queue-panel header Shuffle toggle to `setShuffle`

**Files:**
- Test: `/home/autarch/projects/olivier/test/widgets/queue_panel_shuffle_test.dart` (Create)
- Modify: `/home/autarch/projects/olivier/lib/catalog/queue_panel.dart`

- [ ] **Step 1: Write the failing widget test.** Create `test/widgets/queue_panel_shuffle_test.dart`, modeled on `test/catalog_text_scale_test.dart`. It pumps the panel with a real `QueueController` (fake player), taps the Shuffle toggle, and asserts the controller flipped and the header shows the active indicator.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import '../support/fake_queue_player.dart';

QueueTrack _qt(String p) => QueueTrack(path: p, title: p, album: '');

void main() {
  setUpAll(() async => RustLib.init());

  testWidgets('header Shuffle toggle calls setShuffle and shows active state',
      (tester) async {
    final player = FakeQueuePlayer();
    final controller = QueueController.withPlayer(player, dbPath: ':memory:');
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
```

- [ ] **Step 2: Run it — expect failure.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/widgets/queue_panel_shuffle_test.dart`. Expected: the header Shuffle control is still the Slice-1/3 placeholder (`onPressed: null`), so the tap is a no-op and `controller.shuffled` stays `false`.

- [ ] **Step 3: Wire the toggle.** In `lib/catalog/queue_panel.dart`, replace the placeholder Shuffle `IconButton` in the header with a `Consumer` that reads the view and calls `setShuffle`:

```dart
Consumer(
  builder: (context, ref, _) {
    final view = ref.watch(queueProvider).valueOrNull;
    final shuffled = view?.shuffled ?? false;
    return IconButton(
      tooltip: 'Shuffle',
      isSelected: shuffled,
      icon: const Icon(Icons.shuffle),
      selectedIcon: const Icon(Icons.shuffle_on),
      onPressed: () =>
          ref.read(queueControllerProvider).setShuffle(!shuffled),
    );
  },
)
```

  The indicator is driven by `view.shuffled` (from `controller.shuffled`), so toggling updates the icon's selected state through the `queueProvider` rebuild on `revision`. `setShuffle` is a `QueueController` member; since `queueControllerProvider` is the concrete `Provider<QueueController>` (from Task 6), this resolves.

- [ ] **Step 4: Run it — expect pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/widgets/queue_panel_shuffle_test.dart`. Expected: pass.

- [ ] **Step 5: Run the full Flutter + Rust suites and lint.** `cd /home/autarch/projects/olivier && mise exec -- flutter test` then `cd /home/autarch/projects/olivier/rust && cargo test` then `cd /home/autarch/projects/olivier && mise exec -- precious lint --all`. Expected: all green. (No `rust/src/api/*` signature changed in this slice → no bridge regen.)

- [ ] **Step 6: Build check.** `cd /home/autarch/projects/olivier && mise exec -- flutter build linux --debug`. Expected: build succeeds.

- [ ] **Step 7: Commit.** `cd /home/autarch/projects/olivier && git add lib/catalog/queue_panel.dart test/widgets/queue_panel_shuffle_test.dart && git commit -m "Wire queue-panel header Shuffle toggle to QueueController.setShuffle"`

---

**Slice 5 deliverable:** The queue panel header has a working Shuffle toggle that flips `QueueController.setShuffle`, shows an active/inactive indicator driven by `QueueView.shuffled`, and persists `playback_state.shuffle`; with shuffle ON, removing a queue row, jumping (`playAt`), and appending all act on the correct track by translating between the canonical display order (`_orderedPaths`) and the player's shuffled source order (`_playOrder`) — including duplicate paths — without interrupting playback; toggling shuffle OFF restores canonical play order; and the currently-playing row is highlighted by its canonical index (`_orderedPaths.indexOf(_playOrder[currentIndex])`), re-emitted as the track advances.

---

## Sequencing & shippable deliverables

1. **Slice 1 — Layout redesign (pure Flutter):** `BrowserPage` becomes a 2-pane split (wide Artist | stacked Albums/Tracks) with a collapsed, disabled queue-panel shell above the unchanged now-playing bar; headless layout test at 1.0x/1.3x. No FFI.
2. **Slice 2 — Queue model: append + selection + item 9:** browse clicks only select; double-click appends a track/album via `track_path` (new FFI) / `album_file_paths` through `QueueController.append` (incremental, persisted, `revision`-bumping); `queueProvider`/`QueueView` resolve the canonical queue; collapsed header shows count + up-next.
3. **Slice 3 — Queue panel operations:** expand caret reveals a `ReorderableListView` with reorder, `×` remove, tap-to-play, current-track highlight, and Empty — via `removeAt`/`reorder`/`playAt`/`clear` (not-shuffled path), each persisting the snapshot. No FFI.
4. **Slice 4 — Enqueue by entity: menus, drag, Shuffle-all:** new `track_paths_for_artist` / `track_paths_for_library` FFI; shared `QueueEntityRef`/`resolveEntityPaths`; right-click "Add to queue", double-click artist, and long-press-drag onto the panel all append; "Shuffle entire library" replaces+shuffles+plays with a count-bearing confirm only when non-empty.
5. **Slice 5 — Shuffle toggle:** header Shuffle toggle wired to `setShuffle` with an active indicator; shuffle-aware, duplicate-aware canonical↔player index translation for `removeAt`/`playAt`/`append`; toggling off restores canonical order; canonical current-index highlight re-emitted on advance. No FFI.

## Out of scope

- **"Play next"** (insert-after-current) — intentionally dropped; everything appends. Easy to add later.
- **Album-art thumbnails in queue rows** — depends on the separate album-art pipeline (spec items 5 & 8); the queue view works without them.
- **The other context-menu entries (#3 re-read tags, #4 per-entity re-fetch, #7 info popup)** beyond "Add to queue" — separate backlog items that simply add items to the same shared `AddToQueueMenu`.
- **Keyboard play (Enter on selection)** — playback is via the queue/transport only, unless requested later.
