# Remove from Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Remove from library" right-click action to album and track rows that forgets the entity from the catalog (deletes its DB rows; files on disk are untouched).

**Architecture:** Reuse the existing file-driven deletion model — delete the entity's `file` rows, then run the existing child-first `prune_orphans` sweep (exactly how `remove_root` works). New Rust `deletes` module + two FFI functions, a bridge regen, then Flutter seam providers + a `RowContextMenu` item wired into the album and track columns (invalidate the catalog providers + snackbar, mirroring the existing "Re-read tags" action).

**Tech Stack:** Rust (rusqlite) + flutter_rust_bridge 2.12.0; Dart / Flutter / Riverpod 3.x.

**Commands:** Rust: `cd rust && cargo test --test <name>`, `cargo build`. Bridge: `mise exec -- flutter_rust_bridge_codegen generate` (run from repo root). Flutter: `mise exec -- flutter test <path>`, `mise exec -- flutter analyze`, `mise exec -- dart format <files>`. Lint gate: `mise exec -- precious lint --all` (clippy `-D warnings` + dart) or `just lint --all`.

**Task order rationale:** 1 (Rust API + tests) → 2 (regen the Dart bindings) → 3 (menu item) → 4 (album wiring) → 5 (track wiring). Each task leaves a compiling app. Adding a new FFI *function* (not a struct) does not break `frb_generated.rs` before regen, so Task 1's `cargo` passes without regenerating.

