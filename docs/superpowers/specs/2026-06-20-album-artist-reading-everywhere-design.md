# Album-Artist + Reading Everywhere — Design

**Status:** approved, ready for implementation plan
**Date:** 2026-06-20
**Follows:** the per-artist reading + sort override (`2026-06-20-artist-reading-override-design.md`)

## Goal

The artist displayed for any track or album should be the **album-artist** (the row in the
`artist` table referenced by the release), rendered bilingually with its effective, overridable
reading — exactly like the artist list. This **replaces** the raw file-tag artist everywhere in
the UI, and updates live when the user changes an artist's reading override.

Today the override only flows into the artist list (`artists_page`). Every other surface shows a
raw tag/name string with no reading: the queue rows, the now-playing bar, and the album/track/
queue Info popups.

### Consequence (accepted)

For compilation / "feat." tracks the displayed artist becomes the **album-artist**, so a track's
own credited performer (`track.artist` tag) no longer shows anywhere in the UI. This is the
intended behavior (the user chose "replace the tag").

### Non-goals

- The album *browse* rows are unchanged (they already sit under a selected artist).
- System/MPRIS metadata: `MediaItem.artist` becomes the album-artist *name* (a single string the
  OS shows); the reading is a UI-only concept carried in `MediaItem.extras`, not exposed to MPRIS.
- The `track.artist` tag column stays in the DTOs (still data); it just stops being displayed.

## Effective reading

Everywhere below, "reading" means the same expression the artist list uses:
`COALESCE(a.transliteration_override, a.transliteration)`. So an override wins, and clearing it
falls back to the MusicBrainz transliteration.

## Data model (Rust)

Add the album-artist's `name`, `name_original`, and effective `reading` to three DTOs in
`rust/src/catalog/schema.rs`, and populate them from the queries in `rust/src/catalog/query.rs`.

### `Album`

Already carries `album_artist` (= `a.name`). Add two fields:
- `album_artist_original: Option<String>` (= `a.name_original`)
- `album_artist_reading: Option<String>` (= effective reading)

`albums_for_artist` already does `JOIN artist a ON a.mbid = r.album_artist_mbid`. Extend its
SELECT to also return `a.name_original` and `COALESCE(a.transliteration_override, a.transliteration)`.

### `Track`

Add three **nullable** fields (all `Option<String>` → optional named params in Dart, so the ~15
existing `Track`/`QueueTrack` test fixtures that omit them keep compiling):
- `album_artist: Option<String>` (= `aa.name`)
- `album_artist_original: Option<String>` (= `aa.name_original`)
- `album_artist_reading: Option<String>` (= effective reading)

`tracks_for_album` currently has no release/artist join. Add
`JOIN release r ON r.mbid = t.release_mbid LEFT JOIN artist aa ON aa.mbid = r.album_artist_mbid`,
and select `aa.name, aa.name_original, COALESCE(aa.transliteration_override, aa.transliteration)`.
The artist join is a `LEFT JOIN` (release.album_artist_mbid is a nullable FK) so a release with no
album-artist never drops the track; all three columns map straight to `Option<String>` (null →
`None`). The existing `GROUP BY t.id` is unaffected (the album-artist columns are constant per
release).

### `QueueTrack`

Add the same three `Option<String>` fields (`album_artist`, `album_artist_original`,
`album_artist_reading`).

`tracks_for_paths` already does `JOIN release r ON r.mbid = t.release_mbid`. Add
`LEFT JOIN artist aa ON aa.mbid = r.album_artist_mbid` (nullable FK, same reasoning) and select the
three album-artist columns straight to `Option<String>`. The catalog-miss **placeholder** branch
(a path no longer in the catalog) defaults all three to `None`.

### Bridge

Regenerate with `mise exec -- flutter_rust_bridge_codegen generate`; commit the regenerated
`lib/src/rust/**` + `rust/src/frb_generated.rs`. Dart field names: `albumArtist`,
`albumArtistOriginal`, `albumArtistReading`.

## Display (Dart) — replace the tag artist with the bilingual album-artist

Reuse `BilingualText` with `translate: null` (names get only a reading, matching the artist list):
`BilingualText(original: albumArtistOriginal ?? albumArtist ?? '', translit: albumArtistReading,
translate: null, leads: leads)` — the `?? ''` covers a `QueueTrack`/`Track` whose nullable
`albumArtist` is absent (`Album.albumArtist` is non-null, so its `?? ''` is a no-op).

### Queue rows (`lib/catalog/queue_panel.dart`)

The artist cell currently computes the tag `final artist = t.artist?.trim()...` and renders a
muted `Text`. Replace it with the bilingual album-artist `BilingualText` (the panel already
watches `languageLeadsProvider` for `leads`). Keep it muted (the existing artist/album column
styling).

