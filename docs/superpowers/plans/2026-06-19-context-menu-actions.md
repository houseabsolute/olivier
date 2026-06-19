# Context-Menu Actions + Ctrl-Q — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Ctrl-Q to quit, a copy-paste Info popup (tracks & albums), per-track tag re-read (with re-homing), and per-artist/album MusicBrainz re-fetch — three of them via the row context menu the queue work already built.

**Architecture:** Generalize `AddToQueueMenu` → `RowContextMenu` with optional per-entity actions. Ctrl-Q and the Info popup are pure Flutter. Re-read tags is a new Rust FFI that re-runs the track's file(s) through `scan.rs`'s existing single-file `upsert_file` + `reconcile_album_artists` + `prune_orphans`. Per-entity re-fetch extracts a shared `enrich_lists(...)` from `run::enrich` and adds constrained `enrich_artist`/`enrich_album` entry points that scoped-clear the entity's `mb_cache` first.

**Tech Stack:** Flutter + Riverpod + flutter_rust_bridge + rusqlite.

**Conventions:** Branch `context-menu-actions` (do NOT switch). Tests run host-VM under `mise exec -- flutter test`; FFI is behind injectable seam providers; Rust FFI round-trips are covered by `rust/tests/*` (cargo), not host-VM Dart. After any `rust/src/api/*.rs` signature change run `mise exec -- flutter_rust_bridge_codegen generate` and commit the regenerated `lib/src/rust/**` + `rust/src/frb_generated.rs`. Lint with `mise exec -- precious lint --all` (clippy `-D warnings`). Never stage the unrelated modified `TODO` file.

---

## File Structure

**Flutter**
- `lib/main.dart` (modify) — wrap `OlivierApp`'s `MaterialApp` in `CallbackShortcuts` for Ctrl-Q.
- `lib/widgets/context_menu.dart` (modify) — rename `AddToQueueMenu` → `RowContextMenu`; add optional `onInfo`/`onReadTags`/`onRefetch` entries.
- `lib/widgets/info_dialog.dart` (create) — `showInfoDialog(...)` + `trackInfoFields(Track)` / `albumInfoFields(Album)` builders.
- `lib/catalog/{artist,album,track}_column.dart` (modify) — use `RowContextMenu`; wire the entity-appropriate actions.
- `lib/state/providers.dart` (modify) — `rereadTrackTagsFnProvider` seam (item 3).
- `lib/state/enrich_controller.dart` (modify) — `enrichArtist`/`enrichAlbum` (item 4).

**Rust**
- `rust/src/catalog/scan.rs` (modify) — add `reread_track_tags(conn, track_id)`.
- `rust/src/api/catalog.rs` (modify) — FFI wrapper `reread_track_tags(db_path, track_id)`.
- `rust/src/enrich/run.rs` (modify) — extract `enrich_lists(...)`; add `enrich_artist`/`enrich_album`; add `clear_artist_cache`/`clear_album_cache`.
- `rust/src/api/enrich.rs` (modify) — FFI wrappers `enrich_artist`/`enrich_album`.
- `rust/tests/catalog_test.rs` (modify) — re-read-tags re-home tests.
- `rust/tests/enrich_test.rs` (modify) — per-entity enrich tests.
- Regenerated bridge (commit) — for the new FFI fns.

---

## Slice 1 — Ctrl-Q quits

### Task 1: Ctrl-Q exits the app

**Files:**
- Modify: `lib/main.dart`
- Test: `test/ctrl_q_test.dart` (create)

- [ ] **Step 1: Write the failing test.** Create `test/ctrl_q_test.dart`. `SystemNavigator.pop()` can't be asserted directly, so make the quit action injectable: `OlivierApp` takes an optional `onQuit` callback (defaults to `SystemNavigator.pop`), and the test asserts it fires on Ctrl-Q.

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart';

void main() {
  testWidgets('Ctrl-Q invokes the quit callback', (tester) async {
    var quit = 0;
    await tester.pumpWidget(OlivierApp(onQuit: () => quit++));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(quit, 1);
  });
}
```

- [ ] **Step 2: Run it — fails.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/ctrl_q_test.dart`. Expected: compile error — `OlivierApp` has no `onQuit`.

- [ ] **Step 3: Implement.** In `lib/main.dart` add the `services` import (`import 'package:flutter/services.dart';`) and change `OlivierApp`:

