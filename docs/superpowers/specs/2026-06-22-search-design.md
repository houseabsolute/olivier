# Global Search — Design Spec

**Date:** 2026-06-22
**Status:** Approved in brainstorming — pending spec review

## Goal

Add a global, cross-entity search to Olivier: one search box that finds artists, albums, and tracks at once — matching each entity's original title, romanized reading, and translation — surfaced as a grouped dropdown overlay. Selecting a hit navigates the existing browse cascade to it (it does not play). This lets the user find anything in a large bilingual library by typing `ringo`, `椎名`, or `shiina`, without first knowing the artist.

## Background

The browse UI (`lib/catalog/browser_page.dart`) is a strict master-detail cascade: artist column → that artist's albums → that album's tracks, driven by `selectedArtistProvider` / `selectedAlbumProvider` / `selectedTrackProvider` in `lib/state/providers.dart` (the `albums`/`tracks` list providers re-run when the selection changes). The full artist list is loaded once (`listArtists(after: null, limit: 1000)`); there is no search or filter anywhere today, and the catalog FFI exposes no text-query argument. The top bar (`lib/widgets/top_controls.dart`) is `[Transport] Spacer() [Volume]` — the `Spacer()` is an empty, flexible center with room for a search field.

Searchable text per entity already exists in the schema: artist `name` / `name_original` / `transliteration` / `sort_name` (+ `transliteration_override`); album `release.title` + `release_title_alt` + `release_title_override` (translit/translate); track `track.title` + `track_title_alt` + `track_title_override` (translit/translate). A partial FTS5 trigram spike exists (`CREATE VIRTUAL TABLE search USING fts5(text, tokenize='trigram')` + `db::search_contains`, `rust/src/db.rs`) but is unused by the browse path and not entity-aware.

## Decisions (from brainstorming)

- **Global cross-entity** search (not a per-column filter).
- **Dropdown overlay** presentation (not replace-the-browse-area): a grouped floating list under the top-bar search box.
- **Own-field substring matching**: each entity matches only on its *own* searchable text — so a query matching the artist "Shiina Ringo" surfaces that artist plus albums/tracks whose *own* titles contain the query, but **not** every track by that artist. Case-insensitive (ASCII); literal substring for non-Latin (Japanese needs no case-folding). Substring (contains), not prefix-only.
- **Selecting a hit navigates the cascade** (reveals + scrolls it into view); it never auto-plays — consistent with Olivier's "clicking doesn't play" rule.
- **`LIKE`-based** implementation (with `NOCASE` + `ESCAPE`), not the FTS5 spike — correct and fast at this library size (≤~1000 artists, a few thousand albums/tracks); FTS is a possible later optimization.

## Architecture

### Rust (`rust/src/catalog/`)

A new query `search_catalog(conn, query: &str, limit: u32) -> SearchResults`, exposed via FFI as `search_catalog(db_path, query, limit)`.

- `SearchResults { artists: Vec<Artist>, albums: Vec<Album>, tracks: Vec<SearchTrack> }`.
  - Reuse the existing `Artist` (carries `mbid` + display fields) and `Album` (carries `release_mbid` + `album_artist_mbid` + title/translit/translate + album-artist display) — both already hold the nav keys.
  - New `SearchTrack { id, title, title_translit, title_translate, album_artist, album_artist_original, album_artist_reading, album_artist_mbid, release_mbid }` — the existing `Track` struct lacks `release_mbid`, which a track hit needs to drive the cascade (select its album). It carries the album-artist display for the result subtitle.
