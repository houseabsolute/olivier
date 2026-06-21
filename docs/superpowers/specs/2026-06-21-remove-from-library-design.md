# Remove from Library — Design Spec

**Date:** 2026-06-21
**Status:** Approved in brainstorming — pending spec review

## Goal

Add a **"Remove from library"** action to the album and track right-click context menus that forgets the entity from the catalog (deletes its database rows) so it disappears from the UI immediately. The audio files on disk are never modified.

## Decisions (from brainstorming)

- **Semantics — forget from catalog only.** Delete the catalog rows; leave the audio files on disk untouched. A future scan of the containing root will re-add the entity. (Chosen over delete-files-from-disk, exclude-from-library, and offering both.)
- **Scope — album and track rows** (per the TODO). Artist-level removal is a straightforward future extension via the same mechanism but is out of scope here.
- **No confirm dialog.** Removal is immediate; a snackbar (`Removed "<title>"`) provides feedback. No undo (recovery is via re-scan).
- **Menu label — "Remove from library."** The TODO wording was "remove from app"; renamed for accuracy since the files stay. *(Confirm during spec review — easy to switch back to "Remove from app".)*

## Architecture

### Deletion model (file-driven — reused, not reinvented)

Catalog deletion in Olivier is **file-driven**: catalog rows are pruned once their underlying `file` rows are gone. `prune_orphans` (`rust/src/catalog/scan.rs`) deletes child-first — tracks with no `file` (and their `track_stats`), then releases with no track, then artists with no release. FKs are enforced (the bundled SQLite is built with `SQLITE_DEFAULT_FOREIGN_KEYS=1`). `remove_root` (`rust/src/catalog/roots.rs`) already follows this pattern: delete the `file` rows under the root, then call `prune_orphans`.

Per-entity removal reuses it exactly: **delete the entity's `file` rows, then `prune_orphans`.**

Relevant schema (`rust/src/db.rs`): `file.track_id → track.id` (NOT NULL); `track.release_mbid → release.mbid`; `track_stats.track_id → track.id`; `release.album_artist_mbid → artist.mbid`.

### Rust API (new)

New module `rust/src/catalog/deletes.rs`:

- `remove_track(conn, track_id) -> anyhow::Result<()>`
  - `DELETE FROM file WHERE track_id = ?1`
  - then `scan::prune_orphans(conn, &DecisionLog::to_path(None))`
- `remove_album(conn, release_mbid) -> anyhow::Result<()>`
  - `DELETE FROM file WHERE track_id IN (SELECT id FROM track WHERE release_mbid = ?1)`
  - then `prune_orphans`

Exposed via `rust/src/api/catalog.rs`, mirroring `remove_root`:

- `pub fn remove_track(db_path: String, track_id: i64) -> anyhow::Result<()>` → `deletes::remove_track(&db::open(&db_path)?, track_id)`
- `pub fn remove_album(db_path: String, release_mbid: String) -> anyhow::Result<()>` → `deletes::remove_album(&db::open(&db_path)?, &release_mbid)`

Pruning uses the no-op decision log (`DecisionLog::to_path(None)`), like `remove_root` — a manual removal is not an import decision, so it should not be written to the import decision log.

**Bridge regeneration required.** The new `pub fn`s generate Dart bindings in `lib/src/rust/api/catalog.dart` via flutter_rust_bridge codegen (config: `flutter_rust_bridge.yaml`; `rust_input: crate::api`, `dart_output: lib/src/rust`). This is the first item in this batch of work that is **not** Dart-only. The exact regen command is confirmed at plan time.

### Flutter wiring

- **Seam providers** (`lib/state/providers.dart`), mirroring `rereadTrackTagsFnProvider` / `rereadAlbumTagsFnProvider`:
  - `typedef RemoveTrackFn = Future<void> Function(int trackId);` + `removeTrackFnProvider` → `removeTrack(dbPath, trackId)`
  - `typedef RemoveAlbumFn = Future<void> Function(String releaseMbid);` + `removeAlbumFnProvider` → `removeAlbum(dbPath, releaseMbid)`
- **`RowContextMenu`** (`lib/widgets/context_menu.dart`): add `ValueChanged<QueueEntityRef>? onRemove` plus a `PopupMenuItem(value: 'remove', child: Text('Remove from library'))` shown only when `onRemove != null`, placed last in the menu; dispatch it in the `switch`.
- **`album_column.dart`**: pass `onRemove` → call `removeAlbumFnProvider(album.releaseMbid)`, then `invalidate(artistsProvider/albumsProvider/tracksProvider)`, `selectedAlbumProvider.notifier.clear()`, and show a `Removed "<album.title>"` snackbar. This is the same refresh pattern the existing `onReadTags` ("Re-read tags") handler uses.
- **`track_column.dart`**: pass `onRemove` → `removeTrackFnProvider(track.id)`, then invalidate the three catalog providers, `selectedTrackProvider.notifier.clear()`, and show a `Removed "<track.title>"` snackbar.

## Data flow

`right-click row → "Remove from library" → seam fn → FFI → Rust deletes file rows + prune_orphans → Dart invalidates catalog providers → lists rebuild without the entity → snackbar`.

## Edge cases / caveats (intended behavior)

- Removing an album that is its artist's only release also removes the artist (prune cascade). Removing a track can likewise orphan and remove its album/artist.
- **Queue / now-playing are path-based and independent.** A removed track remains in the queue and still plays (the file still exists on disk). No queue cleanup is performed.
- Play history (`track_stats`) for a removed track is deleted by `prune_orphans` and is not restored if the file is later re-scanned.
- Re-scanning the containing root re-adds the entity — the accepted trade-off of forget-only semantics.

## Testing

- **Rust** (`rust/tests/`, e.g. a new `remove_entity_test.rs`): seed a small catalog; assert `remove_track` drops the track (+ its `track_stats`) and any orphaned parents while siblings remain; `remove_album` drops the release + its tracks (and the artist if orphaned); the `file` rows are deleted but no filesystem I/O occurs (DB-only); a sibling album/track under the same artist survives.
- **Flutter**:
  - `context_menu_test.dart`: the "Remove from library" item appears when `onRemove` is provided and is absent otherwise.
  - `album_column` widget test: right-click → "Remove from library" calls the `removeAlbumFnProvider` seam (records the release mbid) and shows the snackbar.
  - `track_column` widget test: same for `removeTrackFnProvider`.

## Out of scope

Deleting files from disk; an exclude-from-rescan list; artist-level removal; undo; removing the track from the queue when it is forgotten.