```dart
class OlivierApp extends StatelessWidget {
  const OlivierApp({super.key, this.onQuit});

  /// Injectable so the Ctrl-Q binding is testable; defaults to quitting.
  final VoidCallback? onQuit;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true):
            onQuit ?? () => SystemNavigator.pop(),
      },
      child: Focus(
        autofocus: true,
        child: const MaterialApp(
          title: 'Olivier',
          home: BrowserPage(),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run it — passes.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/ctrl_q_test.dart`. Expected: pass.

- [ ] **Step 5: Lint + commit.** `cd /home/autarch/projects/olivier && mise exec -- precious lint --all` then `git add lib/main.dart test/ctrl_q_test.dart && git commit -m "Ctrl-Q quits the app"`.

---

## Slice 2 — Generalize the row context menu

### Task 2: `RowContextMenu` with optional per-entity actions

**Files:**
- Modify: `lib/widgets/context_menu.dart`
- Modify: `lib/catalog/artist_column.dart`, `lib/catalog/album_column.dart`, `lib/catalog/track_column.dart`
- Modify: `test/context_menu_test.dart`

- [ ] **Step 1: Update the test first.** Replace `test/context_menu_test.dart` so it pumps `RowContextMenu` with `onInfo` provided and asserts both "Add to queue" and "Info" appear, that an action without a callback is absent, and that selecting "Info" fires `onInfo`.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/widgets/context_menu.dart';

void main() {
  testWidgets('shows Add to queue + only the provided optional actions',
      (tester) async {
    QueueEntityRef? added;
    QueueEntityRef? infoed;
    const entity = QueueEntityRef.album('rel-1');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RowContextMenu(
          entity: entity,
          onAddToQueue: (e) => added = e,
          onInfo: (e) => infoed = e,
          child: const SizedBox(width: 200, height: 40, child: Text('row')),
        ),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Re-read tags'), findsNothing); // no onReadTags given
    expect(find.text('Re-fetch from MusicBrainz'), findsNothing);

    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    expect(infoed, entity);
    expect(added, isNull);
  });
}
```

- [ ] **Step 2: Run it — fails.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/context_menu_test.dart`. Expected: `RowContextMenu` undefined.

- [ ] **Step 3: Rewrite `lib/widgets/context_menu.dart`.** Replace the whole file:

```dart
import 'package:flutter/material.dart';
import 'package:olivier/audio/queue_entity.dart';

/// Wraps [child] so a right-click (secondary tap) opens a context menu. The
/// "Add to queue" entry is always present; the optional [onInfo]/[onReadTags]/
/// [onRefetch] entries appear only when their callback is non-null, so each
/// column shows the actions appropriate to its entity.
class RowContextMenu extends StatelessWidget {
  const RowContextMenu({
    super.key,
    required this.entity,
    required this.onAddToQueue,
    this.onInfo,
    this.onReadTags,
    this.onRefetch,
    required this.child,
  });

  final QueueEntityRef entity;
  final ValueChanged<QueueEntityRef> onAddToQueue;
  final ValueChanged<QueueEntityRef>? onInfo;
  final ValueChanged<QueueEntityRef>? onReadTags;
  final ValueChanged<QueueEntityRef>? onRefetch;
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
      items: [
        const PopupMenuItem<String>(value: 'add', child: Text('Add to queue')),
        if (onInfo != null)
          const PopupMenuItem<String>(value: 'info', child: Text('Info')),
        if (onReadTags != null)
          const PopupMenuItem<String>(
              value: 'reread', child: Text('Re-read tags')),
        if (onRefetch != null)
          const PopupMenuItem<String>(
              value: 'refetch', child: Text('Re-fetch from MusicBrainz')),
      ],
    );
    switch (selected) {
      case 'add':
        onAddToQueue(entity);
      case 'info':
        onInfo?.call(entity);
      case 'reread':
        onReadTags?.call(entity);
      case 'refetch':
        onRefetch?.call(entity);
    }
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

- [ ] **Step 4: Update the three columns.** In each of `artist_column.dart`, `album_column.dart`, `track_column.dart`, rename the `AddToQueueMenu(...)` wrapper to `RowContextMenu(...)`, keeping the existing `entity:`, `onAddToQueue:`, `child:` args (leave the new optional callbacks unset for now — they're wired in Tasks 3 & 5). The import line `import 'package:olivier/widgets/context_menu.dart';` is unchanged.

- [ ] **Step 5: Run it — passes + no regressions.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/context_menu_test.dart && mise exec -- flutter test`. Expected: all pass.

