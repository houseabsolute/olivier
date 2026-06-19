# Context-Menu Actions + Ctrl-Q — Design

**Date:** 2026-06-19
**Status:** Approved design → ready for implementation plan
**Backlog items:** 1 (Ctrl-Q quits), 7 (Info popup for tracks & albums), 3 (re-read tags for a track, with re-homing), 4 (re-fetch MusicBrainz data for one artist/album)
**Out of scope (separate items):** richer album metadata / album art (8 & 5), import-decision log (2).

## Goal

Four small, independently-shippable additions, three of which hang off the right-click context menu the queue work already built (`AddToQueueMenu`): quit with Ctrl-Q, a copy-paste Info popup, a per-track tag re-read that re-homes the track if its album/artist changed, and a per-artist/album MusicBrainz re-fetch.

---

## Shared change: generalize the row context menu

`lib/widgets/context_menu.dart` currently exposes `AddToQueueMenu({child, entity, onAddToQueue})` — a `GestureDetector` (`onSecondaryTapDown`) that `showMenu`s a single "Add to queue" item. Generalize it to `RowContextMenu` that takes the entity plus a set of OPTIONAL action callbacks and renders only the entries whose callback is non-null:

- `onAddToQueue` (always present) → "Add to queue"
- `onInfo` → "Info"
- `onReadTags` → "Re-read tags"
- `onRefetch` → "Re-fetch from MusicBrainz"

Per column (each row wraps `RowContextMenu` with its entity + the relevant callbacks):
- **Artist** rows: Add to queue, Re-fetch from MusicBrainz.
- **Album** rows: Add to queue, Info, Re-fetch from MusicBrainz.
- **Track** rows: Add to queue, Info, Re-read tags.

(Order in the menu: Add to queue first, then the entity-specific actions.) The existing `LongPressDraggable` wrapping is unchanged.

---

## Item 1 — Ctrl-Q quits

Wrap `OlivierApp`'s `MaterialApp` (`lib/main.dart`) in `CallbackShortcuts` with `SingleActivator(LogicalKeyboardKey.keyQ, control: true)` → `SystemNavigator.pop()`. Linux-first (Ctrl-Q only). The queue already persists on every mutation, so no flush-on-exit is needed. No FFI. **Test:** a widget test that sends Ctrl-Q and asserts the bound callback fires (inject the callback or assert via a spy on the action).

---

## Item 7 — Info popup (tracks & albums)

New `lib/widgets/info_dialog.dart`: `showInfoDialog(BuildContext, {required String title, required List<(String, String)> fields})` opens a modal `Dialog` (a scrollable list of label/value rows) where every value is a `SelectableText` so it can be copy-pasted. **Empty fields are omitted.** No FFI — the data is already on the catalog DTOs.

- **Track** info (`onInfo` on track rows, built from the `Track` DTO): title, original/romaji (`titleTranslit`)/translation (`titleTranslate`) when present, artist, disc/position, length (mm:ss), last-played, added-at, track id.
- **Album** info (from the `Album` DTO): title (+ translit/translate), album artist, original/reissue year, release MBID. (Date-added / cover / track-count are deferred to item 8.)

**Test:** a widget test that opens the dialog for a Japanese track and asserts the original + romaji + translation rows render as `SelectableText`, and that a null field (e.g. no translation) is omitted.

---

## Item 3 — Re-read tags for a track (with re-homing)

`onReadTags` on track rows → a new FFI `reread_track_tags(db_path, track_id)`.

**Backend (`rust/src/api/catalog.rs` + `rust/src/catalog/scan.rs`):** resolve the file path(s) backing the track, re-read each via the existing `tags::read_tags(path)`, and re-run each file through the **same single-file upsert** `scan.rs` uses for a full scan (refactor the per-file body of `scan_roots`/`upsert_file` into a reusable `upsert_one(conn, path, tags, …)` if needed). Because `upsert_file` keys a track by `(release_mbid, disc, position)` and links the file to it, when the tags now name a different album/artist the file is re-pointed to a freshly-created/looked-up release+artist — i.e. the track is **re-homed**. Then run `reconcile_album_artists` + `prune_orphans` so the release/artist the track left (now fileless) is cleaned up. No deletion sweep (that is full-scan-only). Wrap the whole thing in one transaction.

