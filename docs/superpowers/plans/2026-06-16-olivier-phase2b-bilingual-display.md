# Phase 2b — Bilingual Display + A/B Language Toggle Implementation Plan

> For agentic workers: This is a **TDD** plan spanning the Rust catalog layer, the FFI bridge, and the Flutter UI. Work top to bottom. Every task is a self-contained loop: write a failing test, run it and watch it fail, write the minimum code to pass, run it and watch it pass, then commit. Do **not** batch tasks. All paths are relative to the repo root `/home/autarch/projects/olivier`. The Rust crate name is `rust_lib_olivier`; the crate lives in `rust/`. Run Rust tests with `cd rust && cargo test`. Run Flutter analysis with `mise exec -- flutter analyze` and build with `mise exec -- flutter build linux --debug`. Run Flutter widget tests with `mise exec -- flutter test`. Regenerate the FFI bridge with `mise exec -- flutter_rust_bridge_codegen generate` **from the repo root** after any change to a bridged struct (`Artist`/`Album`/`Track`) or any bridged function signature. Run lint with `mise exec -- precious lint --all`. This is **Phase 2b** (display + toggle only). Phase 3 (bilingual FTS **search**, **playlists**, **queue/shuffle UI**, and the per-artist manual transliteration **override**) follows once 2b lands.

## Open questions / decisions I made

1. **Extend the existing `Artist`/`Album`/`Track` DTOs, do NOT add parallel bilingual structs.** The three structs are already the single browse payload every Dart column consumes; the original `name`/`title` stays the canonical original-script value, and I add **nullable** bilingual fields alongside it (`transliteration` on `Artist`; `title_translit` + `title_translate` on `Album`; `title_translit` + `title_translate` on `Track`). A parallel struct would force every consumer to zip two lists and double the FFI marshalling for no benefit — the data is 1:1 with the row. Nullability is the natural "Latin-only / not-enriched" signal (the column is `NULL` when MusicBrainz had no alias/pseudo-release), so no extra "is bilingual" boolean is needed. This does mean a `flutter_rust_bridge_codegen generate` + a sweep of every Dart consumer; Task 5 does exactly that as one atomic step.

2. **Original stays primary in the struct; the *widget* decides which line leads.** The Rust layer is display-agnostic: it always returns `name`/`title` = original, plus the (nullable) reading/translation. Layout A vs B is purely a Flutter rendering decision driven by the `languageLeads` provider, so flipping the toggle never re-queries Rust — it just re-renders. This keeps the sort orders (computed in Rust, §6.1) completely untouched.

3. **The bilingual widget picks what to show by a fixed precedence, not a mode flag per field.** For a **name** (artist), the only alternate is `transliteration` (a reading). For a **title** (album/track), there may be a romaji `translit` *and* an English `translate`; per spec §6 the primary line is "reading/translation" and the original is secondary. The widget renders, in layout A: **primary** = `translit ?? translate ?? original` and, when *both* a translit and translate exist, shows them together (`Muzai Moratorium · "Innocence Moratorium"`) with the original beneath; **secondary** = original (only when it differs from the primary). Layout B swaps: original leads, the reading/translation sits beneath. A single helper computes the `(primary, secondary)` pair so the artist/album/track call sites and the now-playing bar all share one code path.

4. **"Latin-only" / single-line detection = all alternates null or equal to the original.** When `transliteration`/`title_translit`/`title_translate` are all null (un-enriched or genuinely Latin), the widget collapses to one line. I also collapse when the alternate, trimmed, equals the original (case-insensitively) so a redundant MB alias never renders a duplicated two-line row.

5. **The toggle is a `Notifier<LanguageLeads>` hydrated once at startup from `get_setting('language_leads')`.** A `languageLeadsProvider` (a `Notifier`, not a `FutureProvider`, so widgets read a plain enum synchronously) starts at the default `A`, kicks off an async `getSetting` load in `build()` that updates state when it resolves, and exposes `toggle()`/`set(...)` that write through `setSetting` and update state immediately (optimistic). Display widgets `ref.watch(languageLeadsProvider)`, so toggling re-renders the columns and now-playing bar live with no DB round-trip on the read path. Default is `A` (matches the Rust `DEFAULTS` table and the spec).

6. **Now-playing bilingual support carries the alts through `MediaItem.extras`.** `MediaItem` (from `audio_service`) has only `title`/`artist` string fields, and it is the source of truth the bar already watches. Rather than fork that stream, `PlaybackController._buildItems`/`restoreNowPlaying` stash the (nullable) `titleTranslit`/`titleTranslate` into `extras`, and the bar renders them through the same shared bilingual helper. This needs the alts on the `Track` DTO (Task 3) and on `QueueTrack` (Task 4) so a restored session is bilingual too.

7. **`tracks_for_album` must stay 1 row per track despite the new join.** It already `GROUP BY t.id`; `track_title_alt` has up to two rows per recording (`translit` + `translate`), so I pivot with `MAX(CASE WHEN tta.kind='translit' THEN tta.title END)` aggregates inside the existing GROUP BY — no row-count change. `albums_for_artist` has no GROUP BY today, and `release_title_alt` is keyed `(release_mbid, kind)` (≤2 rows/release), so I pivot it with **correlated scalar subqueries** (cleanest; preserves the existing single-row-per-release shape and the exact ORDER BY).

8. **Manual per-artist transliteration override is explicitly OUT (Phase 3 / post-v1).** I note in Task 1 where the schema already leaves room: `artist.sort_name_embedded` preserves the pre-enrichment sort tag (so an override UI can recover it), and a future editable `artist.transliteration_override` column would slot in without touching these queries. No code for it here.

---

## Goal

Surface the bilingual data Phase 2a persisted (`artist.transliteration`, `release_title_alt`, `track_title_alt`) through the catalog queries and DTOs, render it in the Artists/Albums/Tracks columns and the now-playing bar via a reusable layout-A/B bilingual-text widget, and add a Settings A/B language-leads toggle backed by the existing `setting('language_leads')` and exposed through a Riverpod provider the display widgets watch so the toggle re-renders live.

## Architecture

The Rust catalog queries (`albums_for_artist`, `tracks_for_album`, `artists_page`) gain LEFT-JOIN/pivot reads of the title-alt tables and the artist transliteration column, returned as new **nullable** fields on the existing bridged `Artist`/`Album`/`Track` structs (original `name`/`title` unchanged, sort orders unchanged). A single Flutter `BilingualText` widget consumes `(original, translit, translate)` plus a `LanguageLeads` enum and renders layout A (reading/translation leads) or layout B (original leads), collapsing to one line when no alternate exists. A `languageLeadsProvider` (`Notifier<LanguageLeads>`) hydrates from `get_setting` at startup and is written by a Settings toggle through `set_setting`; every display call site watches it so a flip re-renders without re-querying.

## Tech Stack