- [ ] **Step 6: Lint + commit.** `mise exec -- precious lint --all` then `git add lib/widgets/context_menu.dart lib/catalog/artist_column.dart lib/catalog/album_column.dart lib/catalog/track_column.dart test/context_menu_test.dart && git commit -m "Generalize AddToQueueMenu into RowContextMenu with optional actions"`.

---

## Slice 3 — Info popup (tracks & albums)

### Task 3: Info dialog + field builders, wired on track & album rows

**Files:**
- Create: `lib/widgets/info_dialog.dart`
- Modify: `lib/catalog/track_column.dart`, `lib/catalog/album_column.dart`
- Test: `test/info_dialog_test.dart` (create)

- [ ] **Step 1: Failing test.** Create `test/info_dialog_test.dart` covering the field builders (pure, host-VM) and the dialog rendering selectable values + omitting empties.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/widgets/info_dialog.dart';

void main() {
  test('trackInfoFields includes bilingual fields and omits empties', () {
    final t = Track(
      id: 7,
      disc: 1,
      position: 3,
      title: '歌舞伎町の女王',
      artist: 'Sheena Ringo',
      addedAt: 0,
      lengthMs: BigInt.from(258000),
      titleTranslit: 'Kabukicho no Joo',
      // titleTranslate omitted (null) → must not appear
    );
    final fields = trackInfoFields(t);
    final labels = fields.map((f) => f.$1).toList();
    expect(labels, contains('Title'));
    expect(labels, contains('Reading'));
    expect(labels, isNot(contains('Translation'))); // null omitted
    expect(fields.firstWhere((f) => f.$1 == 'Length').$2, '4:18');
  });

  testWidgets('showInfoDialog renders values as SelectableText', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showInfoDialog(context,
                  title: 'Track', fields: const [('Title', '歌舞伎町の女王')]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.text('歌舞伎町の女王'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run it — fails.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/info_dialog_test.dart`. Expected: `showInfoDialog`/`trackInfoFields` undefined.

- [ ] **Step 3: Create `lib/widgets/info_dialog.dart`.**

```dart
import 'package:flutter/material.dart';
import 'package:olivier/src/rust/catalog/schema.dart';

/// A read-only, copy-pasteable info dialog: label/value rows where each value is
/// selectable text. The caller passes only non-empty fields.
Future<void> showInfoDialog(
  BuildContext context, {
  required String title,
  required List<(String, String)> fields,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context).textTheme.labelSmall),
                      SelectableText(value),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

String _fmtLen(BigInt? ms) {
  if (ms == null) return '';
  final s = (ms ~/ BigInt.from(1000)).toInt();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

void _add(List<(String, String)> out, String label, String? value) {
  final v = (value ?? '').trim();
  if (v.isNotEmpty) out.add((label, v));
}

/// Non-empty info fields for a track, in display order.
List<(String, String)> trackInfoFields(Track t) {
  final out = <(String, String)>[];
  _add(out, 'Title', t.title);
  _add(out, 'Reading', t.titleTranslit);
  _add(out, 'Translation', t.titleTranslate);
  _add(out, 'Artist', t.artist);
  _add(out, 'Disc / Track', '${t.disc} / ${t.position}');
  _add(out, 'Length', _fmtLen(t.lengthMs));
  _add(out, 'Track id', t.id.toString());
  return out;
}

/// Non-empty info fields for an album, in display order.
List<(String, String)> albumInfoFields(Album a) {
  final out = <(String, String)>[];
  _add(out, 'Title', a.title);
  _add(out, 'Reading', a.titleTranslit);
  _add(out, 'Translation', a.titleTranslate);
  _add(out, 'Album artist', a.albumArtist);
  _add(out, 'Original year', a.originalYear);
  _add(out, 'Reissue year', a.reissueYear);
  _add(out, 'Release MBID', a.releaseMbid);
  return out;
}
```

- [ ] **Step 4: Run it — passes.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/info_dialog_test.dart`. Expected: pass.

- [ ] **Step 5: Wire `onInfo` on track rows.** In `lib/catalog/track_column.dart` add `import 'package:olivier/widgets/info_dialog.dart';`, and on the row's `RowContextMenu` add:

```dart
            onInfo: (_) => showInfoDialog(context,
                title: 'Track', fields: trackInfoFields(track)),
```

- [ ] **Step 6: Wire `onInfo` on album rows.** In `lib/catalog/album_column.dart` add the same import, and on the album row's `RowContextMenu` add:

```dart
            onInfo: (_) => showInfoDialog(context,
                title: 'Album', fields: albumInfoFields(album)),
```

- [ ] **Step 7: Run the full suite + lint.** `cd /home/autarch/projects/olivier && mise exec -- flutter test && mise exec -- precious lint --all`. Expected: all pass, clean.

- [ ] **Step 8: Commit.** `git add lib/widgets/info_dialog.dart lib/catalog/track_column.dart lib/catalog/album_column.dart test/info_dialog_test.dart && git commit -m "Add copy-paste Info popup for tracks and albums"`.

---

## Slice 4 — Re-read tags for a track (with re-homing)

### Task 4: Rust `reread_track_tags` FFI + bridge + tests

**Files:**
- Modify: `rust/src/catalog/scan.rs`
- Modify: `rust/src/api/catalog.rs`
- Test: `rust/tests/catalog_test.rs`
- Regenerate bridge (commit)

- [ ] **Step 1: Write the failing Rust tests.** Add to `rust/tests/catalog_test.rs`. Seed a file on a real temp path with tags, scan it, then rewrite the file's tags to a DIFFERENT album and assert `reread_track_tags` re-homes the track (new release present, old now-empty release pruned). Model the seeding on the existing scan tests in that file (use a temp dir + write real audio files via the test helpers already there; if none exist, write a minimal tagged file with `lofty` as the other catalog tests do). Two tests:

```rust
#[test]
fn reread_track_tags_is_a_noop_when_tags_unchanged() {
    // seed one file under a temp dir, scan it, capture the track's release_mbid,
    // then reread_track_tags(track_id) WITHOUT changing the file → same release,
    // same track id, one file.
    // (Use the temp-file + scan helpers already used by the other scan tests.)
}

#[test]
fn reread_track_tags_rehomes_when_album_changes() {
    // seed one file (album "A"), scan; rewrite the file's ALBUM tag to "B" on disk;
    // reread_track_tags(track_id) → the track now belongs to release "B", release
    // "A" is pruned (no rows), and the file still resolves to exactly one track.
}
```

(Write the bodies concretely using this file's existing test scaffolding for creating tagged temp files + calling `scan::scan_roots` — read the top of `rust/tests/catalog_test.rs` for the helpers and mirror them.)

- [ ] **Step 2: Run them — fail.** `cd /home/autarch/projects/olivier/rust && cargo test reread_track_tags`. Expected: `scan::reread_track_tags` undefined.

- [ ] **Step 3: Implement `reread_track_tags` in `rust/src/catalog/scan.rs`.** Add after `scan_roots`. It re-stats + re-reads each file backing the track, re-upserts via the existing private `upsert_file`, then reconciles + prunes — re-homing the track if the new tags changed its album/artist. Add `use std::path::Path;` if not already imported.

```rust
/// Re-read the tags of every file backing one track and re-upsert it, re-homing
/// the track to the correct album/artist if the tags changed, then clean up any
/// now-orphaned rows. Local tags only (MusicBrainz re-fetch is a separate action).
pub fn reread_track_tags(conn: &mut Connection, track_id: i64) -> anyhow::Result<()> {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?;
    let epoch = now.as_nanos() as i64;
    let now_secs = now.as_secs() as i64;

    let paths: Vec<String> = {
        let mut stmt = conn.prepare("SELECT path FROM file WHERE track_id = ?1")?;
        let rows = stmt.query_map([track_id], |r| r.get::<_, String>(0))?;
        rows.collect::<Result<Vec<_>, _>>()?
    };

    for path in &paths {
        // The file may have moved/vanished since the scan; skip missing ones (a
        // future full scan's deletion sweep removes them).
        let meta = match std::fs::metadata(path) {
            Ok(m) => m,
            Err(_) => continue,
        };
        let mtime = meta.modified()?.duration_since(std::time::UNIX_EPOCH)?.as_secs() as i64;
        let size = meta.len() as i64;
        let tags = read_tags(Path::new(path))
            .with_context(|| format!("read_tags for {path}"))?;
        let tx = conn.transaction()?;
        upsert_file(&tx, &tags, path, mtime, size, epoch, now_secs)?;
        tx.commit()?;
    }

    reconcile_album_artists(conn)?;
    prune_orphans(conn)?;
    Ok(())
}
```

- [ ] **Step 4: Add the FFI wrapper in `rust/src/api/catalog.rs`.**

```rust
pub fn reread_track_tags(db_path: String, track_id: i64) -> anyhow::Result<()> {
    let mut conn = db::open(&db_path)?;
    scan::reread_track_tags(&mut conn, track_id)
}
```

(`scan` is already imported in that file — confirm `use crate::catalog::scan;` is present; the existing `scan_library` uses it.)

- [ ] **Step 5: Run the Rust tests — pass.** `cd /home/autarch/projects/olivier/rust && cargo test reread_track_tags`. Expected: both pass.

- [ ] **Step 6: Regenerate the bridge + verify build.** `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate` then `mise exec -- flutter build linux --debug`. Confirm `rereadTrackTags` appears in `lib/src/rust/api/catalog.dart`.

- [ ] **Step 7: Lint + commit (including the regenerated bridge).** `mise exec -- precious lint --all` then `git add rust/src/catalog/scan.rs rust/src/api/catalog.rs rust/tests/catalog_test.rs lib/src/rust/ rust/src/frb_generated.rs && git commit -m "Add reread_track_tags FFI (single-file re-scan that re-homes the track)"`.

### Task 5: Wire "Re-read tags" on track rows

**Files:**
- Modify: `lib/state/providers.dart`
- Modify: `lib/catalog/track_column.dart`
- Test: `test/reread_tags_test.dart` (create)

- [ ] **Step 1: Failing test.** Create `test/reread_tags_test.dart`: tapping "Re-read tags" calls the injected FFI seam with the track id and then invalidates the catalog providers. Override the seam so no native lib is touched.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

final _track = Track(id: 7, disc: 1, position: 1, title: 'Song', addedAt: 0);

class _StubAlbum extends SelectedAlbum {
  @override
  String? build() => 'rel-1';
}

void main() {
  testWidgets('Re-read tags calls the FFI seam with the track id',
      (tester) async {
    int? reread;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((k) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(_StubAlbum.new),
        rereadTrackTagsFnProvider.overrideWithValue((id) async => reread = id),
      ],
      child: const MaterialApp(home: Scaffold(body: TrackColumn())),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
        tester.getCenter(find.text('1. Song')),
        buttons: kSecondaryButton);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Re-read tags'));
    await tester.pumpAndSettle();

    expect(reread, 7);
  });
}
```

- [ ] **Step 2: Run it — fails.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/reread_tags_test.dart`. Expected: `rereadTrackTagsFnProvider` undefined.

- [ ] **Step 3: Add the seam in `lib/state/providers.dart`** (next to the other FFI seams; `package:olivier/src/rust/api/catalog.dart` is already imported, so `rereadTrackTags` is in scope after regen):

```dart
// Re-read one track's tags (re-homes it if the album/artist changed). Seam.
typedef RereadTrackTagsFn = Future<void> Function(int trackId);

final rereadTrackTagsFnProvider = Provider<RereadTrackTagsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (trackId) => rereadTrackTags(dbPath: db, trackId: trackId);
});
```

- [ ] **Step 4: Wire `onReadTags` on track rows in `lib/catalog/track_column.dart`.** On the row's `RowContextMenu` add the handler — it calls the seam, then invalidates the catalog providers and clears any dangling selection, and shows a SnackBar:

```dart
            onReadTags: (_) async {
              final messenger = ScaffoldMessenger.of(context);
              await ref.read(rereadTrackTagsFnProvider)(track.id);
              ref.invalidate(artistsProvider);
              ref.invalidate(albumsProvider);
              ref.invalidate(tracksProvider);
              messenger
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(content: Text('Tags re-read')));
            },
```

(Imports: `track_column.dart` already imports `providers.dart` for `tracksProvider`/`languageLeadsProvider`; `artistsProvider`/`albumsProvider` are in the same file. No new import needed.)

- [ ] **Step 5: Run it + full suite — pass.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/reread_tags_test.dart && mise exec -- flutter test`. Expected: all pass.

- [ ] **Step 6: Lint + commit.** `mise exec -- precious lint --all` then `git add lib/state/providers.dart lib/catalog/track_column.dart test/reread_tags_test.dart && git commit -m "Wire Re-read tags action on track rows"`.

---

## Slice 5 — Per-entity MusicBrainz re-fetch

### Task 6: Rust per-entity enrich (`enrich_artist`/`enrich_album`) + scoped cache-clear + bridge

**Files:**
- Modify: `rust/src/enrich/run.rs`
- Modify: `rust/src/api/enrich.rs`
- Test: `rust/tests/enrich_test.rs`
- Regenerate bridge (commit)

- [ ] **Step 1: Failing Rust test.** Add to `rust/tests/enrich_test.rs` (use the existing `FakeHttp` double + fixtures pattern). Seed two real-MBID artists; call `run::enrich_artist(conn, client, artist_a_mbid, |_| true)` and assert ONLY artist A's data was applied (B untouched), and that A's `mb_cache` rows were cleared first (insert a stale cache row for A and assert it's gone / refetched).

```rust
#[tokio::test]
async fn enrich_artist_processes_only_that_artist_and_clears_its_cache() {
    // seed artist A + B (real mbids) + a release for A; insert a stale mb_cache
    // row for A; FakeHttp serves A's artist fetch + A's release browse.
    // run::enrich_artist(&conn, &client, A, |_| true) -> A gets name_original set,
    // B's row unchanged, and A's stale cache row was deleted (refetched).
}
```

(Write the body using `enrich_test.rs`'s existing seed helpers + `FakeHttp`/fixtures; mirror `backfills_name_original_on_upgraded_2a_library`.)

- [ ] **Step 2: Run it — fails.** `cd /home/autarch/projects/olivier/rust && cargo test enrich_artist`. Expected: `run::enrich_artist` undefined.

- [ ] **Step 3: Refactor `run::enrich` to extract `enrich_lists` + add the per-entity entry points.** In `rust/src/enrich/run.rs`, change the public `enrich` to gather the lists and delegate, and add the new fns. Keep the existing artist/release loop bodies inside `enrich_lists` (move them there unchanged):

```rust
pub async fn enrich<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    force: bool,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    let artists = artists_to_enrich(conn, force)?;
    let releases = releases_to_enrich(conn, force)?;
    enrich_lists(conn, client, artists, releases, on_progress).await
}

/// Re-enrich ONE artist and all of its releases, refetching from the network.
pub async fn enrich_artist<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    artist_mbid: &str,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    clear_artist_cache(conn, artist_mbid)?;
    let releases = artist_releases(conn, artist_mbid)?;
    enrich_lists(conn, client, vec![artist_mbid.to_string()], releases, on_progress).await
}

/// Re-enrich ONE release (and its sibling editions), refetching from the network.
pub async fn enrich_album<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    release_mbid: &str,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    clear_album_cache(conn, release_mbid)?;
    let releases = one_release(conn, release_mbid)?;
    enrich_lists(conn, client, Vec::new(), releases, on_progress).await
}

async fn enrich_lists<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    artists: Vec<String>,
    releases: Vec<(String, Option<String>, String)>,
    mut on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    // ... MOVE the existing artist loop + release loop bodies here unchanged,
    // computing `total = artists.len() + releases.len()` and iterating `&artists`
    // / `&releases` exactly as `enrich` did before. ...
}

fn artist_releases(
    conn: &Connection,
    artist_mbid: &str,
) -> anyhow::Result<Vec<(String, Option<String>, String)>> {
    let mut stmt = conn.prepare(
        "SELECT r.mbid, r.release_group_mbid, COALESCE(r.title,'')
         FROM release r WHERE r.album_artist_mbid = ?1 AND r.mbid NOT LIKE 'synth:%'",
    )?;
    let rows = stmt.query_map([artist_mbid], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, String>(2)?))
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

fn one_release(
    conn: &Connection,
    release_mbid: &str,
) -> anyhow::Result<Vec<(String, Option<String>, String)>> {
    let row = conn.query_row(
        "SELECT r.mbid, r.release_group_mbid, COALESCE(r.title,'') FROM release r WHERE r.mbid = ?1",
        [release_mbid],
        |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, String>(2)?)),
    );
    match row {
        Ok(t) => Ok(vec![t]),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(Vec::new()),
        Err(e) => Err(e.into()),
    }
}

