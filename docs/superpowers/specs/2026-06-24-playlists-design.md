# Playlists — Design Spec

**Date:** 2026-06-24
**Status:** Approved in brainstorming — pending spec review

## Goal

Add persistent, named, manually-ordered playlists. Today the only collection is
the ephemeral queue; playlists let the user save sets of tracks, manage them on a
dedicated page, and play them (replace queue / shuffle / append).

## Background

- **Queue model (mirrored here).** The queue persists in `queue_item` keyed by
  **file path** (not track id), restored via `QueueSnapshot`, with missing-on-disk
  paths skipped on load (`rust/src/db.rs`, `lib/audio/queue_controller.dart`).
  Playlists use the same path-based identity.
- **Track resolution.** `query::tracks_for_paths(conn, &[String]) -> Vec<QueueTrack>`
  (`rust/src/catalog/query.rs:376`) runs one `WHERE f.path = ?1` lookup per input
  path, so it preserves both **order** and **duplicate** paths — exactly what a
  playlist needs.
- **Add-to-queue pattern (mirrored here).** A shared `RowContextMenu`
  (`lib/widgets/context_menu.dart`) exposes optional callbacks (`onAddToQueue`,
  `onInfo`, `onRemove`, …) on artist/album/track rows. Rows carry a
  `QueueEntityRef` (artist/album/track) resolved to file paths via
  `resolveEntityPaths` (`lib/audio/queue_entity.dart`).
- **Playback API (reused, no new playback code).** `QueueController`
  (`lib/audio/queue_controller.dart`) already exposes `setQueue(paths,{initialIndex})`,
  `append(paths)`, `playAt(index)`, and `replaceLibraryShuffled(paths)`.
- **Removal funnels through `DELETE FROM file`.** `remove_track`, `remove_album`
  (`rust/src/catalog/deletes.rs`), `remove_root` (`roots.rs`), and the rescan
  deletion sweep (`scan.rs:159`) all delete `file` rows, then `prune_orphans`
  drops now-file-less track/release/artist rows. `file.path` is `UNIQUE`.
- **Re-read tags does NOT delete file rows.** `reread_track_tags`
  (`scan.rs:182`) upserts files with `INSERT … ON CONFLICT(path) DO UPDATE`
  (`scan.rs:494`) — a true update, not a delete+insert — and `prune_orphans`
  only deletes file-*less* catalog rows. So a tag re-read preserves the file row
  and its path.
- **DB/FFI patterns.** Migrations are `M::up("SQL")` entries in the
  `MIGRATION_SLICE` (`rust/src/db.rs`); the new tables are migration index 8 (the
  9th). FOREIGN KEYs are enforced (`SQLITE_DEFAULT_FOREIGN_KEYS=1`). Public fns in
  `rust/src/api/*.rs` are auto-bridged by flutter_rust_bridge (regen:
  `mise exec -- flutter_rust_bridge_codegen generate`); `#[derive(Debug, Clone)]`
  structs serialize automatically.

## Decisions (from brainstorming)

- **UI:** a separate **Playlists page** (master-detail), opened from a new
  app-bar icon, like Settings.
- **Playback actions:** **Play** (replace queue + start), **Shuffle play**, and
  **Add to queue** (append). No "Play next."
- **Track identity:** by **file path** (queue-consistent).
- **Playlist order:** **manual** (user-reorderable), not name-sorted.
- **Remove-from-library prunes playlist entries:** done at the DB layer via a
  foreign-key cascade (below), so it covers explicit removal *and* the orphan
  sweep with no app code, while tag re-reads leave entries intact.

## Data model (new migration appended to `MIGRATION_SLICE`)

```sql
CREATE TABLE playlist (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL,
  position    INTEGER NOT NULL,        -- manual order of playlists (0-based)
  created_at  INTEGER NOT NULL         -- epoch seconds
);
CREATE TABLE playlist_item (
  playlist_id INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
  position    INTEGER NOT NULL,        -- 0-based order within the playlist
  path        TEXT NOT NULL REFERENCES file(path) ON DELETE CASCADE,
  PRIMARY KEY (playlist_id, position)
);
CREATE INDEX idx_playlist_item_path ON playlist_item(path);
```

- `playlist_item.playlist_id … ON DELETE CASCADE`: deleting a playlist drops its
  items.
- `playlist_item.path REFERENCES file(path) ON DELETE CASCADE`: when a file row
  is deleted (any removal path above), its playlist entries vanish automatically.
  Re-read tags upserts (no delete) so entries survive. This is the whole
  "remove-from-library prunes playlists" feature — enforced by the DB.
- `idx_playlist_item_path`: lets the cascade (and path lookups) avoid a full
  child-table scan per file delete.
- Duplicate track entries and duplicate playlist names are allowed (id is the
  key).

## Rust store + FFI

New store module `rust/src/catalog/playlists.rs` (cohesive with `query`/`deletes`;
reuses `query::tracks_for_paths`), registered in the catalog module. Thin
`db_path` wrappers in `rust/src/api/playlists.rs` (auto-bridged).

Struct (`rust/src/catalog/playlists.rs`, `#[derive(Debug, Clone)]`):
```rust
pub struct Playlist { pub id: i64, pub name: String, pub count: i64 }
```

