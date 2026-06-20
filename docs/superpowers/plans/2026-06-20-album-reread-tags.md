# Album "Re-read tags" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Re-read tags" action to the album right-click menu that re-reads every track's on-disk tags.

**Architecture:** A thin `reread_album_tags(conn, release_mbid, log)` collects the album's track IDs then calls the existing `reread_track_tags` for each; exposed via an FFI + a Riverpod seam and wired onto the album column's existing `onReadTags` menu slot (invalidate + clear selection + snackbar).

**Tech Stack:** Rust (rusqlite, lofty), flutter_rust_bridge 2.x, Flutter + Riverpod.

**Spec:** `docs/superpowers/specs/2026-06-20-album-reread-tags-design.md`

**Conventions:** Rust tests `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test`; Dart `cd /home/autarch/projects/olivier && mise exec -- flutter test`. Commit trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. NEVER `git add` `TODO`/`#TODO#`. No remote. Ignore stale rust-analyzer diagnostics; trust `cargo`/`flutter test`.

---

## File Structure

- `rust/src/catalog/scan.rs` — new `reread_album_tags`.
- `rust/src/api/catalog.rs` — new FFI wrapper.
- `rust/src/frb_generated.rs`, `lib/src/rust/**` — regenerated bridge.
- `lib/state/providers.dart` — `rereadAlbumTagsFnProvider` seam.
- `lib/catalog/album_column.dart` — wire `onReadTags`.
- `rust/tests/catalog_test.rs`, `test/album_column_enqueue_test.dart` — tests.

---

### Task 1: Rust `reread_album_tags` + FFI

**Files:** `rust/src/catalog/scan.rs`, `rust/src/api/catalog.rs`, `rust/tests/catalog_test.rs`, regenerated bridge.