- **Rust** (crate `rust_lib_olivier`, edition 2021): `rusqlite` 0.40 (bundled SQLite, FKs enforced), no new deps — pure query + DTO changes. Tests: `cargo test` integration tests in `rust/tests/catalog_test.rs`, `:memory:` SQLite.
- **flutter_rust_bridge** 2.12.0: the three browse DTOs are bridged; codegen via `mise exec -- flutter_rust_bridge_codegen generate` (config `flutter_rust_bridge.yaml`: `rust_input: crate::api`, `dart_output: lib/src/rust`). No new bridged *functions* — only struct field additions.
- **Flutter** (`flutter_riverpod` ^3.3.2, `audio_service`, `just_audio`): new `lib/widgets/bilingual_text.dart`, new `LanguageLeads` provider in `lib/state/providers.dart`, modifications to the catalog columns, now-playing bar, settings page, and playback controller. Widget tests via `flutter_test` in `test/`.
- **Lint/tidy**: `precious` (clippy `-D warnings`, rustfmt, dart format/analyze) via `mise exec -- precious lint --all`.

---

## File structure

### New files

| Path | Responsibility |
|---|---|
| `lib/widgets/bilingual_text.dart` | The reusable `BilingualText` widget + `LanguageLeads` enum + the pure `resolveBilingual(...)` helper that computes the `(primary, secondary)` pair for layout A/B. |
| `test/bilingual_text_test.dart` | Widget + unit tests for `resolveBilingual` and `BilingualText` (layout A, layout B, Latin-only collapse, both-alts title, and `prefix`/`suffix` riding the leading line in both layouts incl. the translate-only and Latin-only cases). |
| `test/language_leads_provider_test.dart` | Tests the `languageLeadsProvider` hydrate/toggle/persist behaviour with a fake settings backend. |

### Modified files

| Path | Change |
|---|---|
| `rust/src/catalog/schema.rs` | Add nullable bilingual fields: `Artist.transliteration`, `Album.title_translit`/`title_translate`, `Track.title_translit`/`title_translate`, and `QueueTrack.title_translit`/`title_translate`. |
| `rust/src/catalog/query.rs` | `artists_page` selects `a.transliteration`; `albums_for_artist` adds correlated `release_title_alt` subqueries; `tracks_for_album` adds `track_title_alt` LEFT JOIN + `MAX(CASE…)` pivots; `tracks_for_paths` adds the track alts. |
| `rust/tests/catalog_test.rs` | New assertions on the bilingual fields for each query; existing tests updated for the new struct fields. |
| `rust/src/frb_generated.rs` | Regenerated by codegen (do not hand-edit). |
| `lib/src/rust/catalog/schema.dart` | Regenerated Dart DTOs (do not hand-edit). |
| `lib/state/providers.dart` | Add `LanguageLeads` enum import + `languageLeadsProvider` (`Notifier`). |
| `lib/catalog/artist_column.dart` | Render `BilingualText` for the artist name + transliteration. |
| `lib/catalog/album_column.dart` | Render `BilingualText` for the album title alts; keep the year suffix and play button. |
| `lib/catalog/track_column.dart` | Render `BilingualText` for the track title alts. |
| `lib/audio/playback_controller.dart` | Stash `titleTranslit`/`titleTranslate` into `MediaItem.extras` in `_buildItems` and `restoreNowPlaying`. **Note:** `selectedAlbumObjectProvider` / `SelectedAlbumObject` (used by the Albums/Tracks columns and Task 11) live in this file, **not** in `lib/state/providers.dart` — grep here for them. (`languageLeadsProvider` is still added to `lib/state/providers.dart`.) |
| `lib/widgets/now_playing_bar.dart` | Render the now-playing title via `BilingualText` using the extras; watch `languageLeadsProvider`. |
| `lib/settings/settings_page.dart` | Add the A/B language-leads toggle (a `SegmentedButton` or `SwitchListTile`) wired to `languageLeadsProvider`. |

---

## Tasks

### Task 1: `Artist.transliteration` field + `artists_page` reads it

The Phase 2a migration already added `artist.transliteration TEXT` (nullable) and `artist.sort_name_embedded TEXT`. No migration needed. (Note for Phase 3: the future per-artist override UI can recover the pre-enrichment sort tag from `sort_name_embedded` and would add an editable `transliteration_override` column — neither is touched here.)

**Files:**
- Modify: `rust/src/catalog/schema.rs`
- Modify: `rust/src/catalog/query.rs`
- Test: `rust/tests/catalog_test.rs`

**Steps:**

- [ ] Add a failing test to `rust/tests/catalog_test.rs` that seeds an artist with a transliteration and asserts `artists_page` returns it, and that a null transliteration round-trips as `None`. Place it after `artists_page_limit`:
  ```rust
  #[test]
  fn artists_page_returns_transliteration() {
      let conn = open(":memory:").unwrap();
      conn.execute(
          "INSERT INTO artist(mbid, name, sort_name, transliteration)
           VALUES ('m-ringo', '椎名林檎', 'Sheena, Ringo', 'Ringo Sheena')",
          [],
      )
      .unwrap();
      // A Latin-only artist with no transliteration.
      conn.execute(
          "INSERT INTO artist(mbid, name, sort_name) VALUES ('m-beatles', 'The Beatles', 'Beatles, The')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r1', 'm-ringo', 'X')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r2', 'm-beatles', 'Y')",
          [],
      )
      .unwrap();

      let page = artists_page(&conn, None, 50).unwrap();
      assert_eq!(page.len(), 2);
      // Ordered by sort_name: "Beatles, The" then "Sheena, Ringo".
      assert_eq!(page[0].name, "The Beatles");
      assert_eq!(page[0].transliteration, None);
      assert_eq!(page[1].name, "椎名林檎");
      assert_eq!(page[1].transliteration, Some("Ringo Sheena".to_string()));
  }
  ```
- [ ] Run `cd rust && cargo test artists_page_returns_transliteration`. Expected: **compile error** (no field `transliteration` on `Artist`). That is the failing state.
- [ ] Add the field to the `Artist` struct in `rust/src/catalog/schema.rs`:
  ```rust
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub struct Artist {
      pub mbid: String,
      pub name: String,
      pub sort_name: String,
      pub transliteration: Option<String>,
  }
  ```
- [ ] Update `artists_page` in `rust/src/catalog/query.rs` to select and map the column. Keep the existing WHERE/ORDER/LIMIT exactly:
  ```rust
  let mut stmt = conn.prepare(
      "SELECT a.mbid, a.name, a.sort_name, a.transliteration FROM artist a
       WHERE a.mbid IN (SELECT DISTINCT album_artist_mbid FROM release)
         AND (?1 IS NULL OR a.sort_name > ?1 COLLATE NOCASE)
       ORDER BY a.sort_name COLLATE NOCASE LIMIT ?2",
  )?;
  let rows = stmt.query_map(rusqlite::params![after, limit], |r| {
      Ok(Artist {
          mbid: r.get(0)?,
          name: r.get(1)?,
          sort_name: r.get(2)?,
          transliteration: r.get(3)?,
      })
  })?;
  ```
- [ ] The existing `artists_page_*` and `reconcile_*` tests construct artists via SQL (not the struct), so they keep compiling. Run `cd rust && cargo test --test catalog_test`. Expected: all green, including the new test.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(catalog): Artist.transliteration field + artists_page reads it"`.

---

### Task 2: `Album` title alts via `release_title_alt` subqueries