Functions (store fn `(conn, …)`, mirrored by `api` fn `(db_path, …)`):
- `create_playlist(name) -> i64` — inserts at `position = COALESCE(MAX(position),-1)+1`, `created_at = now`; returns the new id.
- `rename_playlist(id, name)`
- `delete_playlist(id)` — cascade drops items.
- `reorder_playlists(ids: Vec<i64>)` — sets each playlist's `position` to its index in `ids` (transactional rewrite).
- `list_playlists() -> Vec<Playlist>` — `LEFT JOIN playlist_item … GROUP BY playlist.id ORDER BY playlist.position`; `count` = number of items.
- `playlist_tracks(id) -> Vec<QueueTrack>` — `SELECT path … WHERE playlist_id=? ORDER BY position`, then `query::tracks_for_paths`. (Reuses `QueueTrack`; order + duplicates preserved.)
- `add_to_playlist(id, paths: Vec<String>)` — appends paths at `MAX(position)+1…` (transactional).
- `set_playlist_items(id, paths: Vec<String>)` — transactional `DELETE FROM playlist_item WHERE playlist_id=?` then re-INSERT paths at 0,1,2,… ; backs both reorder-within-playlist and remove-track. (Mirrors `save_queue`'s rewrite.)

The FK requires every inserted path to exist in `file`; the resolve-from-catalog
flow (`resolveEntityPaths` / current playlist paths) guarantees this.

## Playback semantics (reuse `QueueController`, no new playback code)

- **Play** → `setQueue(paths)` then `playAt(0)`.
- **Shuffle play** → `replaceLibraryShuffled(paths)` (setQueue + shuffle + play).
- **Add to queue** → `append(paths)`.

`paths` = the playlist's current paths. Missing-on-disk paths are skipped by the
existing queue restore logic, so a stale entry never breaks playback.

## UI

### Playlists page (`lib/playlists/playlists_page.dart`)
Opened via a new app-bar icon (e.g. `Icons.playlist_play`) on `BrowserPage`,
next to Settings, through `Navigator.push` (like `SettingsPage`). Master-detail:

- **Left:** the playlists, a `ReorderableListView` of name + track count, with a
  **New playlist** action (prompts for a name). Reorder → `reorder_playlists`.
  Selecting a playlist sets `selectedPlaylistProvider`.
- **Right:** the selected playlist's tracks as a `ReorderableListView` (reuses the
  queue-panel row/reorder/remove pattern), with a header bar: **Play**,
  **Shuffle**, **Add to queue**, **Rename**, **Delete**. Reorder + remove call
  `set_playlist_items`. Empty states for "no playlists" and "empty playlist".

### Add to playlist (from browse rows)
Extend `RowContextMenu` with an optional `onAddToPlaylist` callback rendering an
**"Add to playlist…"** item, wired on artist/album/track rows. It opens a small
dialog (`lib/playlists/add_to_playlist_dialog.dart`) listing existing playlists +
a "New playlist" name field; on choice it resolves the row's `QueueEntityRef` →
paths via `resolveEntityPaths` and calls `add_to_playlist` (creating first if a
new name was given).

## State (`lib/state/playlists.dart`)

- `playlistsProvider` (`AsyncNotifier<List<Playlist>>`).
- `selectedPlaylistProvider` (selected id for the page).
- `playlistTracksProvider(int id)` (`FutureProvider.family<List<QueueTrack>>`).
- `PlaylistController` wrapping the FFI mutations (create/rename/delete/reorder/
  add/setItems); after each mutation it invalidates the affected providers.
- FFI seam providers (matching the `getSettingFn`/`setVolumeFn` pattern) so the
  controller/providers are testable without the bridge.
- Mutations are awaited; failures route to the existing `errorReporter` (not
  swallowed), consistent with the error-surfacing work.

## Remove-from-library cascade (how it works)

No imperative cleanup. Because `playlist_item.path REFERENCES file(path) ON
DELETE CASCADE` and FKs are enforced:

- `remove_track` / `remove_album` / `remove_root` and the rescan deletion sweep
  all `DELETE FROM file` → matching `playlist_item` rows cascade away.
- `reread_track_tags` upserts files (`ON CONFLICT(path) DO UPDATE`) → no delete →
  playlist entries are preserved.
- A file missing on disk but still in the catalog (e.g. unmounted drive, no
  rescan yet) keeps its file row, so the entry stays and resolves to the track;
  playback skips it (queue behavior).

## Edge cases

- **Empty playlist:** Play/Shuffle/Add-to-queue are no-ops (empty path list);
  the page shows an empty state.
- **Deleting the selected playlist:** clears `selectedPlaylistProvider`.
- **Duplicate names / duplicate tracks:** allowed.
- **Reorder/remove concurrency:** `set_playlist_items` is a single transaction;
  the page sends the full intended order.
- **Add of a path that just disappeared:** guaranteed not to happen via the
  resolve-from-catalog flow; if it ever did, the FK rejects that insert.

## Testing

- **Rust** (in-memory rusqlite, like existing db tests):
  - create (positions append) / list (with `count`, ordered by position) /
    rename / delete (cascade removes items).
  - `reorder_playlists` rewrites order; `list_playlists` reflects it.
  - `add_to_playlist` appends in order; `set_playlist_items` rewrites order and
    drops removed tracks; both preserve duplicates.
  - `playlist_tracks` returns tracks in `position` order, duplicates intact.
  - **Cascade:** add tracks, then `remove_album`/`remove_track` → their entries
    are gone from the playlist; **and** `reread_album_tags` (or a re-upsert of
    the same path) leaves entries intact.
- **Dart:** `PlaylistController`/provider tests over the FFI seams
  (create/rename/delete/reorder/add/setItems invalidate providers; failures
  reach the reporter). Widget tests for the page (create, select, reorder
  playlists, reorder/remove tracks, Play→`setQueue`+`playAt`,
  Shuffle→`replaceLibraryShuffled`, Add-to-queue→`append`) and the
  add-to-playlist dialog (pick existing, create new).

## Out of scope (YAGNI)

- Smart/rule-based playlists; m3u (or other) import/export; playlist folders or
  nesting; duplicate-name prevention; drag-from-browse-onto-a-playlist (the
  context-menu "Add to playlist…" covers adding); "Play next."