/// Drop the cached MB responses for one artist (its artist fetch, its releases,
/// and their release-groups) so the re-enrich hits the network fresh.
fn clear_artist_cache(conn: &Connection, artist_mbid: &str) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM mb_cache WHERE mbid = ?1
           OR mbid IN (SELECT mbid FROM release WHERE album_artist_mbid = ?1)
           OR mbid IN (SELECT release_group_mbid FROM release
                       WHERE album_artist_mbid = ?1 AND release_group_mbid IS NOT NULL)",
        [artist_mbid],
    )?;
    Ok(())
}

/// Drop the cached MB responses for one release (and its release-group browse).
fn clear_album_cache(conn: &Connection, release_mbid: &str) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM mb_cache WHERE mbid = ?1
           OR mbid IN (SELECT release_group_mbid FROM release
                       WHERE mbid = ?1 AND release_group_mbid IS NOT NULL)",
        [release_mbid],
    )?;
    Ok(())
}
```

(The release loop reads the REAL release-group from the fetched JSON, so passing the catalog `release_group_mbid` here is consistent with `releases_to_enrich`.)

- [ ] **Step 4: Run the Rust test — passes.** `cd /home/autarch/projects/olivier/rust && cargo test enrich_artist` and the whole enrich suite `cargo test --test enrich_test`. Expected: all green (the refactor must not regress the existing enrich tests).

- [ ] **Step 5: Add the FFI wrappers in `rust/src/api/enrich.rs`.** Mirror `enrich_library` (build conn + http client + runtime, then `block_on`):

```rust
pub fn enrich_artist(
    db_path: String,
    artist_mbid: String,
    sink: StreamSink<EnrichProgress>,
) -> anyhow::Result<()> {
    let conn = db::open(&db_path)?;
    let email = settings::get_setting_or_default(&conn, "mb_contact_email")?;
    let http = ReqwestHttp::new(env!("CARGO_PKG_VERSION"), &email)?;
    let client = MbClient::with_pacer(http, WallClockPacer::default());
    let rt = enrich_runtime()?;
    rt.block_on(run::enrich_artist(&conn, &client, &artist_mbid, |p| sink.add(p).is_ok()))
}

