# Album "Re-read tags" — Design

**Status:** approved, ready for implementation plan
**Date:** 2026-06-20

## Goal

Add a "Re-read tags" action to the album right-click menu that re-reads the on-disk tags of every
track in the album, reusing the existing re-home-aware per-track logic.

(The TODO also asked for "re-fetch from MB" on the track menu; dropped — there is no per-track MB
fetch and re-fetching the whole album from a track menu is not wanted. The track menu is unchanged.)

## What's there today

- The album menu (`album_column.dart`) has Add-to-queue, Info, and **Re-fetch from MusicBrainz**
  (`enrichAlbum`); it has no Re-read tags.
- The track menu (`track_column.dart`) has **Re-read tags** wired to `rereadTrackTagsFnProvider`
  (`reread_track_tags(conn, track_id)`), followed by invalidating artists/albums/tracks, clearing
  the selected track, and a "Tags re-read" snackbar.
- `RowContextMenu` already defines the **Re-read tags** item (shown when `onReadTags != null`), so
  no context-menu widget change is needed — only wiring `onReadTags` on the album column.
- `reread_track_tags(conn: &mut Connection, track_id: i64, log: &DecisionLog)` exists in
  `rust/src/catalog/scan.rs`; it re-reads one track's file tags and re-homes the track if its
  album/artist changed.

## Rust

### `reread_album_tags` (`rust/src/catalog/scan.rs`)

Collect the album's track IDs up front (re-homing during the loop can change which tracks belong
to the release), then re-read each via the existing per-track function:

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

(The `stmt` immutable borrow is dropped before the loop, so the `&mut conn` re-borrows in
`reread_track_tags` are fine.)

### FFI (`rust/src/api/catalog.rs`)

Mirror `reread_track_tags`:

```rust
pub fn reread_album_tags(db_path: String, release_mbid: String) -> anyhow::Result<()> {
    let mut conn = db::open(&db_path)?;
    let log = DecisionLog::for_db(&db_path);
    scan::reread_album_tags(&mut conn, &release_mbid, &log)
}
```

Regenerate the bridge (`mise exec -- flutter_rust_bridge_codegen generate`) and commit
`lib/src/rust/**` + `rust/src/frb_generated.rs`. Dart fn: `rereadAlbumTags`.

## Dart

### Seam (`lib/state/providers.dart`)

Mirror `rereadTrackTagsFnProvider`:

```dart
// Re-read every track's tags for one album (re-homes any whose album changed). Seam.
typedef RereadAlbumTagsFn = Future<void> Function(String releaseMbid);

final rereadAlbumTagsFnProvider = Provider<RereadAlbumTagsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (releaseMbid) => rereadAlbumTags(dbPath: db, releaseMbid: releaseMbid);
});
```

### Wiring (`lib/catalog/album_column.dart`)

Add `onReadTags` to the album row's `RowContextMenu`, mirroring the track flow (the `album`,
`ref`, and `context` are already in scope from the existing `onRefetch`):

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

`selectedAlbumProvider` (not `selectedTrack`) is cleared because re-reading can re-home tracks and
change/remove the release — clearing avoids pointing the track pane at a stale album, matching the
track flow's "clear the selection" behavior.

## Testing

### Rust (`rust/tests/catalog_test.rs`)

Reuse the `seed_one_flac` helper (copies the fixture FLAC, scans it → one release/track/file):
- **No-op pass:** `reread_album_tags(&mut conn, <release_mbid>, …)` with unchanged files leaves the
  track/file/release row counts unchanged (proves it iterates the album's tracks via
  `reread_track_tags` without error).
- **Applies a tag change:** model on `reread_track_tags_rehomes_when_album_changes` — rewrite the
  file's `ALBUM` + `MUSICBRAINZ_ALBUMID`, then call `reread_album_tags` for the **original** release
  mbid; assert the file now resolves to the new release (the re-home happened via the album-level
  call), and the old empty release was pruned.

### Dart (host-VM)

- The album menu shows "Re-read tags": pump an `AlbumColumn` (existing
  `test/album_column_enqueue_test.dart` harness), secondary-tap the album row, assert
  `find.text('Re-read tags')` appears.
- Re-read invokes the seam: override `rereadAlbumTagsFnProvider` with a recorder; tap "Re-read
  tags"; assert the recorder got the album's `releaseMbid` and a "Tags re-read" snackbar shows.

## Touched files

- `rust/src/catalog/scan.rs` — `reread_album_tags`.
- `rust/src/api/catalog.rs` — FFI.
- `rust/src/frb_generated.rs`, `lib/src/rust/**` — regenerated bridge.
- `lib/state/providers.dart` — `rereadAlbumTagsFnProvider` seam.
- `lib/catalog/album_column.dart` — wire `onReadTags`.
- `rust/tests/catalog_test.rs`, `test/album_column_*` — tests.