**Files:**
- Modify: `rust/src/catalog/schema.rs`
- Modify: `rust/src/catalog/query.rs`
- Test: `rust/tests/catalog_test.rs`

**Steps:**

- [ ] Add a failing test to `rust/tests/catalog_test.rs` that seeds a release with both alt kinds and one with none, asserting the pivot and that ordering is unaffected:
  ```rust
  #[test]
  fn albums_for_artist_returns_title_alts() {
      let conn = open(":memory:").unwrap();
      conn.execute(
          "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'Shiina', 'Shiina')",
          [],
      )
      .unwrap();
      // Album with both a romaji translit and an English translate.
      conn.execute(
          "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('rel-jp', 'm', '無罪モラトリアム', '1999')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO release_title_alt(release_mbid, kind, title) VALUES ('rel-jp', 'translit', 'Muzai Moratorium')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO release_title_alt(release_mbid, kind, title) VALUES ('rel-jp', 'translate', 'Innocence Moratorium')",
          [],
      )
      .unwrap();
      // A Latin-only album, no alts, later year so it sorts second.
      conn.execute(
          "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('rel-en', 'm', 'Sport', '2014')",
          [],
      )
      .unwrap();

      let albums = albums_for_artist(&conn, "m").unwrap();
      assert_eq!(albums.len(), 2);
      // 1999 album first (ordering unchanged), with both alts.
      assert_eq!(albums[0].title, "無罪モラトリアム");
      assert_eq!(albums[0].title_translit, Some("Muzai Moratorium".to_string()));
      assert_eq!(albums[0].title_translate, Some("Innocence Moratorium".to_string()));
      // Latin-only album: both alts null.
      assert_eq!(albums[1].title, "Sport");
      assert_eq!(albums[1].title_translit, None);
      assert_eq!(albums[1].title_translate, None);
  }
  ```
- [ ] Run `cd rust && cargo test albums_for_artist_returns_title_alts`. Expected: **compile error** (no `title_translit`/`title_translate` on `Album`). Failing state confirmed.
- [ ] Add the fields to `Album` in `rust/src/catalog/schema.rs`:
  ```rust
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub struct Album {
      pub release_mbid: String,
      pub title: String,
      pub album_artist: String,
      pub original_year: Option<String>,
      pub reissue_year: Option<String>,
      pub title_translit: Option<String>,
      pub title_translate: Option<String>,
  }
  ```
- [ ] Update `albums_for_artist` in `rust/src/catalog/query.rs`. Use correlated scalar subqueries so the single-row-per-release shape and the exact `ORDER BY` are untouched:
  ```rust
  let mut stmt = conn.prepare(
      "SELECT r.mbid, r.title, a.name,
              substr(rg.first_release_date, 1, 4), substr(r.date, 1, 4),
              (SELECT title FROM release_title_alt
                 WHERE release_mbid = r.mbid AND kind = 'translit'),
              (SELECT title FROM release_title_alt
                 WHERE release_mbid = r.mbid AND kind = 'translate')
       FROM release r
       JOIN artist a ON a.mbid = r.album_artist_mbid
       LEFT JOIN release_group rg ON rg.mbid = r.release_group_mbid
       WHERE r.album_artist_mbid = ?1
       ORDER BY COALESCE(rg.first_release_date, r.date, '9999'), r.title COLLATE NOCASE",
  )?;
  let rows = stmt.query_map([album_artist_mbid], |r| {
      Ok(Album {
          release_mbid: r.get(0)?,
          title: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
          album_artist: r.get(2)?,
          original_year: r.get(3)?,
          reissue_year: r.get(4)?,
          title_translit: r.get(5)?,
          title_translate: r.get(6)?,
      })
  })?;
  ```
- [ ] The existing `albums_for_artist_*` tests build `Album` via SQL and read individual fields, so they still compile. Run `cd rust && cargo test --test catalog_test`. Expected: all green, including the new test.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(catalog): Album title_translit/title_translate from release_title_alt"`.

---

### Task 3: `Track` title alts via `track_title_alt` pivot (keep 1 row/track)

**Files:**
- Modify: `rust/src/catalog/schema.rs`
- Modify: `rust/src/catalog/query.rs`
- Test: `rust/tests/catalog_test.rs`

**Steps:**

- [ ] Add a failing test to `rust/tests/catalog_test.rs`. The key invariant: a track with two alt rows (translit + translate) must still produce exactly one `Track`, and the original disc/position ordering must hold:
  ```rust
  #[test]
  fn tracks_for_album_returns_title_alts_one_row_per_track() {
      let conn = open(":memory:").unwrap();
      conn.execute(
          "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'A', 'A')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
          [],
      )
      .unwrap();
      // Track 1: Japanese with both alts (two track_title_alt rows).
      conn.execute(
          "INSERT INTO track(id, release_mbid, recording_mbid, disc, position, title)
           VALUES (1, 'rel', 'rec-1', 1, 1, '正しい街')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO track_title_alt(recording_mbid, kind, title) VALUES ('rec-1', 'translit', 'Tadashii Machi')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO track_title_alt(recording_mbid, kind, title) VALUES ('rec-1', 'translate', 'The Right Town')",
          [],
      )
      .unwrap();
      // Track 2: Latin-only, no recording_mbid, no alts.
      conn.execute(
          "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2, 'rel', 1, 2, 'Sport')",
          [],
      )
      .unwrap();

      let tracks = tracks_for_album(&conn, "rel").unwrap();
      assert_eq!(tracks.len(), 2, "two alt rows must not duplicate the track");
      assert_eq!(tracks[0].position, 1);
      assert_eq!(tracks[0].title, "正しい街");
      assert_eq!(tracks[0].title_translit, Some("Tadashii Machi".to_string()));
      assert_eq!(tracks[0].title_translate, Some("The Right Town".to_string()));
      assert_eq!(tracks[1].position, 2);
      assert_eq!(tracks[1].title_translit, None);
      assert_eq!(tracks[1].title_translate, None);
  }
  ```
- [ ] Run `cd rust && cargo test tracks_for_album_returns_title_alts_one_row_per_track`. Expected: **compile error** (no `title_translit`/`title_translate` on `Track`). Failing state confirmed.
- [ ] Add the fields to `Track` in `rust/src/catalog/schema.rs` (append after `added_at`):
  ```rust
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub struct Track {
      pub id: i64,
      pub disc: u32,
      pub position: u32,
      pub title: String,
      pub artist: Option<String>,
      pub length_ms: Option<u64>,
      pub last_played: Option<i64>,
      pub added_at: i64,
      pub title_translit: Option<String>,
      pub title_translate: Option<String>,
  }
  ```