**Conventions / gotchas:**
- NEVER `git add` the `TODO` file (the user's live scratchpad, shows as `M TODO`) or any `#TODO#`. Stage only the explicit file lists below.
- Commit messages: plain imperative (no `feat:` prefix), ending with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Run Flutter only through `mise exec --`.

---

### Task 1: Rust per-entity delete API + tests

**Files:**
- Create: `rust/src/catalog/deletes.rs`
- Modify: `rust/src/catalog/mod.rs` (register the module)
- Modify: `rust/src/api/catalog.rs` (FFI wrappers)
- Test: `rust/tests/remove_entity_test.rs`

- [ ] **Step 1: Write the failing test**

Create `rust/tests/remove_entity_test.rs`:

```rust
use rusqlite::params;
use rust_lib_olivier::catalog::deletes::{remove_album, remove_track};
use rust_lib_olivier::db::open;

/// One artist (A1) with two albums: R1 has tracks T1,T2 (files F1,F2); R2 has
/// track T3 (file F3). Seeded with direct SQL (no fixtures) so the delete logic
/// is tested in isolation. `open(":memory:")` runs the migrations that create
/// the tables.
fn seed() -> rusqlite::Connection {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('A1','Artist One','Artist One')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('R1','A1','Album One')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('R2','A1','Album Two')",
        [],
    )
    .unwrap();
    // UNIQUE(release_mbid, disc, position): give each track in a release a distinct position.
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1,'R1',1,1,'T1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2,'R1',1,2,'T2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (3,'R2',1,1,'T3')",
        [],
    )
    .unwrap();
    for (id, path, tid) in [(1, "/m/a1.flac", 1), (2, "/m/a2.flac", 2), (3, "/m/b1.flac", 3)] {
        conn.execute(
            "INSERT INTO file(id, path, mtime, size, track_id, added_at) VALUES (?1,?2,0,0,?3,0)",
            params![id, path, tid],
        )
        .unwrap();
    }
    conn
}

fn count(conn: &rusqlite::Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |r| r.get(0)).unwrap()
}

#[test]
fn remove_track_drops_the_track_and_its_file_but_keeps_siblings() {
    let conn = seed();
    remove_track(&conn, 2).unwrap(); // forget T2 from album R1

    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE id = 2"), 0);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM file WHERE track_id = 2"), 0);
    // Sibling T1, both releases, and the artist remain.
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE id = 1"), 1);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R1'"), 1);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R2'"), 1);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"), 1);
}

#[test]
fn remove_track_that_is_the_albums_last_track_prunes_the_album() {
    let conn = seed();
    remove_track(&conn, 3).unwrap(); // T3 is R2's only track

    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE id = 3"), 0);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R2'"), 0);
    // A1 still has R1, so artist + R1 stay.
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"), 1);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R1'"), 1);
}

#[test]
fn remove_album_drops_the_release_and_its_tracks_keeps_other_album() {
    let conn = seed();
    remove_album(&conn, "R1").unwrap();

    assert_eq!(count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R1'"), 0);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE release_mbid = 'R1'"), 0);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM file WHERE track_id IN (1,2)"), 0);
    // R2 + its track + the shared artist remain.
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R2'"), 1);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE id = 3"), 1);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"), 1);
}

#[test]
fn remove_albums_last_one_also_prunes_the_artist() {
    let conn = seed();
    remove_album(&conn, "R1").unwrap();
    remove_album(&conn, "R2").unwrap(); // artist now has no releases

    assert_eq!(count(&conn, "SELECT COUNT(*) FROM release"), 0);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track"), 0);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"), 0);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd rust && cargo test --test remove_entity_test`
Expected: FAIL to compile — `unresolved import rust_lib_olivier::catalog::deletes` (the module does not exist yet).

- [ ] **Step 3: Create the `deletes` module**

Create `rust/src/catalog/deletes.rs`:

```rust
use rusqlite::Connection;

use crate::catalog::scan;
use crate::decision_log::DecisionLog;

/// Forget a single track from the catalog: delete its file row(s); the
/// child-first orphan sweep then drops the now-fileless track (and its album /
/// artist if nothing of theirs remains). Files on disk are NOT touched.
pub fn remove_track(conn: &Connection, track_id: i64) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM file WHERE track_id = ?1",
        rusqlite::params![track_id],
    )?;
    scan::prune_orphans(conn, &DecisionLog::to_path(None))?;
    Ok(())
}

/// Forget an album (release) from the catalog: delete the file rows of all its
/// tracks; the orphan sweep then drops those tracks, the release, and the
/// album-artist if it has no other releases. Files on disk are NOT touched.
pub fn remove_album(conn: &Connection, release_mbid: &str) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM file WHERE track_id IN (SELECT id FROM track WHERE release_mbid = ?1)",
        rusqlite::params![release_mbid],
    )?;
    scan::prune_orphans(conn, &DecisionLog::to_path(None))?;
    Ok(())
}
```

In `rust/src/catalog/mod.rs`, add the module (alphabetical, first):

```rust
pub mod deletes;
pub mod ids;
pub mod query;
pub mod roots;
pub mod scan;
pub mod schema;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd rust && cargo test --test remove_entity_test`
Expected: PASS (4 tests).

- [ ] **Step 5: Add the FFI wrappers**

In `rust/src/api/catalog.rs`, add the import alongside the existing `use crate::catalog::...` lines:

```rust
use crate::catalog::deletes;
```

Then add these two functions after `remove_root` (the wrappers mirror `remove_root`'s `db::open` delegation):

```rust
pub fn remove_track(db_path: String, track_id: i64) -> anyhow::Result<()> {
    deletes::remove_track(&db::open(&db_path)?, track_id)
}

pub fn remove_album(db_path: String, release_mbid: String) -> anyhow::Result<()> {
    deletes::remove_album(&db::open(&db_path)?, &release_mbid)
}
```

Run: `cd rust && cargo build`
Expected: compiles (the new FFI functions do not require regen to compile the Rust crate).

- [ ] **Step 6: Lint**

Run: `mise exec -- precious lint --all`
Expected: clean (clippy `-D warnings`, rustfmt, etc.).

- [ ] **Step 7: Commit**

```bash
git add rust/src/catalog/deletes.rs rust/src/catalog/mod.rs rust/src/api/catalog.rs rust/tests/remove_entity_test.rs
git commit -m "$(cat <<'EOF'
Add remove_track / remove_album catalog FFI

Forget a single track or album from the catalog by deleting its file
rows and running the existing child-first prune_orphans sweep (same
file-driven model as remove_root). Files on disk are untouched.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Regenerate the flutter_rust_bridge bindings

**Files:**
- Regenerate: `lib/src/rust/**`, `rust/src/frb_generated.rs`

- [ ] **Step 1: Run codegen**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`
Expected: regenerates the bridge with no errors.

- [ ] **Step 2: Verify the new bindings exist**

Run: `grep -nE 'removeTrack|removeAlbum' lib/src/rust/api/catalog.dart`
Expected: shows `Future<void> removeTrack({required String dbPath, required int trackId})` and `Future<void> removeAlbum({required String dbPath, required String releaseMbid})` (exact parameter names confirm the Dart seam call sites in Tasks 4–5).

- [ ] **Step 3: Confirm the Dart side still analyzes**

Run: `mise exec -- flutter analyze`
Expected: No issues found.

- [ ] **Step 4: Commit the regenerated bridge**

```bash
git add lib/src/rust rust/src/frb_generated.rs
git commit -m "$(cat <<'EOF'
Regenerate bridge for remove_track / remove_album

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add the "Remove from library" item to RowContextMenu

**Files:**
- Modify: `lib/widgets/context_menu.dart`
- Test: `test/context_menu_test.dart`

- [ ] **Step 1: Write the failing test**

In `test/context_menu_test.dart`, add this test inside `main()` (after the existing tests):

```dart
  testWidgets('shows Remove from library and invokes onRemove', (tester) async {
    QueueEntityRef? removed;
    const entity = QueueEntityRef.album('rel-1');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RowContextMenu(
          entity: entity,
          onRemove: (e) => removed = e,
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

    expect(find.text('Remove from library'), findsOneWidget);
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();
    expect(removed, entity);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/context_menu_test.dart`
Expected: FAIL — `No named parameter with the name 'onRemove'` (the param does not exist yet).

- [ ] **Step 3: Add `onRemove` to RowContextMenu**

In `lib/widgets/context_menu.dart`:

Update the doc comment's action list to mention `onRemove`, then add the field + constructor param. The field block becomes:

```dart
  final QueueEntityRef entity;
  final ValueChanged<QueueEntityRef>? onAddToQueue;
  final ValueChanged<QueueEntityRef>? onInfo;
  final ValueChanged<QueueEntityRef>? onReadTags;
  final ValueChanged<QueueEntityRef>? onRefetch;
  final ValueChanged<QueueEntityRef>? onSetReading;
  final ValueChanged<QueueEntityRef>? onRemove;
  final Widget child;
```

And the constructor:

```dart
  const RowContextMenu({
    super.key,
    required this.entity,
    this.onAddToQueue,
    this.onInfo,
    this.onReadTags,
    this.onRefetch,
    this.onSetReading,
    this.onRemove,
    required this.child,
  });
```

Add the menu item last in the `items:` list (after the `onSetReading` item):

```dart
        if (onSetReading != null)
          const PopupMenuItem<String>(
              value: 'reading', child: Text('Set reading…')),
        if (onRemove != null)
          const PopupMenuItem<String>(
              value: 'remove', child: Text('Remove from library')),
```

Add the dispatch case in the `switch (selected)`:

```dart
      case 'reading':
        onSetReading?.call(entity);
      case 'remove':
        onRemove?.call(entity);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- flutter test test/context_menu_test.dart`
Expected: PASS.

- [ ] **Step 5: Format + analyze**

Run: `mise exec -- dart format lib/widgets/context_menu.dart test/context_menu_test.dart`
Run: `mise exec -- flutter analyze`
Expected: No issues.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/context_menu.dart test/context_menu_test.dart
git commit -m "$(cat <<'EOF'
Add Remove from library item to RowContextMenu

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Wire "Remove from library" into the album column

**Files:**
- Modify: `lib/state/providers.dart` (add `removeAlbumFnProvider`)
- Modify: `lib/catalog/album_column.dart` (pass `onRemove`)
- Test: `test/album_column_enqueue_test.dart`

- [ ] **Step 1: Write the failing test**

In `test/album_column_enqueue_test.dart`, add this test inside `main()` (after the existing tests). It imports nothing new — `removeAlbumFnProvider` resolves once Step 3 adds it:

```dart
  testWidgets('album menu "Remove from library" calls the seam + snackbar',
      (tester) async {
    final removed = <String>[];
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        albumsProvider.overrideWith((ref) => [_album]),
        queueControllerProvider.overrideWithValue(qc),
        removeAlbumFnProvider
            .overrideWithValue((mbid) async => removed.add(mbid)),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Album One')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Remove from library'), findsOneWidget);
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(removed, ['rel-1']);
    expect(find.text('Removed "Album One"'), findsOneWidget);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/album_column_enqueue_test.dart`
Expected: FAIL — `removeAlbumFnProvider` undefined (and, once defined, the menu item is absent until Step 4 wires `onRemove`).

- [ ] **Step 3: Add the album seam provider**

In `lib/state/providers.dart`, add after the `rereadAlbumTagsFnProvider` block (the `removeAlbum` symbol comes from the already-imported `package:olivier/src/rust/api/catalog.dart`):

```dart
// Forget one album (release) from the catalog (file rows deleted + orphan
// prune). Seam so the column is testable without the live FFI.
typedef RemoveAlbumFn = Future<void> Function(String releaseMbid);

final removeAlbumFnProvider = Provider<RemoveAlbumFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (releaseMbid) => removeAlbum(dbPath: db, releaseMbid: releaseMbid);
});
```

- [ ] **Step 4: Pass `onRemove` from the album row**

In `lib/catalog/album_column.dart`, add an `onRemove` handler to the `RowContextMenu` (mirroring the existing `onReadTags` handler — capture the messenger before the await, then invalidate the catalog providers, clear the selection, and show the snackbar). Insert it among the other `RowContextMenu` callbacks:

```dart
            onRemove: (_) async {
              final messenger = ScaffoldMessenger.of(context);
              await ref.read(removeAlbumFnProvider)(album.releaseMbid);
              ref.invalidate(artistsProvider);
              ref.invalidate(albumsProvider);
              ref.invalidate(tracksProvider);
              ref.read(selectedAlbumProvider.notifier).clear();
              messenger
                ..clearSnackBars()
                ..showSnackBar(
                    SnackBar(content: Text('Removed "${album.title}"')));
            },
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mise exec -- flutter test test/album_column_enqueue_test.dart`
Expected: PASS.

- [ ] **Step 6: Format + analyze**

Run: `mise exec -- dart format lib/state/providers.dart lib/catalog/album_column.dart test/album_column_enqueue_test.dart`
Run: `mise exec -- flutter analyze`
Expected: No issues.

- [ ] **Step 7: Commit**

```bash
git add lib/state/providers.dart lib/catalog/album_column.dart test/album_column_enqueue_test.dart
git commit -m "$(cat <<'EOF'
Wire Remove from library into the album column

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire "Remove from library" into the track column

**Files:**
- Modify: `lib/state/providers.dart` (add `removeTrackFnProvider`)
- Modify: `lib/catalog/track_column.dart` (pass `onRemove`)
- Test: `test/track_column_select_test.dart`

- [ ] **Step 1: Write the failing test**

In `test/track_column_select_test.dart`, add this test inside `main()` (after the existing tests). `_track` (id 7, title 'Song') and the helper overrides already exist in this file:

```dart
  testWidgets('track menu "Remove from library" calls the seam + snackbar',
      (tester) async {
    final removed = <int>[];
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
        queueControllerProvider.overrideWithValue(qc),
        removeTrackFnProvider.overrideWithValue((id) async => removed.add(id)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: TrackColumn()),
      ),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Remove from library'), findsOneWidget);
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(removed, [7]);
    expect(find.text('Removed "Song"'), findsOneWidget);
  });
```

Add `kSecondaryButton` to the existing `package:flutter/gestures.dart` import at the top of the file if it is not already shown there:

```dart
import 'package:flutter/gestures.dart' show kSecondaryButton;
```

(If the file already imports other gesture constants, add `kSecondaryButton` to that existing `show` list instead of adding a second import.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/track_column_select_test.dart`
Expected: FAIL — `removeTrackFnProvider` undefined (and the menu item absent until Step 4).

- [ ] **Step 3: Add the track seam provider**

In `lib/state/providers.dart`, add after the `removeAlbumFnProvider` block (`removeTrack` comes from the already-imported catalog bindings):

```dart
// Forget one track from the catalog (file rows deleted + orphan prune). Seam.
typedef RemoveTrackFn = Future<void> Function(int trackId);

final removeTrackFnProvider = Provider<RemoveTrackFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (trackId) => removeTrack(dbPath: db, trackId: trackId);
});
```

- [ ] **Step 4: Pass `onRemove` from the track row**

In `lib/catalog/track_column.dart`, add an `onRemove` handler to the `RowContextMenu` (mirroring the existing `onReadTags` handler):

```dart
                  onRemove: (_) async {
                    final messenger = ScaffoldMessenger.of(context);
                    await ref.read(removeTrackFnProvider)(track.id);
                    ref.invalidate(artistsProvider);
                    ref.invalidate(albumsProvider);
                    ref.invalidate(tracksProvider);
                    ref.read(selectedTrackProvider.notifier).clear();
                    messenger
                      ..clearSnackBars()
                      ..showSnackBar(
                          SnackBar(content: Text('Removed "${track.title}"')));
                  },
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mise exec -- flutter test test/track_column_select_test.dart`
Expected: PASS.

- [ ] **Step 6: Format + analyze**

Run: `mise exec -- dart format lib/state/providers.dart lib/catalog/track_column.dart test/track_column_select_test.dart`
Run: `mise exec -- flutter analyze`
Expected: No issues.

- [ ] **Step 7: Commit**

```bash
git add lib/state/providers.dart lib/catalog/track_column.dart test/track_column_select_test.dart
git commit -m "$(cat <<'EOF'
Wire Remove from library into the track column

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (before finishing the branch)

- [ ] `cd rust && cargo test` — all Rust tests green (includes `remove_entity_test`).
- [ ] `mise exec -- flutter test` — full Dart suite green.
- [ ] `just lint --all` — whole-project gate (dart format check + analyze + clippy + typos).
- [ ] Manual smoke (optional, `just run`): right-click an album → "Remove from library" → it disappears with a `Removed "<title>"` snackbar; same for a track; the audio file still exists on disk; a re-scan re-adds it.

## Touched files

| File | Change |
|------|--------|
| `rust/src/catalog/deletes.rs` | `remove_track`, `remove_album` (new) |
| `rust/src/catalog/mod.rs` | register `deletes` module |
| `rust/src/api/catalog.rs` | `remove_track`/`remove_album` FFI wrappers |
| `rust/tests/remove_entity_test.rs` | delete-cascade unit tests (new) |
| `lib/src/rust/**`, `rust/src/frb_generated.rs` | regenerated bridge |
| `lib/widgets/context_menu.dart` | `onRemove` + "Remove from library" item |
| `lib/state/providers.dart` | `removeAlbumFnProvider`, `removeTrackFnProvider` |
| `lib/catalog/album_column.dart` | wire `onRemove` (seam + invalidate + snackbar) |
| `lib/catalog/track_column.dart` | wire `onRemove` (seam + invalidate + snackbar) |
| `test/context_menu_test.dart`, `test/album_column_enqueue_test.dart`, `test/track_column_select_test.dart` | menu-item + wiring tests |