- [ ] **Step 1: Write the failing tests** — in `rust/tests/catalog_test.rs`, add `reread_album_tags` to the existing scan `use` (currently `use rust_lib_olivier::catalog::scan::{reconcile_album_artists, reread_track_tags, scan_roots};` → add `reread_album_tags`). Then add (these reuse the file's existing `seed_one_flac` helper + `DecisionLog`/`open` imports):

```rust
#[test]
fn reread_album_tags_is_a_noop_when_tags_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let (mut conn, track_id) = seed_one_flac(dir.path());
    let release: String = conn
        .query_row("SELECT release_mbid FROM track WHERE id = ?1", [track_id], |r| r.get(0))
        .unwrap();

    reread_album_tags(&mut conn, &release, &DecisionLog::to_path(None)).unwrap();

    // Unchanged file → counts stay at one each.
    for (table, n) in [("track", 1), ("file", 1), ("release", 1)] {
        let got: i64 = conn
            .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
            .unwrap();
        assert_eq!(got, n, "{table}");
    }
}

#[test]
fn reread_album_tags_applies_a_tag_change_across_the_album() {
    use lofty::config::{ParseOptions, WriteOptions};
    use lofty::file::AudioFile;
    use lofty::flac::FlacFile;

    let dir = tempfile::tempdir().unwrap();
    let (mut conn, track_id) = seed_one_flac(dir.path());
    let path = dir.path().join("sample.flac");
    let release_before: String = conn
        .query_row("SELECT release_mbid FROM track WHERE id = ?1", [track_id], |r| r.get(0))
        .unwrap();

    // Rewrite the album name + MB album id so the track re-homes to a new release.
    {
        let mut f = std::fs::File::open(&path).unwrap();
        let mut flac = FlacFile::read_from(&mut f, ParseOptions::new()).unwrap();
        let vc = flac.vorbis_comments_mut().unwrap();
        vc.insert("ALBUM".to_string(), "Some Other Album".to_string());
        vc.insert(
            "MUSICBRAINZ_ALBUMID".to_string(),
            "ffffffff-0000-0000-0000-000000000099".to_string(),
        );
        flac.save_to_path(&path, WriteOptions::default()).unwrap();
    }

    // Re-read via the ALBUM-level call (for the original release mbid).
    reread_album_tags(&mut conn, &release_before, &DecisionLog::to_path(None)).unwrap();

    // The file now resolves to the new release...
    let path_str = path.to_string_lossy().to_string();
    let release_after: String = conn
        .query_row(
            "SELECT t.release_mbid FROM file f JOIN track t ON t.id = f.track_id WHERE f.path = ?1",
            [&path_str],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(release_after, "ffffffff-0000-0000-0000-000000000099");
    // ...and the old, now-empty release was pruned.
    let old: i64 = conn
        .query_row("SELECT count(*) FROM release WHERE mbid = ?1", [&release_before], |r| r.get(0))
        .unwrap();
    assert_eq!(old, 0);
}
```

- [ ] **Step 2: Run them, verify FAIL** (`reread_album_tags` doesn't exist) — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test reread_album_tags`

- [ ] **Step 3: Add `reread_album_tags`** — in `rust/src/catalog/scan.rs`, add (place it right after the existing `reread_track_tags` function):

```rust
/// Re-read the on-disk tags of every track in a release, re-homing tracks whose
/// album/artist tags changed (per `reread_track_tags`). Track IDs are collected
/// before the loop because a re-home can move a track off this release mid-pass.
pub fn reread_album_tags(
    conn: &mut Connection,
    release_mbid: &str,
    log: &DecisionLog,
) -> anyhow::Result<()> {
    let track_ids: Vec<i64> = {
        let mut stmt = conn.prepare("SELECT id FROM track WHERE release_mbid = ?1")?;
        let ids = stmt
            .query_map([release_mbid], |r| r.get::<_, i64>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        ids
    };
    for id in track_ids {
        reread_track_tags(conn, id, log)?;
    }
    Ok(())
}
```

(If `Connection`/`DecisionLog` aren't already imported in `scan.rs`, they are — `reread_track_tags` uses both; no new imports needed.)

- [ ] **Step 4: Run them, verify PASS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test reread_album_tags`

- [ ] **Step 5: Add the FFI wrapper** — in `rust/src/api/catalog.rs`, add right after the existing `reread_track_tags` function:

```rust
pub fn reread_album_tags(db_path: String, release_mbid: String) -> anyhow::Result<()> {
    let mut conn = db::open(&db_path)?;
    let log = DecisionLog::for_db(&db_path);
    scan::reread_album_tags(&mut conn, &release_mbid, &log)
}
```

- [ ] **Step 6: Verify cargo still builds** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test 2>&1 | tail -4` (the new FFI fn compiles; it isn't bridged until the next step).

- [ ] **Step 7: Regenerate the bridge + confirm** — `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`, then `grep -rn 'rereadAlbumTags' lib/src/rust/api/catalog.dart | head` (should show `Future<void> rereadAlbumTags(...)`).

- [ ] **Step 8: Commit**
```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/scan.rs rust/src/api/catalog.rs rust/tests/catalog_test.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "Add reread_album_tags (re-read every track's tags in an album)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Dart seam + album menu wiring

**Files:** `lib/state/providers.dart`, `lib/catalog/album_column.dart`, `test/album_column_enqueue_test.dart`.

- [ ] **Step 1: Write the failing test** — add to `test/album_column_enqueue_test.dart` (it already imports `package:flutter/gestures.dart` (for `kSecondaryButton`), the providers, `AlbumColumn`, `QueueController`, `FakeQueuePlayer`, and defines `const _album` with `releaseMbid: 'rel-1'`):

```dart
  testWidgets('album menu "Re-read tags" calls the seam + shows a snackbar',
      (tester) async {
    final reread = <String>[];
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
        albumFilePathsFnProvider.overrideWithValue((mbid) async => []),
        rereadAlbumTagsFnProvider
            .overrideWithValue((mbid) async => reread.add(mbid)),
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

    expect(find.text('Re-read tags'), findsOneWidget);
    await tester.tap(find.text('Re-read tags'));
    await tester.pumpAndSettle();

    expect(reread, ['rel-1']);
    expect(find.text('Tags re-read'), findsOneWidget);
  });
```

- [ ] **Step 2: Run it, verify FAILS** (`rereadAlbumTagsFnProvider` doesn't exist; the menu item isn't wired) — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/album_column_enqueue_test.dart`

- [ ] **Step 3: Add the seam** — in `lib/state/providers.dart`, add right after the `rereadTrackTagsFnProvider` block:

```dart
// Re-read every track's tags for one album (re-homes any whose album changed). Seam.
typedef RereadAlbumTagsFn = Future<void> Function(String releaseMbid);

final rereadAlbumTagsFnProvider = Provider<RereadAlbumTagsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (releaseMbid) => rereadAlbumTags(dbPath: db, releaseMbid: releaseMbid);
});
```

(`rereadAlbumTags` is the generated bridge function from `package:olivier/src/rust/api/catalog.dart`, already imported in `providers.dart`.)

- [ ] **Step 4: Wire `onReadTags` on the album column** — in `lib/catalog/album_column.dart`, in the album row's `RowContextMenu`, add (e.g. right after the existing `onRefetch: (_) { … },` block):

```dart
            onReadTags: (_) async {
              final messenger = ScaffoldMessenger.of(context);
              await ref.read(rereadAlbumTagsFnProvider)(album.releaseMbid);
              ref.invalidate(artistsProvider);
              ref.invalidate(albumsProvider);
              ref.invalidate(tracksProvider);
              ref.read(selectedAlbumProvider.notifier).clear();
              messenger
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(content: Text('Tags re-read')));
            },
```

- [ ] **Step 5: Run it, verify PASS** — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/album_column_enqueue_test.dart`

- [ ] **Step 6: Full verification**
```bash
cd /home/autarch/projects/olivier && mise exec -- flutter test 2>&1 | tail -2
cd /home/autarch/projects/olivier && mise exec -- flutter analyze lib/state/providers.dart lib/catalog/album_column.dart 2>&1 | tail -3
cd /home/autarch/projects/olivier/rust && mise exec -- cargo test 2>&1 | tail -4
```
Expected: all green. (A `precious lint --all` `typos` hit on the untracked `TODO` is the user's note — ignore.)

- [ ] **Step 7: Format + commit**
```bash
cd /home/autarch/projects/olivier
mise exec -- dart format lib/state/providers.dart lib/catalog/album_column.dart test/album_column_enqueue_test.dart
git add lib/state/providers.dart lib/catalog/album_column.dart test/album_column_enqueue_test.dart
git commit -m "Album menu: Re-read tags action

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- `reread_album_tags` (collect IDs + reuse `reread_track_tags`) + FFI + bridge → Task 1. ✓
- Rust tests: no-op + tag-change/re-home via the album-level call → Task 1. ✓
- `rereadAlbumTagsFnProvider` seam → Task 2. ✓
- Album `onReadTags` wiring (invalidate artists/albums/tracks + clear selectedAlbum + snackbar) → Task 2. ✓
- Dart test: menu shows "Re-read tags" + invokes the seam → Task 2. ✓
- Track menu unchanged (re-fetch dropped) → not touched. ✓

**Type consistency:** Rust `reread_album_tags(conn, release_mbid, log)` ↔ FFI `reread_album_tags(db_path, release_mbid)` ↔ Dart `rereadAlbumTags(dbPath, releaseMbid)` ↔ seam `RereadAlbumTagsFn(String releaseMbid)` — consistent. `selectedAlbumProvider.notifier.clear()` exists (verified). The Dart test reuses the existing `_album` (`releaseMbid: 'rel-1'`) and asserts `reread == ['rel-1']`.

**Placeholders:** none — every step has exact code. Adding a new FFI *function* (not struct) doesn't break `frb_generated.rs` compilation before regen, so cargo passes at Step 6 and the bridge is regenerated at Step 7.
