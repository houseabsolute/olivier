# Playlists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persistent, named, manually-ordered playlists with a dedicated master-detail page, "Add to playlist…" from browse rows, and Play / Shuffle / Add-to-queue actions — entries pruned automatically when files leave the library.

**Architecture:** Two new SQLite tables (`playlist`, `playlist_item`) mirroring the path-based queue, with `playlist_item.path` carrying a `REFERENCES file(path) ON DELETE CASCADE` so removals prune entries with no app code. A Rust store module + auto-bridged FFI; a Dart state layer (AsyncNotifier + FFI seams); a Playlists page and an add-to-playlist dialog. Playback reuses existing `QueueController` methods via a small seam.

**Tech Stack:** Rust + rusqlite + rusqlite_migration; flutter_rust_bridge 2.12.0; Flutter + Riverpod 3.x.

**Spec:** `docs/superpowers/specs/2026-06-24-playlists-design.md`

**Conventions:**
- Rust tests: `cd rust && cargo test`. Flutter: `mise exec -- flutter test <path>`. Codegen: `mise exec -- flutter_rust_bridge_codegen generate`. Lint gate: `just lint --all`.
- Riverpod: use `state.value` (no `valueOrNull`). flutter_rust_bridge maps `i64` to Dart `int` on native.
- NEVER `git add` the `TODO` file. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `rust/src/db.rs` (modify) — append the playlists migration.
- `rust/src/catalog/playlists.rs` (create) — `Playlist` struct + store fns.
- `rust/src/catalog/mod.rs` (modify) — `pub mod playlists;`.
- `rust/src/api/playlists.rs` (create) — thin `db_path` FFI wrappers.
- `rust/src/api/mod.rs` (modify) — `pub mod playlists;`.
- `rust/tests/playlists_test.rs` (create) — store + cascade tests.
- `lib/src/rust/**` (generated) — regenerated bridge.
- `lib/state/playlists.dart` (create) — providers, FFI seams, `PlaylistsNotifier`, playback seam.
- `lib/playlists/playlists_page.dart` (create) — master-detail page + `reordered` helper.
- `lib/playlists/add_to_playlist_dialog.dart` (create) — picker/create dialog.
- `lib/widgets/context_menu.dart` (modify) — `onAddToPlaylist`.
- `lib/catalog/{artist,album,track}_column.dart` (modify) — wire `onAddToPlaylist`.
- `lib/catalog/browser_page.dart` (modify) — app-bar Playlists icon.
- `test/playlists_state_test.dart`, `test/playlists_page_test.dart`, `test/add_to_playlist_dialog_test.dart`, `test/reordered_test.dart` (create).

---

## Task 1: Rust — migration + playlist store + store tests

**Files:**
- Modify: `rust/src/db.rs`
- Create: `rust/src/catalog/playlists.rs`
- Modify: `rust/src/catalog/mod.rs`
- Test: `rust/tests/playlists_test.rs`

- [ ] **Step 1: Write the failing test** — create `rust/tests/playlists_test.rs`:

```rust
use rusqlite::params;
use rust_lib_olivier::catalog::playlists::*;
use rust_lib_olivier::db::open;

/// One artist/release with three tracks + files (so playlist_item's FK to
/// file(path) is satisfiable). open(":memory:") runs the migrations.
fn seed() -> rusqlite::Connection {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('A1','A','A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R1','A1','Alb')",
        [],
    )
    .unwrap();
    for (id, pos) in [(1, 1), (2, 2), (3, 3)] {
        conn.execute(
            "INSERT INTO track(id,release_mbid,disc,position,title) VALUES (?1,'R1',1,?2,'T')",
            params![id, pos],
        )
        .unwrap();
    }
    for (id, path, tid) in [(1, "/m/a.flac", 1), (2, "/m/b.flac", 2), (3, "/m/c.flac", 3)] {
        conn.execute(
            "INSERT INTO file(id,path,mtime,size,track_id,added_at) VALUES (?1,?2,0,0,?3,0)",
            params![id, path, tid],
        )
        .unwrap();
    }
    conn
}

fn s(x: &str) -> String {
    x.to_string()
}

#[test]
fn create_list_and_count() {
    let conn = seed();
    let p1 = create_playlist(&conn, "First").unwrap();
    let _p2 = create_playlist(&conn, "Second").unwrap();
    add_to_playlist(&conn, p1, &[s("/m/a.flac"), s("/m/b.flac")]).unwrap();

    let lists = list_playlists(&conn).unwrap();
    assert_eq!(lists.len(), 2);
    assert_eq!(lists[0].name, "First"); // ordered by position (creation order)
    assert_eq!(lists[0].count, 2);
    assert_eq!(lists[1].name, "Second");
    assert_eq!(lists[1].count, 0);
}

#[test]
fn add_preserves_order_and_duplicates() {
    let conn = seed();
    let p = create_playlist(&conn, "P").unwrap();
    add_to_playlist(&conn, p, &[s("/m/c.flac"), s("/m/a.flac"), s("/m/a.flac")]).unwrap();

    let paths: Vec<String> = playlist_tracks(&conn, p).unwrap().into_iter().map(|t| t.path).collect();
    assert_eq!(paths, vec![s("/m/c.flac"), s("/m/a.flac"), s("/m/a.flac")]);
}

#[test]
fn set_items_rewrites_order_and_removes() {
    let conn = seed();
    let p = create_playlist(&conn, "P").unwrap();
    add_to_playlist(&conn, p, &[s("/m/a.flac"), s("/m/b.flac"), s("/m/c.flac")]).unwrap();
    set_playlist_items(&conn, p, &[s("/m/c.flac"), s("/m/a.flac")]).unwrap();

    let paths: Vec<String> = playlist_tracks(&conn, p).unwrap().into_iter().map(|t| t.path).collect();
    assert_eq!(paths, vec![s("/m/c.flac"), s("/m/a.flac")]);
}

#[test]
fn rename_and_delete_cascade() {
    let conn = seed();
    let p = create_playlist(&conn, "Old").unwrap();
    add_to_playlist(&conn, p, &[s("/m/a.flac")]).unwrap();
    rename_playlist(&conn, p, "New").unwrap();
    assert_eq!(list_playlists(&conn).unwrap()[0].name, "New");

    delete_playlist(&conn, p).unwrap();
    assert!(list_playlists(&conn).unwrap().is_empty());
    let items: i64 = conn
        .query_row("SELECT COUNT(*) FROM playlist_item", [], |r| r.get(0))
        .unwrap();
    assert_eq!(items, 0, "deleting a playlist cascades its items");
}

#[test]
fn reorder_playlists_changes_listing_order() {
    let conn = seed();
    let a = create_playlist(&conn, "A").unwrap();
    let b = create_playlist(&conn, "B").unwrap();
    let c = create_playlist(&conn, "C").unwrap();
    reorder_playlists(&conn, &[c, a, b]).unwrap();

    let names: Vec<String> = list_playlists(&conn).unwrap().into_iter().map(|p| p.name).collect();
    assert_eq!(names, vec![s("C"), s("A"), s("B")]);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test --test playlists_test`
Expected: FAIL — `rust_lib_olivier::catalog::playlists` does not exist.

- [ ] **Step 3a: Append the migration** in `rust/src/db.rs`, as the LAST element of `MIGRATION_SLICE` (immediately before the closing `];`):

```rust
    // ── Playlists ────────────────────────────────────────────────────────
    M::up(
        "CREATE TABLE playlist (
            id          INTEGER PRIMARY KEY,
            name        TEXT NOT NULL,
            position    INTEGER NOT NULL,
            created_at  INTEGER NOT NULL
         );
         CREATE TABLE playlist_item (
            playlist_id INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
            position    INTEGER NOT NULL,
            path        TEXT NOT NULL REFERENCES file(path) ON DELETE CASCADE,
            PRIMARY KEY (playlist_id, position)
         );
         CREATE INDEX idx_playlist_item_path ON playlist_item(path);",
    ),
```

- [ ] **Step 3b: Register the module** — in `rust/src/catalog/mod.rs`, add (keeping the list alphabetical, after `pub mod ids;`):

```rust
pub mod playlists;
```

- [ ] **Step 3c: Create the store** — `rust/src/catalog/playlists.rs`:

```rust
use rusqlite::{params, Connection};

use crate::catalog::query;
use crate::catalog::schema::QueueTrack;

/// A playlist with its track count (for the list view).
#[derive(Debug, Clone)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    pub count: i64,
}

fn now_secs() -> anyhow::Result<i64> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64)
}

/// Create a playlist appended after the last one; returns its id.
pub fn create_playlist(conn: &Connection, name: &str) -> anyhow::Result<i64> {
    let pos: i64 = conn.query_row(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist",
        [],
        |r| r.get(0),
    )?;
    conn.execute(
        "INSERT INTO playlist(name, position, created_at) VALUES (?1, ?2, ?3)",
        params![name, pos, now_secs()?],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn rename_playlist(conn: &Connection, id: i64, name: &str) -> anyhow::Result<()> {
    conn.execute(
        "UPDATE playlist SET name = ?2 WHERE id = ?1",
        params![id, name],
    )?;
    Ok(())
}

/// Delete a playlist; its items cascade away.
pub fn delete_playlist(conn: &Connection, id: i64) -> anyhow::Result<()> {
    conn.execute("DELETE FROM playlist WHERE id = ?1", params![id])?;
    Ok(())
}

/// Set the manual order of playlists to `ids` (index becomes position).
pub fn reorder_playlists(conn: &Connection, ids: &[i64]) -> anyhow::Result<()> {
    let tx = conn.unchecked_transaction()?;
    for (i, id) in ids.iter().enumerate() {
        tx.execute(
            "UPDATE playlist SET position = ?2 WHERE id = ?1",
            params![id, i as i64],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn list_playlists(conn: &Connection) -> anyhow::Result<Vec<Playlist>> {
    let mut stmt = conn.prepare(
        "SELECT p.id, p.name, COUNT(pi.path)
         FROM playlist p
         LEFT JOIN playlist_item pi ON pi.playlist_id = p.id
         GROUP BY p.id
         ORDER BY p.position",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(Playlist {
            id: r.get(0)?,
            name: r.get(1)?,
            count: r.get(2)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// The playlist's tracks, in order (duplicates preserved), with catalog metadata.
pub fn playlist_tracks(conn: &Connection, id: i64) -> anyhow::Result<Vec<QueueTrack>> {
    let paths: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT path FROM playlist_item WHERE playlist_id = ?1 ORDER BY position")?;
        stmt.query_map([id], |r| r.get(0))?
            .collect::<Result<_, _>>()?
    };
    query::tracks_for_paths(conn, &paths)
}

/// Append paths to the end of a playlist.
pub fn add_to_playlist(conn: &Connection, id: i64, paths: &[String]) -> anyhow::Result<()> {
    let tx = conn.unchecked_transaction()?;
    let mut pos: i64 = tx.query_row(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_item WHERE playlist_id = ?1",
        params![id],
        |r| r.get(0),
    )?;
    for p in paths {
        tx.execute(
            "INSERT INTO playlist_item(playlist_id, position, path) VALUES (?1, ?2, ?3)",
            params![id, pos, p],
        )?;
        pos += 1;
    }
    tx.commit()?;
    Ok(())
}

/// Replace a playlist's items with `paths` (in order). Backs reorder + remove.
pub fn set_playlist_items(conn: &Connection, id: i64, paths: &[String]) -> anyhow::Result<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "DELETE FROM playlist_item WHERE playlist_id = ?1",
        params![id],
    )?;
    for (i, p) in paths.iter().enumerate() {
        tx.execute(
            "INSERT INTO playlist_item(playlist_id, position, path) VALUES (?1, ?2, ?3)",
            params![id, i as i64, p],
        )?;
    }
    tx.commit()?;
    Ok(())
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd rust && cargo test --test playlists_test`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add rust/src/db.rs rust/src/catalog/mod.rs rust/src/catalog/playlists.rs rust/tests/playlists_test.rs
git commit -m "$(cat <<'EOF'
Add playlist tables + store (create/list/add/setItems/reorder)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Rust — remove-from-library cascade tests

Validates the FK cascade: genuine removals prune entries; a tag-read upsert does not. No production code — the FK from Task 1 is the mechanism.

**Files:**
- Test: `rust/tests/playlists_test.rs` (append)

- [ ] **Step 1: Append the failing tests** to `rust/tests/playlists_test.rs`:

```rust
use rust_lib_olivier::catalog::deletes::{remove_album, remove_track};

#[test]
fn removing_album_from_library_prunes_playlist_entries() {
    let conn = seed();
    let p = create_playlist(&conn, "P").unwrap();
    add_to_playlist(&conn, p, &[s("/m/a.flac"), s("/m/b.flac"), s("/m/c.flac")]).unwrap();

    remove_album(&conn, "R1").unwrap(); // deletes the file rows -> cascade

    assert!(
        playlist_tracks(&conn, p).unwrap().is_empty(),
        "tracks removed from the library must cascade out of playlists"
    );
}

#[test]
fn removing_one_track_prunes_only_that_entry() {
    let conn = seed();
    let p = create_playlist(&conn, "P").unwrap();
    add_to_playlist(&conn, p, &[s("/m/a.flac"), s("/m/b.flac")]).unwrap();

    remove_track(&conn, 1).unwrap(); // /m/a.flac

    let paths: Vec<String> = playlist_tracks(&conn, p).unwrap().into_iter().map(|t| t.path).collect();
    assert_eq!(paths, vec![s("/m/b.flac")]);
}

#[test]
fn re_upserting_a_file_keeps_playlist_entries() {
    // reread_track_tags upserts files with ON CONFLICT(path) DO UPDATE — a true
    // update, not a delete — so it must NOT trip the ON DELETE CASCADE.
    let conn = seed();
    let p = create_playlist(&conn, "P").unwrap();
    add_to_playlist(&conn, p, &[s("/m/a.flac")]).unwrap();

    conn.execute(
        "INSERT INTO file(path, mtime, size, track_id, added_at)
         VALUES ('/m/a.flac', 99, 99, 1, 0)
         ON CONFLICT(path) DO UPDATE SET mtime = 99, size = 99",
        [],
    )
    .unwrap();

    assert_eq!(
        playlist_tracks(&conn, p).unwrap().len(),
        1,
        "a tag re-read (upsert) must not drop playlist entries"
    );
}
```

- [ ] **Step 2: Run** — `cd rust && cargo test --test playlists_test` — Expected: PASS (8 tests total). If the cascade tests fail, the migration's FK in Task 1 is wrong (check `path TEXT NOT NULL REFERENCES file(path) ON DELETE CASCADE`).

- [ ] **Step 3: Commit**