pub fn enrich_album(
    db_path: String,
    release_mbid: String,
    sink: StreamSink<EnrichProgress>,
) -> anyhow::Result<()> {
    let conn = db::open(&db_path)?;
    let email = settings::get_setting_or_default(&conn, "mb_contact_email")?;
    let http = ReqwestHttp::new(env!("CARGO_PKG_VERSION"), &email)?;
    let client = MbClient::with_pacer(http, WallClockPacer::default());
    let rt = enrich_runtime()?;
    rt.block_on(run::enrich_album(&conn, &client, &release_mbid, |p| sink.add(p).is_ok()))
}
```

- [ ] **Step 6: Regenerate the bridge + build.** `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate` then `mise exec -- flutter build linux --debug`. Confirm `enrichArtist`/`enrichAlbum` are in `lib/src/rust/api/enrich.dart`.

- [ ] **Step 7: Lint + commit (with the bridge).** `mise exec -- precious lint --all` then `git add rust/src/enrich/run.rs rust/src/api/enrich.rs rust/tests/enrich_test.rs lib/src/rust/ rust/src/frb_generated.rs && git commit -m "Add per-entity enrich_artist/enrich_album FFI with scoped cache-clear"`.

### Task 7: `EnrichController.enrichArtist/enrichAlbum` + wire "Re-fetch from MusicBrainz"

**Files:**
- Modify: `lib/state/enrich_controller.dart`
- Modify: `lib/catalog/artist_column.dart`, `lib/catalog/album_column.dart`
- Test: `test/enrich_per_entity_test.dart` (create)

- [ ] **Step 1: Failing test.** Create `test/enrich_per_entity_test.dart`: `enrichArtist` is single-flight and streams to completion, then invalidates the catalog providers. Override the FFI seam. (The controller currently calls the bridge `enrichLibrary` directly; this task adds a seam so the per-entity path is testable — add `enrichArtistFnProvider`/`enrichAlbumFnProvider` typedef seams that yield a `Stream<EnrichProgress>`, defaulting to the real `enrichArtist`/`enrichAlbum`.)

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/api/enrich.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';

void main() {
  test('enrichArtist runs single-flight and finishes not-running', () async {
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue('/x.db'),
      enrichArtistFnProvider.overrideWithValue((mbid) async* {
        yield EnrichProgress(
            entitiesDone: BigInt.one,
            entitiesTotal: BigInt.one,
            current: 'A',
            done: true);
      }),
    ]);
    addTearDown(container.dispose);

    await container.read(enrichControllerProvider.notifier).enrichArtist('A');
    expect(container.read(enrichControllerProvider).running, isFalse);
  });
}
```