### Now-playing bar (`lib/widgets/now_playing_bar.dart` + `lib/audio/playback_controller.dart`)

- `mediaItemsForQueueTracks` (the pure `QueueTrack` → `MediaItem` mapper): set
  `artist: qt.albumArtistOriginal ?? qt.albumArtist` (both nullable → `MediaItem.artist` is null
  when absent) and add `extras['artistReading'] = qt.albumArtistReading`.
- `now_playing_bar.dart`: the artist currently renders as a plain `Text(item.artist!)`. Render it
  with `BilingualText(original: item.artist!, translit: item.extras?['artistReading'] as String?,
  translate: null, leads: leads)` — mirroring how the title is already rendered there.

### Info popups (`lib/widgets/info_dialog.dart`)

Replace the tag artist with the album-artist + reading:
- `albumInfoFields`: change `'Album artist'` to `a.albumArtistOriginal ?? a.albumArtist`, and add
  a `'Reading'` row = `a.albumArtistReading` (omitted when null/empty via the existing `_add`).
- `trackInfoFields`: drop `'Artist' = t.artist`; add `'Album artist' = t.albumArtistOriginal ??
  t.albumArtist` and `'Reading' = t.albumArtistReading`.
- `queueTrackInfoFields`: same change as `trackInfoFields`.

## Refresh on override change

`showArtistReadingDialog`'s `onSubmit` (`lib/widgets/artist_reading_dialog.dart`) currently does
`setArtistReadingOverride(...)` then `ref.invalidate(artistsProvider)`. Extend it to refresh
every surface:

- Add `void refreshMetadata() { revision.value++; }` to `QueueController`
  (`lib/audio/queue_controller.dart`). Bumping `revision` re-resolves the queue panel (the
  `QueueNotifier` listens and `invalidateSelf`s) **and** triggers `PlaybackController`'s
  `_onQueueRevision`, which rebuilds the now-playing `MediaItem`s (and MPRIS) from fresh
  `tracksForPaths` data — so the now-playing bar updates live.
- `onSubmit` becomes: `await setArtistReadingOverride(...)`, then
  `ref.read(queueControllerProvider).refreshMetadata()` and
  `ref.invalidate(artistsProvider); ref.invalidate(albumsProvider); ref.invalidate(tracksProvider);`.

The queue panel, now-playing bar, MPRIS, artist list, and the (next-opened) Info popups all then
reflect the new reading. (Info popups read live data each time they open, so invalidating
`albumsProvider`/`tracksProvider` is enough.)

## Testing

### Rust (`rust/tests/catalog_test.rs`)

For each query, seed an artist with a `transliteration`, a release, tracks, and files; set an
override via `set_artist_reading_override`; assert the query returns the **overridden**
album-artist reading, and that clearing the override falls back to the MB transliteration:
- `albums_for_artist` → `album_artist_reading` reflects the override; `album_artist_original` is
  the MB `name_original`.
- `tracks_for_album` → each `Track` carries the album-artist `name` / `name_original` / overridden
  `reading`.
- `tracks_for_paths` → each real `QueueTrack` carries them; a catalog-miss path yields the
  placeholder defaults (empty/None).

### Dart (host-VM)

- Queue row renders the album-artist bilingually: pump `QueuePanel` with a stub `QueueTrack`
  carrying `albumArtist`/`albumArtistOriginal`/`albumArtistReading`; assert the original and the
  reading both appear and the old tag `artist` does not.
- `mediaItemsForQueueTracks` maps the album-artist into `MediaItem.artist` + `extras['artistReading']`
  (pure unit test).
- `onSubmit` wiring: override `setArtistReadingOverrideFnProvider` + the queue controller +
  spy on invalidations; tap Save and assert `refreshMetadata()` was called and
  `artistsProvider`/`albumsProvider`/`tracksProvider` were invalidated.

## Touched files

- `rust/src/catalog/schema.rs` — `Album` (+2), `Track` (+3), `QueueTrack` (+3).
- `rust/src/catalog/query.rs` — `albums_for_artist`, `tracks_for_album`, `tracks_for_paths`.
- `rust/src/frb_generated.rs`, `lib/src/rust/**` — regenerated bridge.
- `lib/catalog/queue_panel.dart` — queue artist cell → bilingual album-artist.
- `lib/audio/playback_controller.dart` — `mediaItemsForQueueTracks` album-artist + reading.
- `lib/widgets/now_playing_bar.dart` — bilingual artist.
- `lib/widgets/info_dialog.dart` — album/track/queue artist + reading fields.
- `lib/audio/queue_controller.dart` — `refreshMetadata()`.
- `lib/widgets/artist_reading_dialog.dart` — `onSubmit` refreshes all surfaces.
- `rust/tests/catalog_test.rs`, `test/…` — tests above.