- [ ] Update `tracks_for_album` in `rust/src/catalog/query.rs`. The query already `GROUP BY t.id`; add a LEFT JOIN on `track_title_alt` (which can yield two rows per track) and collapse it with `MAX(CASE…)` so the grain stays one row per track:
  ```rust
  let mut stmt = conn.prepare(
      "SELECT t.id, t.disc, t.position, t.title, t.artist, t.length_ms,
              s.last_played, MIN(f.added_at),
              MAX(CASE WHEN tta.kind = 'translit' THEN tta.title END),
              MAX(CASE WHEN tta.kind = 'translate' THEN tta.title END)
       FROM track t
       LEFT JOIN track_stats s ON s.track_id = t.id
       LEFT JOIN file f ON f.track_id = t.id
       LEFT JOIN track_title_alt tta ON tta.recording_mbid = t.recording_mbid
       WHERE t.release_mbid = ?1
       GROUP BY t.id
       ORDER BY t.disc, t.position",
  )?;
  let rows = stmt.query_map([release_mbid], |r| {
      Ok(Track {
          id: r.get(0)?,
          disc: r.get::<_, i64>(1)? as u32,
          position: r.get::<_, i64>(2)? as u32,
          title: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
          artist: r.get(4)?,
          length_ms: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
          last_played: r.get(6)?,
          added_at: r.get::<_, Option<i64>>(7)?.unwrap_or(0),
          title_translit: r.get(8)?,
          title_translate: r.get(9)?,
      })
  })?;
  ```
  Note: the `LEFT JOIN … ON tta.recording_mbid = t.recording_mbid` correctly contributes nothing when `t.recording_mbid IS NULL` (SQL `NULL = NULL` is not true), so untagged tracks get null alts — exactly what the test asserts.
  Note: once the `track_title_alt` LEFT JOIN is added, every non-grouped projected column must sit inside an aggregate (the new alt columns use `MAX(CASE WHEN kind=…)`); `s.last_played` stays safe under `GROUP BY t.id` only because `track_stats` is PK'd by `track_id` (exactly one row per track), so it is functionally dependent on the GROUP BY key.
- [ ] Run `cd rust && cargo test --test catalog_test`. Expected: all green. (The existing `tracks_for_album_ordered_by_disc_position` test reads fields it still has, and builds via SQL, so it passes unchanged.)
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(catalog): Track title_translit/title_translate via track_title_alt pivot"`.

---

### Task 4: `QueueTrack` title alts (so a restored now-playing bar is bilingual)

**Files:**
- Modify: `rust/src/catalog/schema.rs`
- Modify: `rust/src/catalog/query.rs`
- Test: `rust/tests/catalog_test.rs`

**Steps:**

- [ ] Add a failing test to `rust/tests/catalog_test.rs` asserting `tracks_for_paths` returns the track alts for a catalogued path, and null for a placeholder:
  ```rust
  #[test]
  fn tracks_for_paths_returns_title_alts() {
      let conn = open(":memory:").unwrap();
      conn.execute(
          "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'A', 'A')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO track(id, release_mbid, recording_mbid, disc, position, title)
           VALUES (1, 'rel', 'rec-1', 1, 1, '正しい街')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO track_title_alt(recording_mbid, kind, title) VALUES ('rec-1', 'translit', 'Tadashii Machi')",
          [],
      )
      .unwrap();
      conn.execute(
          "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES ('/m/a.flac', 0, 0, 1, 0)",
          [],
      )
      .unwrap();

      let paths = vec!["/m/a.flac".to_string(), "/m/missing.mp3".to_string()];
      let got = tracks_for_paths(&conn, &paths).unwrap();
      assert_eq!(got[0].title_translit, Some("Tadashii Machi".to_string()));
      assert_eq!(got[0].title_translate, None);
      // Placeholder has no alts.
      assert_eq!(got[1].title_translit, None);
      assert_eq!(got[1].title_translate, None);
  }
  ```
- [ ] Run `cd rust && cargo test tracks_for_paths_returns_title_alts`. Expected: **compile error** (no fields on `QueueTrack`). Failing state confirmed.
- [ ] Add the fields to `QueueTrack` in `rust/src/catalog/schema.rs` (append after `length_ms`):
  ```rust
  pub title_translit: Option<String>,
  pub title_translate: Option<String>,
  ```
- [ ] Update `tracks_for_paths` in `rust/src/catalog/query.rs`. Add the two correlated subqueries to the SELECT and populate both the found and placeholder branches:
  ```rust
  let mut stmt = conn.prepare(
      "SELECT t.id, t.title, t.artist, t.length_ms, r.title,
              (SELECT title FROM track_title_alt
                 WHERE recording_mbid = t.recording_mbid AND kind = 'translit'),
              (SELECT title FROM track_title_alt
                 WHERE recording_mbid = t.recording_mbid AND kind = 'translate')
       FROM file f JOIN track t ON t.id = f.track_id
       JOIN release r ON r.mbid = t.release_mbid
       WHERE f.path = ?1",
  )?;
  ```
  In the `query_row` closure, add `title_translit: r.get(5)?, title_translate: r.get(6)?,`. In the placeholder `unwrap_or_else` branch, add `title_translit: None, title_translate: None,`.
- [ ] The existing `tracks_for_paths_preserves_order_with_placeholder` test reads named fields and still compiles. Run `cd rust && cargo test --test catalog_test`. Expected: all green.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(catalog): QueueTrack title alts for restored now-playing"`.

---

### Task 5: Regenerate the FFI bridge + fix all Dart consumers (atomic)

This is the one task that crosses the FFI boundary. The three DTOs changed, so codegen rewrites `lib/src/rust/catalog/schema.dart` and `rust/src/frb_generated.rs`, and every Dart site that constructs or destructures these DTOs must keep compiling. We do **not** render the new fields yet — that is Tasks 7–10. This task only re-greens the build.

**Files:**
- Modify (regenerated): `rust/src/frb_generated.rs`, `lib/src/rust/catalog/schema.dart`, `lib/src/rust/frb_generated.*.dart`

**Steps:**