- [ ] **Step 2: Run it — fails.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/enrich_per_entity_test.dart`. Expected: `enrichArtistFnProvider`/`enrichArtist` (method) undefined.

- [ ] **Step 3: Add the seams + methods in `lib/state/enrich_controller.dart`.** Add the typedef seam providers (near the controller) and two methods that reuse the existing single-flight/progress/invalidate shape of `enrich()`:

```dart
typedef EnrichEntityFn = Stream<EnrichProgress> Function(String mbid);

final enrichArtistFnProvider = Provider<EnrichEntityFn>((ref) {
  final db = ref.read(dbPathProvider);
  return (mbid) => enrichArtist(dbPath: db, artistMbid: mbid);
});
final enrichAlbumFnProvider = Provider<EnrichEntityFn>((ref) {
  final db = ref.read(dbPathProvider);
  return (mbid) => enrichAlbum(dbPath: db, releaseMbid: mbid);
});
```

  Then add to `EnrichController` a private runner + two public methods:

```dart
  Future<void> enrichArtist(String mbid) =>
      _runEntity(ref.read(enrichArtistFnProvider), mbid);
  Future<void> enrichAlbum(String mbid) =>
      _runEntity(ref.read(enrichAlbumFnProvider), mbid);

  Future<void> _runEntity(EnrichEntityFn fn, String mbid) async {
    if (_running) return;
    _running = true;
    if (!_disposed) {
      state = state.copyWith(
          running: true,
          entitiesDone: 0,
          entitiesTotal: 0,
          current: '',
          lastError: null);
    }
    try {
      await for (final p in fn(mbid)) {
        if (_disposed) return;
        state = state.copyWith(
            entitiesDone: p.entitiesDone.toInt(),
            entitiesTotal: p.entitiesTotal.toInt(),
            current: p.current);
        if (p.done) break;
      }
    } catch (e) {
      if (!_disposed) state = state.copyWith(lastError: '$e');
    } finally {
      _running = false;
      if (!_disposed) {
        state = state.copyWith(running: false);
        ref.invalidate(artistsProvider);
        ref.invalidate(albumsProvider);
        ref.invalidate(tracksProvider);
      }
    }
  }