```bash
git add rust/tests/playlists_test.rs
git commit -m "$(cat <<'EOF'
Test playlist FK cascade: removal prunes, re-read preserves

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rust — FFI wrappers + regenerate bridge

**Files:**
- Create: `rust/src/api/playlists.rs`
- Modify: `rust/src/api/mod.rs`
- Generated: `rust/src/frb_generated.rs`, `lib/src/rust/**`

- [ ] **Step 1: Create the wrappers** — `rust/src/api/playlists.rs`:

```rust
use crate::catalog::playlists::{self, Playlist};
use crate::catalog::schema::QueueTrack;
use crate::db;

pub fn create_playlist(db_path: String, name: String) -> anyhow::Result<i64> {
    playlists::create_playlist(&db::open(&db_path)?, &name)
}

pub fn rename_playlist(db_path: String, id: i64, name: String) -> anyhow::Result<()> {
    playlists::rename_playlist(&db::open(&db_path)?, id, &name)
}

pub fn delete_playlist(db_path: String, id: i64) -> anyhow::Result<()> {
    playlists::delete_playlist(&db::open(&db_path)?, id)
}

pub fn reorder_playlists(db_path: String, ids: Vec<i64>) -> anyhow::Result<()> {
    playlists::reorder_playlists(&db::open(&db_path)?, &ids)
}

pub fn list_playlists(db_path: String) -> anyhow::Result<Vec<Playlist>> {
    playlists::list_playlists(&db::open(&db_path)?)
}

pub fn playlist_tracks(db_path: String, id: i64) -> anyhow::Result<Vec<QueueTrack>> {
    playlists::playlist_tracks(&db::open(&db_path)?, id)
}

pub fn add_to_playlist(db_path: String, id: i64, paths: Vec<String>) -> anyhow::Result<()> {
    playlists::add_to_playlist(&db::open(&db_path)?, id, &paths)
}

pub fn set_playlist_items(db_path: String, id: i64, paths: Vec<String>) -> anyhow::Result<()> {
    playlists::set_playlist_items(&db::open(&db_path)?, id, &paths)
}
```

- [ ] **Step 2: Register** — in `rust/src/api/mod.rs`, add (alphabetical, after `pub mod enrich;`):

```rust
pub mod playlists;
```

- [ ] **Step 3: Regenerate the bridge**

Run: `mise exec -- flutter_rust_bridge_codegen generate`
Expected: regenerates `rust/src/frb_generated.rs` and writes `lib/src/rust/api/playlists.dart` + `lib/src/rust/catalog/playlists.dart` (the `Playlist` class). No errors.

- [ ] **Step 4: Verify it builds + analyzes**

Run: `cd rust && cargo build` — Expected: success.
Run: `mise exec -- flutter analyze` — Expected: no new issues.

- [ ] **Step 5: Commit** (include all generated files)

```bash
git add rust/src/api/playlists.rs rust/src/api/mod.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "$(cat <<'EOF'
Add playlists FFI + regenerate bridge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Dart — state (providers, seams, notifier, playback seam)

**Files:**
- Create: `lib/state/playlists.dart`
- Test: `test/playlists_state_test.dart`

- [ ] **Step 1: Write the failing test** — `test/playlists_state_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/state/playlists.dart';

/// In-memory fake of the playlist FFI so the notifier is testable without the
/// bridge. Records calls and behaves enough for refresh assertions.
class _FakeStore {
  final List<Playlist> lists = [];
  final List<String> calls = [];
  int _nextId = 1;

  PlaylistFns fns() => PlaylistFns(
        list: () async {
          calls.add('list');
          return List.of(lists);
        },
        create: (name) async {
          calls.add('create:$name');
          final id = _nextId++;
          lists.add(Playlist(id: id, name: name, count: 0));
          return id;
        },
        rename: (id, name) async => calls.add('rename:$id:$name'),
        delete: (id) async {
          calls.add('delete:$id');
          lists.removeWhere((p) => p.id == id);
        },
        reorder: (ids) async => calls.add('reorder:${ids.join(",")}'),
        tracks: (id) async {
          calls.add('tracks:$id');
          return [];
        },
        add: (id, paths) async => calls.add('add:$id:${paths.join(",")}'),
        setItems: (id, paths) async => calls.add('set:$id:${paths.join(",")}'),
      );
}

void main() {
  ProviderContainer containerWith(_FakeStore store) {
    final c = ProviderContainer(overrides: [
      playlistFnsProvider.overrideWithValue(store.fns()),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('build loads the list', () async {
    final store = _FakeStore()..lists.add(const Playlist(id: 1, name: 'X', count: 0));
    final c = containerWith(store);
    final lists = await c.read(playlistsProvider.future);
    expect(lists.map((p) => p.name), ['X']);
  });

  test('create then refresh', () async {
    final store = _FakeStore();
    final c = containerWith(store);
    await c.read(playlistsProvider.future);
    final id = await c.read(playlistsProvider.notifier).create('New');
    expect(id, 1);
    expect(store.calls, contains('create:New'));
    expect(c.read(playlistsProvider).value!.map((p) => p.name), ['New']);
  });

  test('reorder and setItems and add forward to the store', () async {
    final store = _FakeStore();
    final c = containerWith(store);
    await c.read(playlistsProvider.future);
    final n = c.read(playlistsProvider.notifier);
    await n.reorder([3, 1, 2]);
    await n.setItems(7, ['/m/a.flac']);
    await n.addTracks(7, ['/m/b.flac']);
    expect(store.calls, containsAll(['reorder:3,1,2', 'set:7:/m/a.flac', 'add:7:/m/b.flac']));
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/playlists_state_test.dart`
Expected: FAIL — `lib/state/playlists.dart` / `PlaylistFns` don't exist.

- [ ] **Step 3: Implement** — `lib/state/playlists.dart`:

```dart
// frb maps Vec<i64> to ITS OWN Int64List (a TypedList), not dart:typed_data's.
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/src/rust/api/playlists.dart' as ffi;
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

/// FFI seam bundle so the notifier/page are testable without the bridge.
class PlaylistFns {
  const PlaylistFns({
    required this.list,
    required this.create,
    required this.rename,
    required this.delete,
    required this.reorder,
    required this.tracks,
    required this.add,
    required this.setItems,
  });

  final Future<List<Playlist>> Function() list;
  final Future<int> Function(String name) create;
  final Future<void> Function(int id, String name) rename;
  final Future<void> Function(int id) delete;
  final Future<void> Function(List<int> ids) reorder;
  final Future<List<QueueTrack>> Function(int id) tracks;
  final Future<void> Function(int id, List<String> paths) add;
  final Future<void> Function(int id, List<String> paths) setItems;
}

final playlistFnsProvider = Provider<PlaylistFns>((ref) {
  final db = ref.watch(dbPathProvider);
  return PlaylistFns(
    list: () => ffi.listPlaylists(dbPath: db),
    create: (name) => ffi.createPlaylist(dbPath: db, name: name),
    rename: (id, name) => ffi.renamePlaylist(dbPath: db, id: id, name: name),
    delete: (id) => ffi.deletePlaylist(dbPath: db, id: id),
    reorder: (ids) => ffi.reorderPlaylists(dbPath: db, ids: Int64List.fromList(ids)),
    tracks: (id) => ffi.playlistTracks(dbPath: db, id: id),
    add: (id, paths) => ffi.addToPlaylist(dbPath: db, id: id, paths: paths),
    setItems: (id, paths) =>
        ffi.setPlaylistItems(dbPath: db, id: id, paths: paths),
  );
});

class PlaylistsNotifier extends AsyncNotifier<List<Playlist>> {
  PlaylistFns get _fns => ref.read(playlistFnsProvider);

  @override
  Future<List<Playlist>> build() => _fns.list();

  Future<void> _refresh() async {
    state = await AsyncValue.guard(_fns.list);
  }

  Future<int> create(String name) async {
    final id = await _fns.create(name);
    await _refresh();
    return id;
  }

  Future<void> rename(int id, String name) async {
    await _fns.rename(id, name);
    await _refresh();
  }

  Future<void> delete(int id) async {
    await _fns.delete(id);
    await _refresh();
  }

  Future<void> reorder(List<int> ids) async {
    await _fns.reorder(ids);
    await _refresh();
  }

  Future<void> addTracks(int id, List<String> paths) async {
    await _fns.add(id, paths);
    ref.invalidate(playlistTracksProvider(id));
    await _refresh();
  }

  Future<void> setItems(int id, List<String> paths) async {
    await _fns.setItems(id, paths);
    ref.invalidate(playlistTracksProvider(id));
    await _refresh();
  }
}

final playlistsProvider =
    AsyncNotifierProvider<PlaylistsNotifier, List<Playlist>>(
        PlaylistsNotifier.new);

class SelectedPlaylist extends Notifier<int?> {
  @override
  int? build() => null;
  void select(int? id) => state = id;
}

final selectedPlaylistProvider =
    NotifierProvider<SelectedPlaylist, int?>(SelectedPlaylist.new);

final playlistTracksProvider =
    FutureProvider.family<List<QueueTrack>, int>((ref, id) {
  return ref.watch(playlistFnsProvider).tracks(id);
});

/// Playback seam: maps the three playlist actions onto QueueController, so the
/// page is testable without a live player.
class PlaylistPlayback {
  const PlaylistPlayback({
    required this.play,
    required this.shuffle,
    required this.addToQueue,
  });
  final Future<void> Function(List<String> paths) play;
  final Future<void> Function(List<String> paths) shuffle;
  final Future<void> Function(List<String> paths) addToQueue;
}

final playlistPlaybackProvider = Provider<PlaylistPlayback>((ref) {
  final qc = ref.read(queueControllerProvider);
  return PlaylistPlayback(
    play: (paths) async {
      await qc.setQueue(paths);
      await qc.playAt(0);
    },
    shuffle: (paths) => qc.replaceLibraryShuffled(paths),
    addToQueue: (paths) => qc.append(paths),
  );
});
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/playlists_state_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/state/playlists.dart test/playlists_state_test.dart
git commit -m "$(cat <<'EOF'
Add playlists Dart state (providers, FFI seams, playback seam)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Dart — Playlists page + reorder helper + app-bar entry

**Files:**
- Create: `lib/playlists/playlists_page.dart`
- Modify: `lib/catalog/browser_page.dart`
- Test: `test/reordered_test.dart`, `test/playlists_page_test.dart`

- [ ] **Step 1: Write the failing reorder-helper test** — `test/reordered_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/playlists/playlists_page.dart';

void main() {
  test('reordered moves an item down (ReorderableListView convention)', () {
    expect(reordered([0, 1, 2, 3], 0, 2), [1, 0, 2, 3]);
  });
  test('reordered moves an item up', () {
    expect(reordered([0, 1, 2, 3], 3, 1), [0, 3, 1, 2]);
  });
}
```

- [ ] **Step 2: Write the failing page test** — `test/playlists_page_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/playlists/playlists_page.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';

QueueTrack _track(String path, String title) => QueueTrack(
      path: path,
      trackId: null,
      title: title,
      artist: 'Artist',
      album: 'Album',
      albumArtist: null,
      albumArtistOriginal: null,
      albumArtistReading: null,
      lengthMs: null,
      addedAt: 0, // PlatformInt64 == int on native
      lastPlayed: null,
      titleTranslit: null,
      titleTranslate: null,
      recordingMbid: null,
      albumArtistMbid: null,
    );

void main() {
  late List<String> played;
  late List<String> setItemsCalls;

  PlaylistFns fakeFns(List<Playlist> lists, Map<int, List<QueueTrack>> tracks) =>
      PlaylistFns(
        list: () async => List.of(lists),
        create: (name) async => 99,
        rename: (id, name) async {},
        delete: (id) async {},
        reorder: (ids) async {},
        tracks: (id) async => tracks[id] ?? const [],
        add: (id, paths) async {},
        setItems: (id, paths) async => setItemsCalls.add(paths.join(',')),
      );

  Widget harness(List<Override> overrides) => ProviderScope(
        overrides: [
          getSettingFnProvider.overrideWithValue((k) async => null),
          ...overrides,
        ],
        child: const MaterialApp(home: PlaylistsPage()),
      );

  setUp(() {
    played = [];
    setItemsCalls = [];
  });

  testWidgets('shows playlists and their tracks on selection', (tester) async {
    await tester.pumpWidget(harness([
      playlistFnsProvider.overrideWithValue(fakeFns(
        [const Playlist(id: 1, name: 'Roadtrip', count: 2)],
        {
          1: [_track('/m/a.flac', 'Song A'), _track('/m/b.flac', 'Song B')]
        },
      )),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Roadtrip'), findsOneWidget);
    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Song B'), findsOneWidget);
  });

  testWidgets('Play sends the playlist paths to the playback seam',
      (tester) async {
    await tester.pumpWidget(harness([
      playlistFnsProvider.overrideWithValue(fakeFns(
        [const Playlist(id: 1, name: 'Roadtrip', count: 2)],
        {
          1: [_track('/m/a.flac', 'Song A'), _track('/m/b.flac', 'Song B')]
        },
      )),
      playlistPlaybackProvider.overrideWithValue(PlaylistPlayback(
        play: (paths) async => played
          ..clear()
          ..addAll(paths),
        shuffle: (paths) async {},
        addToQueue: (paths) async {},
      )),
    ]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Play'));
    await tester.pumpAndSettle();
    expect(played, ['/m/a.flac', '/m/b.flac']);
  });
}
```

- [ ] **Step 3: Run both to verify they fail**

Run: `mise exec -- flutter test test/reordered_test.dart test/playlists_page_test.dart`
Expected: FAIL — `lib/playlists/playlists_page.dart` doesn't exist.

- [ ] **Step 4: Implement the page** — `lib/playlists/playlists_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';

/// Pure reorder helper using ReorderableListView's index convention (when an
/// item moves down, newIndex counts the slot it's leaving).
List<T> reordered<T>(List<T> items, int oldIndex, int newIndex) {
  final copy = List<T>.of(items);
  var to = newIndex;
  if (to > oldIndex) to -= 1;
  final item = copy.removeAt(oldIndex);
  copy.insert(to, item);
  return copy;
}

class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New playlist',
            onPressed: () => _newPlaylist(context, ref),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          SizedBox(width: 280, child: _PlaylistSidebar()),
          VerticalDivider(width: 1),
          Expanded(child: _PlaylistDetail()),
        ],
      ),
    );
  }
}

Future<void> _newPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await _promptName(context, title: 'New playlist');
  if (name == null || name.trim().isEmpty) return;
  final id = await ref.read(playlistsProvider.notifier).create(name.trim());
  ref.read(selectedPlaylistProvider.notifier).select(id);
}

Future<String?> _promptName(BuildContext context,
    {required String title, String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('OK')),
      ],
    ),
  );
}

class _PlaylistSidebar extends ConsumerWidget {
  const _PlaylistSidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(playlistsProvider);
    final selected = ref.watch(selectedPlaylistProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load playlists: $e')),
      data: (lists) {
        if (lists.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No playlists yet. Use + to create one.'),
            ),
          );
        }
        return ReorderableListView.builder(
          itemCount: lists.length,
          onReorder: (oldIndex, newIndex) {
            final ids = reordered(lists, oldIndex, newIndex)
                .map((p) => p.id)
                .toList();
            ref.read(playlistsProvider.notifier).reorder(ids);
          },
          itemBuilder: (context, i) {
            final p = lists[i];
            return ListTile(
              key: ValueKey(p.id),
              title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${p.count} track${p.count == 1 ? '' : 's'}'),
              selected: p.id == selected,
              onTap: () =>
                  ref.read(selectedPlaylistProvider.notifier).select(p.id),
            );
          },
        );
      },
    );
  }
}

class _PlaylistDetail extends ConsumerWidget {
  const _PlaylistDetail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(selectedPlaylistProvider);
    if (id == null) {
      return const Center(child: Text('Select a playlist'));
    }
    final lists = ref.watch(playlistsProvider).value ?? const <Playlist>[];
    Playlist? playlist;
    for (final p in lists) {
      if (p.id == id) {
        playlist = p;
        break;
      }
    }
    final tracksAsync = ref.watch(playlistTracksProvider(id));
    final leads = ref.watch(languageLeadsProvider);

    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load tracks: $e')),
      data: (tracks) {
        final paths = tracks.map((t) => t.path).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      playlist?.name ?? '',
                      style: Theme.of(context).textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  FilledButton(
                    onPressed: paths.isEmpty
                        ? null
                        : () => ref.read(playlistPlaybackProvider).play(paths),
                    child: const Text('Play'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: paths.isEmpty
                        ? null
                        : () =>
                            ref.read(playlistPlaybackProvider).shuffle(paths),
                    child: const Text('Shuffle'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: paths.isEmpty
                        ? null
                        : () => ref
                            .read(playlistPlaybackProvider)
                            .addToQueue(paths),
                    child: const Text('Add to queue'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Rename',
                    onPressed: () async {
                      final name = await _promptName(context,
                          title: 'Rename playlist',
                          initial: playlist?.name ?? '');
                      if (name != null && name.trim().isNotEmpty) {
                        await ref
                            .read(playlistsProvider.notifier)
                            .rename(id, name.trim());
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () async {
                      await ref.read(playlistsProvider.notifier).delete(id);
                      ref.read(selectedPlaylistProvider.notifier).select(null);
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: tracks.isEmpty
                  ? const Center(child: Text('This playlist is empty'))
                  : ReorderableListView.builder(
                      itemCount: tracks.length,
                      onReorder: (oldIndex, newIndex) {
                        final newPaths = reordered(paths, oldIndex, newIndex);
                        ref
                            .read(playlistsProvider.notifier)
                            .setItems(id, newPaths);
                      },
                      itemBuilder: (context, i) {
                        final t = tracks[i];
                        return ListTile(
                          key: ValueKey('${t.path}#$i'),
                          title: BilingualText(
                            original: t.title,
                            translit: t.titleTranslit,
                            translate: t.titleTranslate,
                            leads: leads,
                          ),
                          subtitle: Text(t.artist ?? ''),
                          trailing: IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'Remove',
                            onPressed: () {
                              final newPaths = List<String>.of(paths)
                                ..removeAt(i);
                              ref
                                  .read(playlistsProvider.notifier)
                                  .setItems(id, newPaths);
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
```

- [ ] **Step 5: Add the app-bar entry** — in `lib/catalog/browser_page.dart`, add an import near the other `package:olivier/...` imports:

```dart
import 'package:olivier/playlists/playlists_page.dart';
```

Then in the `AppBar`'s `actions:` list, insert this BEFORE the existing Settings `IconButton`:

```dart
            IconButton(
              icon: const Icon(Icons.playlist_play),
              tooltip: 'Playlists',
              onPressed: () {
                ref.read(searchQueryProvider.notifier).clear();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PlaylistsPage()),
                );
              },
            ),
```

- [ ] **Step 6: Run the tests**

Run: `mise exec -- flutter test test/reordered_test.dart test/playlists_page_test.dart`
Expected: PASS (2 + 2 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/playlists/playlists_page.dart lib/catalog/browser_page.dart test/reordered_test.dart test/playlists_page_test.dart
git commit -m "$(cat <<'EOF'
Add Playlists page (master-detail) + app-bar entry

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Dart — "Add to playlist…" dialog + context-menu wiring

**Files:**
- Create: `lib/playlists/add_to_playlist_dialog.dart`
- Modify: `lib/widgets/context_menu.dart`
- Modify: `lib/catalog/artist_column.dart`, `lib/catalog/album_column.dart`, `lib/catalog/track_column.dart`
- Test: `test/add_to_playlist_dialog_test.dart`

- [ ] **Step 1: Write the failing test** — `test/add_to_playlist_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/playlists/add_to_playlist_dialog.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';

void main() {
  testWidgets('picking an existing playlist adds the resolved paths',
      (tester) async {
    final added = <String>[];
    final fns = PlaylistFns(
      list: () async => [const Playlist(id: 5, name: 'Faves', count: 0)],
      create: (name) async => 9,
      rename: (id, name) async {},
      delete: (id) async {},
      reorder: (ids) async {},
      tracks: (id) async => const [],
      add: (id, paths) async => added.addAll(['$id', ...paths]),
      setItems: (id, paths) async {},
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        playlistFnsProvider.overrideWithValue(fns),
        entityPathFnsProvider.overrideWithValue(EntityPathFns(
          artistPaths: (_) async => [],
          albumPaths: (mbid) async => ['/m/a.flac', '/m/b.flac'],
          trackPath: (_) async => null,
        )),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: Consumer(builder: (context, ref, _) {
                return ElevatedButton(
                  onPressed: () => showAddToPlaylistDialog(
                      context, ref, const QueueEntityRef.album('R1')),
                  child: const Text('open'),
                );
              }),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Faves'));
    await tester.pumpAndSettle();

    expect(added, ['5', '/m/a.flac', '/m/b.flac']);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/add_to_playlist_dialog_test.dart`
Expected: FAIL — `showAddToPlaylistDialog` doesn't exist.

- [ ] **Step 3: Implement the dialog** — `lib/playlists/add_to_playlist_dialog.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';

/// Show a picker to add [entity]'s tracks to an existing or new playlist.
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  WidgetRef ref,
  QueueEntityRef entity,
) async {
  final fns = ref.read(playlistFnsProvider);
  final lists = await fns.list();
  if (!context.mounted) return;

  final result = await showDialog<int>(
    context: context,
    builder: (context) {
      final newNameController = TextEditingController();
      return AlertDialog(
        title: const Text('Add to playlist'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (lists.isNotEmpty)
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in lists)
                        ListTile(
                          title: Text(p.name),
                          onTap: () => Navigator.of(context).pop(p.id),
                        ),
                    ],
                  ),
                ),
              const Divider(),
              TextField(
                controller: newNameController,
                decoration: const InputDecoration(
                  hintText: 'New playlist name',
                  suffixIcon: Icon(Icons.add),
                ),
                onSubmitted: (v) async {
                  if (v.trim().isEmpty) return;
                  final id = await ref
                      .read(playlistsProvider.notifier)
                      .create(v.trim());
                  if (context.mounted) Navigator.of(context).pop(id);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );

  if (result == null) return;
  final paths = await resolveEntityPaths(entity, ref.read(entityPathFnsProvider));
  if (paths.isEmpty) return;
  await ref.read(playlistsProvider.notifier).addTracks(result, paths);
}
```

- [ ] **Step 4: Wire the context menu** — in `lib/widgets/context_menu.dart`:

Add the field + constructor param (next to `onAddToQueue`):

```dart
  final ValueChanged<QueueEntityRef>? onAddToPlaylist;
```
```dart
    this.onAddToPlaylist,
```

Add the menu item right after the `onAddToQueue` item in the `items:` list:

```dart
        if (onAddToPlaylist != null)
          const PopupMenuItem<String>(
              value: 'playlist', child: Text('Add to playlist…')),
```

Add the case to the `switch (selected)`:

```dart
      case 'playlist':
        onAddToPlaylist?.call(entity);
```

- [ ] **Step 5: Wire each column.** In `lib/catalog/artist_column.dart`, `lib/catalog/album_column.dart`, and `lib/catalog/track_column.dart`, add this import near the others:

```dart
import 'package:olivier/playlists/add_to_playlist_dialog.dart';
```

In each file's `RowContextMenu(...)`, add this parameter alongside the existing `onAddToQueue:`:

```dart
                    onAddToPlaylist: (entity) =>
                        showAddToPlaylistDialog(context, ref, entity),
```

(Each column's row builder already has `context` and `ref` in scope where `onAddToQueue` is set; use the same `entity` value the row already passes.)

- [ ] **Step 6: Run the test + analyze**

Run: `mise exec -- flutter test test/add_to_playlist_dialog_test.dart`
Expected: PASS.
Run: `mise exec -- flutter analyze`
Expected: no new issues.

- [ ] **Step 7: Full suite + lint**

Run: `mise exec -- flutter test`  (entire Dart suite green)
Run: `cd rust && cargo test`  (entire Rust suite green)
Run: `just lint --all`  (PASS)

- [ ] **Step 8: Commit**

```bash
git add lib/playlists/add_to_playlist_dialog.dart lib/widgets/context_menu.dart lib/catalog/artist_column.dart lib/catalog/album_column.dart lib/catalog/track_column.dart test/add_to_playlist_dialog_test.dart
git commit -m "$(cat <<'EOF'
Add "Add to playlist…" dialog + wire browse context menus

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Definition of Done

- Playlists page reachable from the app bar: create / rename / delete / reorder
  playlists; reorder / remove tracks; Play (replace+start), Shuffle, Add to queue.
- "Add to playlist…" on artist/album/track right-click menus (existing + new).
- Removing a track/album/root from the library (or a rescan orphan sweep) prunes
  the matching playlist entries automatically; a tag re-read does not.
- All tests green (`cd rust && cargo test`; `mise exec -- flutter test`);
  `just lint --all` clean.
```