- [ ] Confirm the Rust side builds (it must, after Tasks 1–4): `cd rust && cargo build`. Expected: `Finished`.
- [ ] From the repo root, run codegen: `mise exec -- flutter_rust_bridge_codegen generate`. Expected: it rewrites the generated files and prints no errors. Verify the new fields appear: the `Album` class in `lib/src/rust/catalog/schema.dart` should now have `final String? titleTranslit;` and `final String? titleTranslate;`, `Artist` should have `final String? transliteration;`, and `Track`/`QueueTrack` should have the two alt fields.
- [ ] Run `mise exec -- flutter analyze`. Expected: **green** — the new fields are nullable and optional in the generated constructors, so existing Dart that builds these DTOs from FFI (it doesn't construct them by hand) keeps compiling. If `analyze` flags any site that pattern-matches all fields, fix it minimally. (No production Dart constructs these DTOs directly today; they all come from FFI return values, so this should be clean.)
- [ ] Run `mise exec -- flutter test`. Expected: **green** — the existing widget/smoke test must still pass after the DTO sweep, so a regression in this atomic FFI change is caught here, not only in Task 13.
- [ ] Run `mise exec -- flutter build linux --debug`. Expected: build succeeds.
- [ ] Run `mise exec -- precious lint --all`. Expected: green (generated files are excluded or already formatted; if precious reformats a generated file, that is fine — commit it).
- [ ] Commit: `git commit -am "chore(ffi): regenerate bridge for bilingual DTO fields"`.

---

### Task 6: The `BilingualText` widget + `resolveBilingual` helper (pure logic first)

Build the rendering primitive in isolation with its own tests before wiring it into any column. Decision 3/4 lives here.

**Files:**
- Create: `lib/widgets/bilingual_text.dart`
- Test: `test/bilingual_text_test.dart`

**Steps:**

- [ ] Write `test/bilingual_text_test.dart` testing the pure `resolveBilingual` helper first (no widget pump needed). Cover: layout A name (reading leads), layout A title with both alts (romaji · "translation"), layout B (original leads), Latin-only collapse, and alt-equals-original collapse:
  ```dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:olivier/widgets/bilingual_text.dart';

  void main() {
    group('resolveBilingual', () {
      test('layout A name: reading leads, original beneath', () {
        final r = resolveBilingual(
          original: '椎名林檎',
          translit: 'Ringo Sheena',
          translate: null,
          leads: LanguageLeads.a,
        );
        expect(r.primary, 'Ringo Sheena');
        expect(r.secondary, '椎名林檎');
      });

      test('layout A title with both alts: romaji and translation joined', () {
        final r = resolveBilingual(
          original: '無罪モラトリアム',
          translit: 'Muzai Moratorium',
          translate: 'Innocence Moratorium',
          leads: LanguageLeads.a,
        );
        expect(r.primary, 'Muzai Moratorium · "Innocence Moratorium"');
        expect(r.secondary, '無罪モラトリアム');
      });

      test('layout A title with only translation', () {
        final r = resolveBilingual(
          original: '無罪モラトリアム',
          translit: null,
          translate: 'Innocence Moratorium',
          leads: LanguageLeads.a,
        );
        expect(r.primary, 'Innocence Moratorium');
        expect(r.secondary, '無罪モラトリアム');
      });

      test('layout B: original leads, reading beneath', () {
        final r = resolveBilingual(
          original: '椎名林檎',
          translit: 'Ringo Sheena',
          translate: null,
          leads: LanguageLeads.b,
        );
        expect(r.primary, '椎名林檎');
        expect(r.secondary, 'Ringo Sheena');
      });

      test('Latin-only collapses to a single line (no secondary)', () {
        final r = resolveBilingual(
          original: 'The Beatles',
          translit: null,
          translate: null,
          leads: LanguageLeads.a,
        );
        expect(r.primary, 'The Beatles');
        expect(r.secondary, isNull);
      });

      test('alt equal to original (case-insensitive) collapses', () {
        final r = resolveBilingual(
          original: 'Cornelius',
          translit: 'cornelius',
          translate: null,
          leads: LanguageLeads.a,
        );
        expect(r.primary, 'Cornelius');
        expect(r.secondary, isNull);
      });
    });

    testWidgets('BilingualText renders two lines in layout A', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BilingualText(
              original: '椎名林檎',
              translit: 'Ringo Sheena',
              translate: null,
              leads: LanguageLeads.a,
            ),
          ),
        ),
      );
      expect(find.text('Ringo Sheena'), findsOneWidget);
      expect(find.text('椎名林檎'), findsOneWidget);
    });

    testWidgets('BilingualText renders one line when Latin-only', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BilingualText(
              original: 'The Beatles',
              translit: null,
              translate: null,
              leads: LanguageLeads.a,
            ),
          ),
        ),
      );
      expect(find.text('The Beatles'), findsOneWidget);
    });

    // The prefix/suffix attach to the LEADING (primary) line only, AFTER
    // resolveBilingual picks primary/secondary. They must stay on the top line
    // in both layouts and in the translate-only and Latin-only cases.
    testWidgets('suffix sits on the leading line in layout A', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BilingualText(
              original: '無罪モラトリアム',
              translit: 'Muzai Moratorium',
              translate: null,
              leads: LanguageLeads.a,
              suffix: ' (1999)',
            ),
          ),
        ),
      );
      // Reading leads in A, so the suffix rides the reading line; original is bare.
      expect(find.text('Muzai Moratorium (1999)'), findsOneWidget);
      expect(find.text('無罪モラトリアム'), findsOneWidget);
    });

    testWidgets('suffix sits on the leading line in layout B', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BilingualText(
              original: '無罪モラトリアム',
              translit: 'Muzai Moratorium',
              translate: null,
              leads: LanguageLeads.b,
              suffix: ' (1999)',
            ),
          ),
        ),
      );
      // Original leads in B, so the suffix rides the original line; reading is bare.
      expect(find.text('無罪モラトリアム (1999)'), findsOneWidget);
      expect(find.text('Muzai Moratorium'), findsOneWidget);
    });

    testWidgets('translate-only: suffix stays on the leading translation line in A',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BilingualText(
              original: '無罪モラトリアム',
              translit: null,
              translate: 'Innocence Moratorium',
              leads: LanguageLeads.a,
              suffix: ' (1999)',
            ),
          ),
        ),
      );
      // Translation leads in A; the year must ride it, not the bare original.
      expect(find.text('Innocence Moratorium (1999)'), findsOneWidget);
      expect(find.text('無罪モラトリアム'), findsOneWidget);
    });

    testWidgets('Latin-only single line still carries the suffix', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BilingualText(
              original: 'Sport',
              translit: null,
              translate: null,
              leads: LanguageLeads.a,
              suffix: ' (2014)',
            ),
          ),
        ),
      );
      expect(find.text('Sport (2014)'), findsOneWidget);
    });
  }
  ```
- [ ] Run `mise exec -- flutter test test/bilingual_text_test.dart`. Expected: **fails to compile** (no `lib/widgets/bilingual_text.dart`). Failing state confirmed.
- [ ] Create `lib/widgets/bilingual_text.dart` with the enum, the pure helper, and the widget:
  ```dart
  import 'package:flutter/material.dart';

  /// Which script leads in a bilingual row. `a` = reading/translation primary
  /// (spec layout A, default); `b` = original primary (layout B).
  enum LanguageLeads { a, b }

  /// The two lines a bilingual row renders. [secondary] is null when the row
  /// collapses to a single line (Latin-only, or no distinct alternate).
  class BilingualLines {
    const BilingualLines(this.primary, this.secondary);
    final String primary;
    final String? secondary;
  }

  /// Compute the (primary, secondary) lines for a bilingual entry.
  ///
  /// - A *name* passes only [translit] (a reading); a *title* may pass both a
  ///   [translit] (romaji) and a [translate] (English).
  /// - Layout A leads with the reading/translation; layout B leads with the
  ///   original. When no distinct alternate exists the row collapses to one line.
  BilingualLines resolveBilingual({
    required String original,
    required String? translit,
    required String? translate,
    required LanguageLeads leads,
  }) {
    final t1 = (translit ?? '').trim();
    final t2 = (translate ?? '').trim();
    final orig = original.trim();

    // Build the "alternate" line: romaji and translation together when both
    // exist (titles), otherwise whichever is present.
    final String alt;
    if (t1.isNotEmpty && t2.isNotEmpty) {
      alt = '$t1 · "$t2"';
    } else if (t1.isNotEmpty) {
      alt = t1;
    } else {
      alt = t2; // may be empty
    }

    // Collapse: no alternate, or the alternate is just the original again.
    final altIsRedundant = alt.isEmpty ||
        alt.toLowerCase() == orig.toLowerCase() ||
        (t2.isEmpty && t1.toLowerCase() == orig.toLowerCase());
    if (altIsRedundant) {
      return BilingualLines(orig, null);
    }

    switch (leads) {
      case LanguageLeads.a:
        return BilingualLines(alt, orig);
      case LanguageLeads.b:
        return BilingualLines(orig, alt);
    }
  }

  /// Renders an entry's original plus its reading/translation as one or two
  /// lines, per the current [leads] mode. The primary line uses [primaryStyle]
  /// (defaults to the ambient body style); the secondary is dimmer/smaller.
  ///
  /// [prefix]/[suffix] are a pure *rendering* concern: they are applied to the
  /// **leading (primary) line only**, AFTER [resolveBilingual] has chosen which
  /// of original/reading/translation leads. That keeps a year suffix or a
  /// track-number prefix glued to the top line in BOTH layouts (in layout A it
  /// rides the reading/translation line; in layout B it rides the original
  /// line) and, crucially, in the translate-only case (where the leading line
  /// is the translation, not the original). [resolveBilingual] itself never
  /// sees them, so the bilingual pair is unaffected.
  class BilingualText extends StatelessWidget {
    const BilingualText({
      super.key,
      required this.original,
      required this.translit,
      required this.translate,
      required this.leads,
      this.prefix,
      this.suffix,
      this.primaryStyle,
    });

    final String original;
    final String? translit;
    final String? translate;
    final LanguageLeads leads;
    final String? prefix;
    final String? suffix;
    final TextStyle? primaryStyle;

    @override
    Widget build(BuildContext context) {
      final lines = resolveBilingual(
        original: original,
        translit: translit,
        translate: translate,
        leads: leads,
      );
      // Decorate the leading line only, after primary/secondary is chosen.
      final primary = '${prefix ?? ''}${lines.primary}${suffix ?? ''}';
      final theme = Theme.of(context);
      final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );
      if (lines.secondary == null) {
        return Text(
          primary,
          style: primaryStyle,
          overflow: TextOverflow.ellipsis,
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(primary, style: primaryStyle, overflow: TextOverflow.ellipsis),
          Text(lines.secondary!, style: secondaryStyle, overflow: TextOverflow.ellipsis),
        ],
      );
    }
  }
  ```
- [ ] Run `mise exec -- flutter test test/bilingual_text_test.dart`. Expected: all tests green.
- [ ] Run `mise exec -- flutter analyze` and `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(ui): BilingualText widget + resolveBilingual layout A/B helper"`.

---

### Task 7: `languageLeadsProvider` — hydrate from settings, toggle, persist

**Files:**
- Modify: `lib/state/providers.dart`
- Test: `test/language_leads_provider_test.dart`

**Steps:**

- [ ] Write `test/language_leads_provider_test.dart`. Because the provider calls the FFI `getSetting`/`setSetting`, the test drives it through small indirection: the provider reads/writes via two function-typed providers (`getSettingFnProvider`/`setSettingFnProvider`) that default to the real FFI but can be overridden in tests. The test overrides them with fakes:
  ```dart
  import 'package:flutter_riverpod/flutter_riverpod.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:olivier/state/providers.dart';
  import 'package:olivier/widgets/bilingual_text.dart';

  void main() {
    test('hydrates from getSetting=B', () async {
      String? stored = 'B';
      final container = ProviderContainer(
        overrides: [
          dbPathProvider.overrideWithValue('/tmp/x.db'),
          getSettingFnProvider.overrideWithValue((key) async => stored),
          setSettingFnProvider.overrideWithValue((key, value) async {
            stored = value;
          }),
        ],
      );
      addTearDown(container.dispose);

      // Default before hydration.
      expect(container.read(languageLeadsProvider), LanguageLeads.a);
      // Let the async hydrate complete.
      await container.read(languageLeadsProvider.notifier).hydrate();
      expect(container.read(languageLeadsProvider), LanguageLeads.b);
    });

    test('toggle persists and flips state', () async {
      String? stored = 'A';
      final container = ProviderContainer(
        overrides: [
          dbPathProvider.overrideWithValue('/tmp/x.db'),
          getSettingFnProvider.overrideWithValue((key) async => stored),
          setSettingFnProvider.overrideWithValue((key, value) async {
            stored = value;
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(languageLeadsProvider.notifier).toggle();
      expect(container.read(languageLeadsProvider), LanguageLeads.b);
      expect(stored, 'B');

      await container.read(languageLeadsProvider.notifier).toggle();
      expect(container.read(languageLeadsProvider), LanguageLeads.a);
      expect(stored, 'A');
    });
  }
  ```
- [ ] Run `mise exec -- flutter test test/language_leads_provider_test.dart`. Expected: **fails to compile** (no `getSettingFnProvider`, `languageLeadsProvider`). Failing state confirmed.
- [ ] Add to `lib/state/providers.dart` (import the enum and the FFI settings binding at the top):
  ```dart
  import 'package:olivier/src/rust/api/settings.dart' as rust_settings;
  import 'package:olivier/widgets/bilingual_text.dart';
  ```
  and append:
  ```dart
  // --- Language-leads (A/B) display mode ---

  // Indirection seams so the provider is unit-testable without the FFI.
  typedef GetSettingFn = Future<String?> Function(String key);
  typedef SetSettingFn = Future<void> Function(String key, String value);

  final getSettingFnProvider = Provider<GetSettingFn>((ref) {
    final db = ref.watch(dbPathProvider);
    return (key) => rust_settings.getSetting(dbPath: db, key: key);
  });

  final setSettingFnProvider = Provider<SetSettingFn>((ref) {
    final db = ref.watch(dbPathProvider);
    return (key, value) =>
        rust_settings.setSetting(dbPath: db, key: key, value: value);
  });

  const _languageLeadsKey = 'language_leads';

  class LanguageLeadsNotifier extends Notifier<LanguageLeads> {
    @override
    LanguageLeads build() {
      // Default to A immediately; hydrate the stored value asynchronously.
      unawaited(hydrate());
      return LanguageLeads.a;
    }

    Future<void> hydrate() async {
      final raw = await ref.read(getSettingFnProvider)(_languageLeadsKey);
      state = _parse(raw);
    }

    Future<void> set(LanguageLeads leads) async {
      state = leads; // optimistic
      await ref.read(setSettingFnProvider)(
        _languageLeadsKey,
        leads == LanguageLeads.a ? 'A' : 'B',
      );
    }

    Future<void> toggle() =>
        set(state == LanguageLeads.a ? LanguageLeads.b : LanguageLeads.a);

    static LanguageLeads _parse(String? raw) =>
        raw == 'B' ? LanguageLeads.b : LanguageLeads.a;
  }

  final languageLeadsProvider =
      NotifierProvider<LanguageLeadsNotifier, LanguageLeads>(
    LanguageLeadsNotifier.new,
  );
  ```
  Add `import 'dart:async' show unawaited;` at the top of the file.
- [ ] Run `mise exec -- flutter test test/language_leads_provider_test.dart`. Expected: green. (The `build()`'s `unawaited(hydrate())` fires on first read; the test then awaits an explicit `hydrate()` to be deterministic.)
- [ ] Run `mise exec -- flutter analyze` and `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(state): languageLeadsProvider hydrate/toggle/persist via settings FFI"`.

---

### Task 8: Render `BilingualText` in the Artists column

**Files:**
- Modify: `lib/catalog/artist_column.dart`

**Steps:**

- [ ] In `lib/catalog/artist_column.dart`, add imports and watch the leads provider in `_ArtistList.build` (it is already a `ConsumerWidget`):
  ```dart
  import 'package:olivier/widgets/bilingual_text.dart';
  ```
  Inside `_ArtistList.build`, after reading `selected`:
  ```dart
  final leads = ref.watch(languageLeadsProvider);
  ```
- [ ] Replace the `_RowLabel(text: artist.name)` call with `BilingualText`, and pass the leads down. Replace the `_RowLabel` widget usage:
  ```dart
  child: BilingualText(
    original: artist.name,
    translit: artist.transliteration,
    translate: null, // names get a reading only (spec §6)
    leads: leads,
  ),
  ```
- [ ] Because a two-line row is now possible, the fixed `itemExtent: 48` may clip. Keep `itemExtent: 48` (matches Phase 1 row height; two compact lines fit at the default body + bodySmall sizes). If a runtime check (Task 12) shows clipping, the follow-up is to drop `itemExtent` to let rows size naturally — note this in Task 12. The `_RowLabel` class is now unused; delete it.
- [ ] Run `mise exec -- flutter analyze`. Expected: green (no unused `_RowLabel`).
- [ ] Run `mise exec -- flutter build linux --debug`. Expected: build succeeds.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(ui): bilingual artist rows in the Artists column"`.

---

### Task 9: Render `BilingualText` in the Albums column (keep year + play button)

**Files:**
- Modify: `lib/catalog/album_column.dart`

**Steps:**

- [ ] In `lib/catalog/album_column.dart`, add `import 'package:olivier/widgets/bilingual_text.dart';` and watch the provider in `_AlbumList.build`:
  ```dart
  final leads = ref.watch(languageLeadsProvider);
  ```
- [ ] Replace the `label` string + `_RowLabel(text: label)` with a `BilingualText` for the title, and pass the year as the widget's `suffix` so it always rides the **leading** line (whichever it is) instead of being baked into the title strings. Do **not** interpolate the year into `original`/`translit`. Replace the `Expanded(child: _RowLabel(text: label))` with:
  ```dart
  Expanded(
    child: BilingualText(
      original: album.title,
      translit: album.titleTranslit,
      translate: album.titleTranslate,
      leads: leads,
      suffix: year.isNotEmpty ? ' ($year)' : null,
    ),
  ),
  ```
  Keep the `final year = album.originalYear ?? album.reissueYear ?? '';` line (compute `$year` exactly as the column does today); remove the now-unused `label` local. Passing the year as `suffix` keeps it on the top line in every mode — including a **translate-only** album, where layout A leads with the (year-less) English translation and the `suffix` still attaches the year to that line. The interpolation approach failed there: it baked the year into `translit`, which is null when only a translation exists, so the year fell off the leading line.
- [ ] The `onTap`/`playAlbum` calls still pass `album.title` (the original) — leave those unchanged; playback metadata uses the original title as the album name and Task 11 handles the bilingual now-playing title separately. The `_RowLabel` class is now unused; delete it.
- [ ] Run `mise exec -- flutter analyze`. Expected: green.
- [ ] Run `mise exec -- flutter build linux --debug`. Expected: build succeeds.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(ui): bilingual album rows (title alts + year) in the Albums column"`.

---

### Task 10: Render `BilingualText` in the Tracks column

**Files:**
- Modify: `lib/catalog/track_column.dart`

**Steps:**

- [ ] In `lib/catalog/track_column.dart`, add `import 'package:olivier/widgets/bilingual_text.dart';` and watch the provider in `_TrackList.build` (after the existing `releaseMbid`/`albumObj` reads — `albumObj` comes from `selectedAlbumObjectProvider`, which is defined in `lib/audio/playback_controller.dart`, **not** `lib/state/providers.dart`):
  ```dart
  final leads = ref.watch(languageLeadsProvider);
  ```
- [ ] Replace the `Expanded(child: _RowLabel(text: '${track.position}. ${track.title}'))` with a `BilingualText`, passing the track number as the widget's `prefix` so it stays glued to the **leading** line (whichever it is) rather than being baked into the title strings. Do **not** prefix the number into `original`/`translit`:
  ```dart
  Expanded(
    child: BilingualText(
      original: track.title,
      translit: track.titleTranslit,
      translate: track.titleTranslate,
      leads: leads,
      prefix: '${track.position}. ',
    ),
  ),
  ```
  Keep the trailing length `Text(_formatLength(track.lengthMs), …)` unchanged. Passing the number as `prefix` keeps it on the top line in every mode — including a track whose only alt is a **translation** (layout A leads with the translation, and the `prefix` rides that line); the old approach prefixed only `original`/`translit`, so the number showed only on the original line there. The `_RowLabel` class is now unused; delete it.
- [ ] Run `mise exec -- flutter analyze`. Expected: green.
- [ ] Run `mise exec -- flutter build linux --debug`. Expected: build succeeds.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(ui): bilingual track rows in the Tracks column"`.

---

### Task 11: Bilingual now-playing bar (carry alts through `MediaItem.extras`)

The bar watches `audioHandler.mediaItem` (an `audio_service` `MediaItem`), which has only `title`/`artist` strings. Carry the alts in `extras` and render them with `BilingualText`. The now-playing bar must also watch `languageLeadsProvider`, so it becomes a `ConsumerWidget`.

**Files:**
- Modify: `lib/audio/playback_controller.dart`
- Modify: `lib/widgets/now_playing_bar.dart`
- Modify: `lib/catalog/browser_page.dart` (the `NowPlayingBar(audioHandler: …)` call site stays the same shape; no change needed unless the constructor changes — it does not)

**Steps:**

- [ ] In `lib/audio/playback_controller.dart`, populate the alts into `extras`. In `_buildItems`, change the `extras` map:
  ```dart
  extras: {
    'trackId': tracks[i].id,
    'titleTranslit': tracks[i].titleTranslit,
    'titleTranslate': tracks[i].titleTranslate,
  },
  ```
  In `restoreNowPlaying`, change the per-item `extras`:
  ```dart
  extras: {
    if (qt.trackId != null) 'trackId': qt.trackId,
    'titleTranslit': qt.titleTranslit,
    'titleTranslate': qt.titleTranslate,
  },
  ```
  (The play-tracking code reads `extras?['trackId']` and type-checks it `is int`, so adding string entries is safe; the `restoreNowPlaying` conditional key keeps the existing "no trackId for placeholder" behaviour.)
- [ ] Convert `NowPlayingBar` to a `ConsumerWidget` in `lib/widgets/now_playing_bar.dart`. Change the imports and class:
  ```dart
  import 'package:flutter_riverpod/flutter_riverpod.dart';
  import 'package:olivier/widgets/bilingual_text.dart';
  // ...
  class NowPlayingBar extends ConsumerWidget {
    const NowPlayingBar({super.key, required this.audioHandler});
    final OlivierAudioHandler audioHandler;
    // ... _player, _posStream getters unchanged ...

    @override
    Widget build(BuildContext context, WidgetRef ref) {
      final leads = ref.watch(languageLeadsProvider);
      // ... existing body ...
  ```
- [ ] In the title/artist `StreamBuilder<MediaItem?>`, replace the bold `Text(item.title, …)` with a `BilingualText` driven by the extras (keep the artist `Text` beneath it unchanged):
  ```dart
  BilingualText(
    original: item.title,
    translit: item.extras?['titleTranslit'] as String?,
    translate: item.extras?['titleTranslate'] as String?,
    leads: leads,
    primaryStyle: Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontWeight: FontWeight.bold),
  ),
  ```
- [ ] `browser_page.dart` constructs `NowPlayingBar(audioHandler: audioHandler)` inside a `ConsumerStatefulWidget`'s build, which has a `ref` in scope and a `ProviderScope` ancestor, so a `ConsumerWidget` child resolves the provider fine — **no change needed** there. Confirm by analyzing.
- [ ] Run `mise exec -- flutter analyze`. Expected: green.
- [ ] Run `mise exec -- flutter build linux --debug`. Expected: build succeeds.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(ui): bilingual now-playing title via MediaItem extras"`.

---

### Task 12: The A/B language-leads toggle in Settings

**Files:**
- Modify: `lib/settings/settings_page.dart`

**Steps:**

- [ ] In `lib/settings/settings_page.dart`, add imports:
  ```dart
  import 'package:olivier/state/providers.dart';
  import 'package:olivier/widgets/bilingual_text.dart';
  ```
- [ ] Watch the provider at the top of `build` (it is already a `ConsumerWidget`):
  ```dart
  final leads = ref.watch(languageLeadsProvider);
  ```
- [ ] Add a "Display" section with a `SegmentedButton<LanguageLeads>` to the `ListView`'s `children`, after the music-folders block (before the closing `]`). Place it under a section header for consistency with "Music folders":
  ```dart
  const SizedBox(height: 24),
  Text('Display', style: Theme.of(context).textTheme.titleMedium),
  const SizedBox(height: 8),
  const Text(
    'Language leads: which script shows first in bilingual rows.',
    style: TextStyle(color: Colors.grey),
  ),
  const SizedBox(height: 8),
  SegmentedButton<LanguageLeads>(
    segments: const [
      ButtonSegment(
        value: LanguageLeads.a,
        label: Text('Reading / translation (A)'),
      ),
      ButtonSegment(
        value: LanguageLeads.b,
        label: Text('Original (B)'),
      ),
    ],
    selected: {leads},
    onSelectionChanged: (sel) =>
        ref.read(languageLeadsProvider.notifier).set(sel.first),
  ),
  ```
- [ ] Run `mise exec -- flutter analyze`. Expected: green.
- [ ] Run `mise exec -- flutter build linux --debug`. Expected: build succeeds.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(ui): A/B language-leads toggle in Settings"`.

---

### Task 13: Full-suite verification + manual runtime check

Automated steps verify the build and logic; the actual *look* (two-line rows, layout flip, no clipping) is human-verified at runtime, exactly as Phase 1's UI was.

**Files:** none (verification only)

**Steps:**

- [ ] Run the whole Rust suite: `cd rust && cargo test`. Expected: all green, including the four new bilingual query tests.
- [ ] Run the whole Flutter suite: `mise exec -- flutter test`. Expected: all green (`bilingual_text_test.dart`, `language_leads_provider_test.dart`, and the existing smoke test).
- [ ] Run `mise exec -- flutter analyze` and `mise exec -- precious lint --all`. Expected: green.
- [ ] Run `mise exec -- flutter build linux --debug`. Expected: build succeeds.
- [ ] **Manual runtime check (human):** launch the app against a library that has at least one enriched Japanese artist/album (e.g. Shiina Ringo / 無罪モラトリアム). Verify:
  - Artists column shows `Ringo Sheena` over `椎名林檎`; Latin-only artists show one line.
  - Albums column shows romaji + English translation over the original, with the year still visible; Latin-only albums show one line; the play button still works.
  - Tracks column shows the track number attached to the leading line; lengths still align on the right.
  - Now-playing bar shows the bilingual title for both a freshly played track and a queue **restored on startup**.
  - Toggling Settings → Display → "Original (B)" flips every visible row **live** (no restart) so the original leads; flipping back to A restores layout A. Restart the app and confirm the choice persisted.
  - Check the artist/album/track rows for **clipping** at `itemExtent: 48`. If two-line rows clip, drop the `itemExtent` in the three columns (let rows size to content) and re-verify; record that as a follow-up commit if needed.
- [ ] No commit unless the clipping follow-up was required.

---

## Done criteria for Phase 2b

- The Rust catalog queries return the bilingual fields: `Artist.transliteration`, `Album.title_translit`/`title_translate`, `Track.title_translit`/`title_translate`, and `QueueTrack.title_translit`/`title_translate`. The §6.1 sort orders (artists by case-insensitive `sort_name`, albums by original year then title, tracks by disc/position) are **unchanged**, and `tracks_for_album` still returns exactly one row per track.
- `flutter_rust_bridge_codegen generate` has been re-run; the generated DTOs carry the new nullable fields and the whole app builds.
- A reusable `BilingualText` widget renders layout A (reading/translation leads) and layout B (original leads), collapses Latin-only / redundant entries to one line, and joins a title's romaji + English translation on the primary line — all unit/widget-tested.
- The Artists, Albums, and Tracks columns and the now-playing bar (including a queue restored on startup) render through `BilingualText`.
- A Settings A/B toggle, backed by `setting('language_leads')` (default `A`) via `get_setting`/`set_setting` and exposed through `languageLeadsProvider`, flips every display widget **live** and persists across restarts — verified at runtime.
- `cargo test`, `flutter test`, `flutter analyze`, `flutter build linux --debug`, and `precious lint --all` are all green.

## Phase 3 (follows)

Phase 3 covers the **bilingual FTS search** (the `search` FTS5 table over original + romaji + translation + sort names, §4/§6), **playlists** (create/rename/delete, bilingual tracklists), the **queue/shuffle UI** (drag-reorder, remove, clear, shuffle-all), and the **per-artist manual transliteration override** (the post-v1 editable column the schema already leaves room for — `artist.sort_name_embedded` preserves the recoverable pre-enrichment sort tag). None of those are in 2b.

---

### Critical Files for Implementation

- `/home/autarch/projects/olivier/rust/src/catalog/query.rs` — the three queries (`artists_page`, `albums_for_artist`, `tracks_for_album`) plus `tracks_for_paths` that gain the alt joins/pivots.
- `/home/autarch/projects/olivier/rust/src/catalog/schema.rs` — the bridged `Artist`/`Album`/`Track`/`QueueTrack` structs to extend with nullable bilingual fields.
- `/home/autarch/projects/olivier/lib/widgets/bilingual_text.dart` (new) — the `BilingualText` widget + `resolveBilingual` layout-A/B helper every display site shares.
- `/home/autarch/projects/olivier/lib/state/providers.dart` — the new `languageLeadsProvider` (hydrate/toggle/persist) the display widgets watch.
- `/home/autarch/projects/olivier/lib/audio/playback_controller.dart` — carries the title alts into `MediaItem.extras` so the now-playing bar (and restored sessions) render bilingual.