```

  (`enrichArtist`/`enrichAlbum` bridge fns + `EnrichProgress` come from the already-imported `package:olivier/src/rust/api/enrich.dart`.)

- [ ] **Step 4: Run it — passes.** `cd /home/autarch/projects/olivier && mise exec -- flutter test test/enrich_per_entity_test.dart`. Expected: pass.

- [ ] **Step 5: Wire `onRefetch` on artist rows.** In `lib/catalog/artist_column.dart` add `import 'package:olivier/state/enrich_controller.dart';` (if absent) and on the row's `RowContextMenu`:

```dart
            onRefetch: (_) {
              final c = ref.read(enrichControllerProvider.notifier);
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(
                    content: Text('Re-fetching from MusicBrainz…')));
              c.enrichArtist(artist.mbid);
            },
```

- [ ] **Step 6: Wire `onRefetch` on album rows.** In `lib/catalog/album_column.dart` add the same import and on the album row's `RowContextMenu`:

```dart
            onRefetch: (_) {
              final c = ref.read(enrichControllerProvider.notifier);
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(
                    content: Text('Re-fetching from MusicBrainz…')));
              c.enrichAlbum(album.releaseMbid);
            },
```

- [ ] **Step 7: Full suite + lint + build.** `cd /home/autarch/projects/olivier && mise exec -- flutter test && mise exec -- precious lint --all && mise exec -- flutter build linux --debug`. Expected: all pass, clean, builds.

- [ ] **Step 8: Commit.** `git add lib/state/enrich_controller.dart lib/catalog/artist_column.dart lib/catalog/album_column.dart test/enrich_per_entity_test.dart && git commit -m "Wire per-entity Re-fetch from MusicBrainz on artist and album rows"`.

---

## Sequencing & shippable deliverables

1. **Ctrl-Q** — quit shortcut.
2. **RowContextMenu** — generalized menu (Add-to-queue unchanged).
3. **Info popup** — copy-paste info on track & album rows.
4. **Re-read tags** — per-track re-scan that re-homes on album/artist change.
5. **Per-entity re-fetch** — fresh MusicBrainz re-fetch for one artist/album, single-flight, progress + invalidate.

## Out of scope
- Richer album info (date-added, cover, track count) — rides album-art item 8.
- Import-decision log (item 2). Re-read tags is local-only; it does not re-enrich (that's the per-entity re-fetch).