**Frontend:** a thin `RereadTagsController` (or a method on the existing scan controller) calls the FFI, then invalidates `artistsProvider`/`albumsProvider`/`tracksProvider` and clears any now-dangling artist/album/track selection (mirroring what the scan controller does on completion). SnackBar feedback ("Tags re-read"). Local tags only — MusicBrainz re-fetch is item 4.

*Edge:* a track backed by two files whose tags now diverge will split into two tracks (each file re-homed by its own tags) — acceptable and rare; the FFI re-reads every file of the track.

**Tests (Rust, seeded `:memory:`):** (a) re-reading a track whose file tags are unchanged is a no-op (same release/track); (b) re-reading a track whose file album tag changed re-homes it to the new release and prunes the old now-empty release; (c) the artist-change case. **Dart:** the menu action invalidates the providers (override the FFI seam).

---

## Item 4 — Re-fetch MusicBrainz data for one artist/album

`onRefetch` on artist & album rows → new FFI `enrich_artist(db_path, artist_mbid, sink)` / `enrich_album(db_path, release_mbid, sink)` (streaming `EnrichProgress`, same as `enrich_library`).

**Backend (`rust/src/api/enrich.rs` + `rust/src/enrich/run.rs`):** add entry points that run the existing `enrich(...)` engine but constrain the selection to one entity — `artists_to_enrich`/`releases_to_enrich` gain a variant (or the entry points pass a single-entity filter) so only that artist (and its releases) / that release (and its sibling editions) are processed, with `force = true`. To make it a genuine *re-fetch from MusicBrainz* (fresh network data, not just a re-apply of cached JSON), first **scoped-clear the entity's `mb_cache` rows**: for an artist, the cache rows for the artist MBID + its releases + their release-groups; for an album, the release MBID + its release-group. Then the constrained `force` enrich re-hits the network for those entities.

**Frontend:** `EnrichController` gains `enrichArtist(mbid)` / `enrichAlbum(mbid)` mirroring the existing `enrich()` single-flight + `_disposed` guards + progress; both are disabled while any enrich (global or per-entity) is already running. On completion, invalidate `artistsProvider`/`albumsProvider`/`tracksProvider`. Progress shows via the existing enrich indicator + a completion SnackBar.

**Tests (Rust, with the `FakeHttp` double + fixtures):** `enrich_artist` re-fetches and applies only the named artist (+ its releases), leaving other artists untouched; the scoped cache-clear removes exactly the entity's cache rows. **Dart:** `EnrichController.enrichArtist/enrichAlbum` are single-flight and invalidate on completion.

---

## Build order

1. **Ctrl-Q** (pure Flutter shell) — trivial, independent.
2. **Generalize `RowContextMenu`** (the shared widget) — unblocks 7/3/4's menu entries; "Add to queue" behavior unchanged.
3. **Item 7 — Info popup** (pure UI over existing DTOs).
4. **Item 3 — re-read tags** (Rust single-file re-scan FFI + bridge regen + controller).
5. **Item 4 — per-entity re-fetch** (Rust constrained-enrich + scoped cache-clear FFI + bridge regen + `EnrichController`).

## Notes / deferred

- Re-fetch fresh-vs-reapply: this design clears the entity's cache for a true network re-fetch; if rate-limiting makes that annoying in practice, a future "re-apply only" variant could skip the clear.
- All new FFI changes require `flutter_rust_bridge_codegen generate` + committing the regenerated bridge.
- Host-VM test rule (as in the queue work): Dart unit/widget tests must run under plain `mise exec -- flutter test` — FFI behind injectable seam providers; Rust FFI round-trips are covered by Rust tests, not host-VM Dart tests.