- Matching (per entity, all `LIKE '%' || ?query || '%' ESCAPE '\'`, the query pre-escaped for `%`/`_`/`\`, `COLLATE NOCASE`):
  - **Artists:** `name` OR `name_original` OR `COALESCE(transliteration_override, transliteration)` OR `COALESCE(sort_name_override, sort_name)`. Restrict to album-artists actually referenced by a release (same population as `artists_page`).
  - **Albums:** `release.title` OR the album's translit/translate display values (the `NULLIF(COALESCE(override, alt), '')` expressions already used in `albums_for_artist`).
  - **Tracks:** `track.title` OR its translit/translate display values (same override-aware expressions as `tracks_for_album`), joined to `release` for `release_mbid` + `album_artist_mbid`.
- **Caps + ranking:** each group limited to `limit` rows (default 8). Order prefix-matches first (the original/reading/translation that starts with the query), then by the entity's normal sort (artist sort-name; album by date/title; track by title) — all `COLLATE NOCASE`.
- New `pub fn` → **flutter_rust_bridge regen**.

### Flutter (`lib/`)

- `searchQueryProvider` (a `NotifierProvider<.., String>` holding the current query) and `searchResultsProvider` (a `FutureProvider<SearchResults>` that `ref.watch`es the query and calls the FFI; returns empty for a blank query). The query string is debounced (~150 ms) in the field widget before it updates the provider. Seam providers follow the existing typedef+Provider pattern for testability.
- `SearchField` widget placed in `TopControls`' center (replacing the bare `Spacer`), with a sensible `max-width` so it doesn't crowd transport/volume; `Ctrl/Cmd-F` focuses it, `Esc` clears + closes. It remains visible (top bar) even when the queue is expanded and the browse columns are hidden.
- `SearchResultsOverlay` — a grouped, keyboard-navigable floating panel (Artists / Albums / Tracks, each with a "+N more" hint when capped), shown while the query is non-empty and focused. Rows render with `BilingualText` like the browse columns. `↑/↓` move a single highlighted selection across the flattened list, `Enter` selects, click selects, `Esc`/click-away closes. Empty results show "No matches".
- **Navigation on select:** set the selection providers so the cascade reveals the hit and scroll the relevant column(s) to it, then close the overlay:
  - Artist hit → `selectedArtistProvider.select(mbid)`.
  - Album hit → `selectedArtistProvider.select(album.albumArtistMbid)` then `selectedAlbumProvider.select(album.releaseMbid)`.
  - Track hit → select artist + album as above, then `selectedTrackProvider.select(track.id)`.
  - Scroll-to: the browse `ListView.builder`s use a fixed `itemExtent`, so a `ScrollController` can jump to `index * extent`; the columns expose/accept the target so the selected row is visible. (Scroll-into-view is the trickiest part; selecting/highlighting is the hard requirement, scrolling the column to it is included.)

## Edge cases

- Blank query → no overlay, no FFI call. 1–2 character queries work (plain `LIKE`, no trigram minimum). Whitespace-only → treated as blank.
- Query containing `%`, `_`, or `\` is escaped (`ESCAPE '\'`) so it matches literally.
- A track whose recording appears on multiple releases: the hit navigates to one release (the joined `release_mbid`); acceptable.
- Diacritics are not folded (e.g. `Tokyo` won't match `Tōkyō`); acceptable for v1 (romaji rarely uses macrons in this catalog).
- The result structs are rebuilt on each query; no caching beyond Riverpod's.

## Testing

- **Rust** (`search_catalog`): a query matches an artist by name / original / reading; an album by translit and by translate; a track by its own title (orig/reading/translation) — and importantly, a query matching only an *artist's* name does NOT return that artist's tracks (own-field matching). Case-insensitivity (`shiina` matches `Shiina`); Japanese substring (`椎名` matches `椎名林檎`); `%`/`_` escaped to literal; per-group cap honored; track results carry `release_mbid` + `album_artist_mbid`.
- **Flutter**: the overlay renders grouped hits from a stubbed `searchResultsProvider`; selecting an album hit sets `selectedArtist` + `selectedAlbum` via the seam providers; selecting a track sets all three; `Esc`/blank clears; debounce coalesces rapid keystrokes into one query update.

## Out of scope

- Fuzzy / typo-tolerant matching; search history / recent searches; searching lyrics, file paths, or tags; the replace-the-browse-area results layout; building the entity-aware FTS5 index (the trigram spike is left untouched); collapse-to-icon behavior on narrow windows (the field gets a max-width and simply shrinks).
