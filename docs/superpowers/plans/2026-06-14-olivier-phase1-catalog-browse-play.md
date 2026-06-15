# Olivier Phase 1 — Catalog + Browse + Play (Linux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Phase-0 scaffold into the first real, usable Linux app — scan a music tree into a catalog, browse Artists → Albums → Tracks (grouped by album artist) in a resizable column UI, and play albums/tracks with a now-playing bar and real MPRIS metadata. Embedded tags only — **no MusicBrainz enrichment yet (single language)**.

**Architecture:** Rust core owns the catalog: an `ignore`-based scanner (single-threaded for Phase 1; parallel walk + writer-thread is a later optimization) reads embedded tags (`lofty`, single-parse) and upserts into a SQLite schema (`artist`/`release_group`/`release`/`track`/`file`/`track_stats`) keyed by embedded MBIDs with synthetic fallbacks; it exposes paged query DTOs and a scan-progress stream over `flutter_rust_bridge`. Flutter owns the UI: a `multi_split_view` 3-column Miller browser with `flutter_riverpod` selection state, real queue playback via `just_audio`/`audio_service` (libmpv on Linux), a reactive now-playing bar, and MPRIS metadata fed from `MediaItem`s.

**Tech Stack:** Rust + `rusqlite`(bundled, FTS5) + `rusqlite_migration` 2.6 + `ignore` 0.4 + `lofty` 0.24 · `flutter_rust_bridge` 2.12 · Flutter + `flutter_riverpod` 3.3 + `multi_split_view` 3.6 + `just_audio` 0.10 / `just_audio_media_kit` 2.1 + `audio_service` 0.18 / `audio_service_mpris` 1.0.0-beta.2 + `rxdart`.

**Spec:** [docs/superpowers/specs/2026-06-13-olivier-design.md](../specs/2026-06-13-olivier-design.md) — this plan implements §9 "Phase 1" (§4 data model, §5 scan, §6 UI/§6.1 sort, §7 Linux).

**Phase-0 outcomes assumed:** the scaffold, `read_tags`, the `db.rs` `open()`/migrations/queue, the FFI bridge, and the `just_audio`/`audio_service`/MPRIS wiring all exist and work (see [phase0-results.md](../spikes/phase0-results.md)). Lint/format is **precious** (`mise exec -- precious tidy --all` / `lint --all`); run all flutter/dart/codegen via `mise exec -- …`.

---

## Design decisions (locked with the user)

- **Synthetic identity for un-enriched entities.** Files are Picard-tagged so most carry real MBIDs; when an MBID tag is absent, synthesize a stable, readable key from the normalized name: `synth:aa:<norm album-artist>`, `synth:rg:<norm album-artist|album>`, `synth:rel:<norm album-artist|album>`. `recording_mbid` may remain `NULL` (it is not part of the track upsert key).
- **Track upsert key is `(release_mbid, disc, position)`** — always present, so NULL `recording_mbid` is fine; `recording_mbid` is stored as a nullable attribute for future cross-release identity. Every file maps to exactly one `track` row; duplicate files collapse onto the same track.
- **Sort names from Picard tags.** `read_tags` is extended to read the sort tags (`TSO2`/`TSOP`, `ALBUMARTISTSORT`/`ARTISTSORT`, `soaa`/`soar`). `artist.sort_name` = the embedded album-artist sort tag when present (Picard already writes "Beatles, The" form), else the display name with a leading `A`/`An`/`The` stripped.
- **Single-parse.** `read_tags` is refactored to parse each file once (read the concrete format file type once, extract common + MBIDs + sort + dates + cover from its native tag) — collapsing the Phase-0 double parse.

---

## Prerequisites / dependency delta

**Rust** (`rust/Cargo.toml` `[dependencies]`): add `ignore = "0.4.26"`; bump `rusqlite_migration` to `"2.6"`.

**Flutter** (`pubspec.yaml` `dependencies`): add `flutter_riverpod: ^3.3.2`, `multi_split_view: ^3.6.2`, `rxdart: ^0.28.0`. (`just_audio`, `just_audio_media_kit`, `audio_service`, `audio_service_mpris`, `path_provider` are already present.)

---

## File structure (created/modified)

```
rust/src/
  tags.rs              # MODIFY: + sort fields, single-parse refactor (Task 2)
  catalog/             # NEW module — the real catalog
    mod.rs             #   pub mod schema; pub mod scan; pub mod query; re-exports
    schema.rs          #   migrations + DTO structs (Artist/Album/Track) (Task 1)
    ids.rs             #   synthetic-id + sort-name + normalize helpers (Task 1/5)
    scan.rs            #   ignore walker + transactional upsert (single-threaded) (Task 3)
    query.rs           #   artists_page / albums_for_artist / tracks_for_album (Task 4)
  db.rs                # MODIFY: append catalog migrations (Task 1)
  api/
    catalog.rs         # NEW: FFI — scan_roots(StreamSink), queries, record_play (Task 6/7)
  lib.rs               # MODIFY: pub mod catalog;
rust/tests/
  catalog_test.rs      # NEW: schema/scan/query/sort/play tests (Task 1,3,4,5,6)

lib/
  main.dart            # MODIFY: ProviderScope, retire spike UI (Task 8,12)
  state/
    providers.dart     # NEW: Riverpod providers (selection chain, queries) (Task 8)
  catalog/
    browser_page.dart  # NEW: 3-column Miller browser (Task 8)
    artist_column.dart, album_column.dart, track_column.dart  # NEW (Task 8)
  audio/
    playback_controller.dart # NEW: build queue from catalog, drive handler (Task 9)
    audio_handler.dart   # MODIFY: feed MediaItem from currentIndex (Task 10)
  widgets/
    now_playing_bar.dart # NEW: reactive bottom bar (Task 9)
  settings/
    settings_page.dart   # NEW: root folders + scan w/ progress (Task 11)
integration_test/
  catalog_ffi_test.dart  # NEW: scan+query bridge test (Task 7)
docs/superpowers/spikes/phase1-results.md  # NEW (Task 13)
```

---

## Task 1: Catalog schema + DTOs + id helpers (Rust, TDD)

**Files:** Create `rust/src/catalog/mod.rs`, `rust/src/catalog/schema.rs`, `rust/src/catalog/ids.rs`, `rust/tests/catalog_test.rs`; Modify `rust/src/lib.rs`, `rust/src/db.rs`, `rust/Cargo.toml`.

- [ ] **Step 1: Deps.** In `rust/Cargo.toml`: add `ignore = "0.4.26"`, bump `rusqlite_migration = "2.6"`.

- [ ] **Step 2: Module + lib.** Create `rust/src/catalog/mod.rs`:
```rust
pub mod ids;
pub mod query;
pub mod scan;
pub mod schema;
```
Add `pub mod catalog;` to `rust/src/lib.rs`. Create `rust/src/catalog/scan.rs` and `rust/src/catalog/query.rs` now as empty files containing only `//! filled in later tasks`, so the `mod.rs` declarations compile (Tasks 3 and 4 fill them in).

- [ ] **Step 3: Append the catalog migration.** In `rust/src/db.rs`, add a NEW `M::up(...)` to `MIGRATION_SLICE` (append-only — after the existing two):
```rust
    M::up(
        "CREATE TABLE artist (
            mbid       TEXT PRIMARY KEY,
            name       TEXT NOT NULL,
            sort_name  TEXT NOT NULL
         );
         CREATE TABLE release_group (
            mbid                TEXT PRIMARY KEY,
            title               TEXT,
            first_release_date  TEXT
         );
         CREATE TABLE release (
            mbid                TEXT PRIMARY KEY,
            release_group_mbid  TEXT REFERENCES release_group(mbid),
            album_artist_mbid   TEXT REFERENCES artist(mbid),
            title               TEXT,
            date                TEXT
         );
         CREATE TABLE track (
            id              INTEGER PRIMARY KEY,
            release_mbid    TEXT NOT NULL REFERENCES release(mbid),
            recording_mbid  TEXT,
            artist          TEXT,
            disc            INTEGER NOT NULL DEFAULT 1,
            position        INTEGER NOT NULL DEFAULT 1,
            title           TEXT,
            length_ms       INTEGER,
            UNIQUE(release_mbid, disc, position)
         );
         CREATE TABLE file (
            id              INTEGER PRIMARY KEY,
            path            TEXT UNIQUE NOT NULL,
            mtime           INTEGER NOT NULL,
            size            INTEGER NOT NULL,
            codec           TEXT,
            track_id        INTEGER NOT NULL REFERENCES track(id),
            added_at        INTEGER NOT NULL,
            has_cover       INTEGER NOT NULL DEFAULT 0,
            enriched        INTEGER NOT NULL DEFAULT 0,
            scan_epoch      INTEGER NOT NULL DEFAULT 0
         );
         CREATE TABLE track_stats (
            track_id     INTEGER PRIMARY KEY REFERENCES track(id),
            last_played  INTEGER,
            play_count   INTEGER NOT NULL DEFAULT 0,
            first_played INTEGER
         );
         CREATE INDEX idx_release_albumartist ON release(album_artist_mbid);
         CREATE INDEX idx_track_release ON track(release_mbid);
         CREATE INDEX idx_artist_sort ON artist(sort_name);
         CREATE INDEX idx_file_track ON file(track_id);",
    ),
```

- [ ] **Step 4: DTOs (in `rust/src/catalog/schema.rs`).** These cross the FFI bridge later:
```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Artist {
    pub mbid: String,
    pub name: String,
    pub sort_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Album {
    pub release_mbid: String,
    pub title: String,
    pub album_artist: String,
    pub original_year: Option<String>, // 4-char year (queries project substr(date,1,4))
    pub reissue_year: Option<String>,  // 4-char year; for MP4 originals are absent so this is the only year
}

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
}
```

- [ ] **Step 5: id + normalize helpers (`rust/src/catalog/ids.rs`).**
```rust
/// Lowercased, whitespace-collapsed key fragment for synthetic ids.
pub fn normalize(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// Album-artist mbid: real one if present, else a stable synthetic key.
pub fn album_artist_key(mbid: Option<&str>, name: &str) -> String {
    match mbid {
        Some(m) if !m.is_empty() => m.to_string(),
        _ => format!("synth:aa:{}", normalize(name)),
    }
}

pub fn release_group_key(mbid: Option<&str>, album_artist: &str, album: &str) -> String {
    match mbid {
        Some(m) if !m.is_empty() => m.to_string(),
        _ => format!("synth:rg:{}|{}", normalize(album_artist), normalize(album)),
    }
}

pub fn release_key(mbid: Option<&str>, album_artist: &str, album: &str) -> String {
    match mbid {
        Some(m) if !m.is_empty() => m.to_string(),
        _ => format!("synth:rel:{}|{}", normalize(album_artist), normalize(album)),
    }
}

/// Sort key: embedded Picard sort tag if present, else name with a leading
/// English article (A / An / The) stripped.
pub fn sort_name(name: &str, embedded_sort: Option<&str>) -> String {
    if let Some(s) = embedded_sort {
        if !s.is_empty() {
            return s.to_string();
        }
    }
    for art in ["A ", "An ", "The "] {
        if let Some(rest) = name.strip_prefix(art) {
            return rest.to_string();
        }
    }
    name.to_string()
}
```

- [ ] **Step 6: Tests (`rust/tests/catalog_test.rs`).**
```rust
use rust_lib_olivier::catalog::ids::{album_artist_key, sort_name};
use rust_lib_olivier::db::open;

#[test]
fn migration_creates_catalog_tables() {
    let conn = open(":memory:").unwrap();
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table'
             AND name IN ('artist','release_group','release','track','file','track_stats')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 6);
}

#[test]
fn synthetic_keys_and_sort_names() {
    assert_eq!(album_artist_key(Some("abc"), "X"), "abc");
    assert_eq!(album_artist_key(None, "The Beatles"), "synth:aa:the beatles");
    assert_eq!(sort_name("The Beatles", Some("Beatles, The")), "Beatles, The");
    assert_eq!(sort_name("The Beatles", None), "Beatles");
    assert_eq!(sort_name("A Perfect Circle", None), "Perfect Circle");
}
```

- [ ] **Step 7: Run.** `cd rust && cargo test --test catalog_test` → 2 pass. (Module stubs for scan/query must at least compile — give them empty bodies if needed.)

- [ ] **Step 8: Format + lint + commit.**
```bash
cd /home/autarch/projects/olivier && mise exec -- precious tidy --all && mise exec -- precious lint --all
git add rust/Cargo.toml rust/Cargo.lock rust/src/lib.rs rust/src/db.rs rust/src/catalog/ rust/tests/catalog_test.rs
git commit -m "feat(catalog): schema, DTOs, and id/sort helpers"
```

---

## Task 2: Extend `read_tags` — sort names + single parse (Rust, TDD)

**Files:** Modify `rust/src/tags.rs`, `rust/tests/tags_test.rs`. Possibly extend `scripts/make_fixtures.py` + regenerate fixtures.

- [ ] **Step 1: Add sort fields + a `codec` to `TrackTags`** in `rust/src/tags.rs`:
```rust
    pub artist_sort: Option<String>,
    pub album_artist_sort: Option<String>,
    pub codec: Option<String>,
```

- [ ] **Step 2: Add sort tags to fixtures.** In `scripts/make_fixtures.py`, add to the ID3 tagger `t.add(TSOP(encoding=3, text="Shiina, Ringo"))` and `t.add(TSO2(encoding=3, text="Shiina, Ringo"))` (import them); Vorbis: `obj["ARTISTSORT"]="Shiina, Ringo"; obj["ALBUMARTISTSORT"]="Shiina, Ringo"`; MP4: `m["soar"]=["Shiina, Ringo"]; m["soaa"]=["Shiina, Ringo"]`. Regenerate: `./scripts/make-fixtures.sh`.

- [ ] **Step 3: Failing test.** Append to `rust/tests/tags_test.rs`:
```rust
#[test]
fn reads_sort_names_for_all_formats() {
    for name in FILES {
        let t = read_tags(&fixture(name)).unwrap();
        assert_eq!(t.album_artist_sort.as_deref(), Some("Shiina, Ringo"), "{name} aa-sort");
    }
}
```
Run it: `cd rust && cargo test --test tags_test reads_sort_names_for_all_formats` → FAIL.

- [ ] **Step 4: Single-parse refactor + sort extraction.** Restructure `read_tags` so it reads each file's concrete format type **once** and extracts common fields, MBIDs, sort names, dates, and `has_cover` from that one native tag — collapsing the current `Probe::read()` + per-format re-read. Concretely: detect `FileType` via `Probe::open(path)?.guess_file_type()?` (or read once), then `match` to the concrete `*File` (`MpegFile`/`FlacFile`/`VorbisFile`/`OpusFile`/`Mp4File`), read it **once**, and from its native tag pull everything. Reuse the existing Phase-0 per-format MBID code (ID3 `UFID`/`get_user_text`, Vorbis `get`, MP4 freeform). Add the sort keys per format:
  - ID3: `get_user_text` won't help; sort frames are `TSOP`/`TSO2` text frames — read via `id3.get_text(&FrameId::Valid(Cow::Borrowed("TSOP")))` / `"TSO2"` (or the Accessor where available).
  - Vorbis: `vc.get("ARTISTSORT")` / `vc.get("ALBUMARTISTSORT")`.
  - MP4: standard atoms `soar` / `soaa` via `AtomIdent::Fourcc(*b"soar")` etc.
  - Common fields (title/artist/album/album_artist/track/disc/length/dates/cover): **convert the native tag to a unified `Tag` via `lofty::tag::Tag::from(native.clone())`** and reuse the Phase-0 reads unchanged — `tag.title()/artist()/album()`, `tag.get_string(ItemKey::AlbumArtist)`, `tag.get_string(ItemKey::OriginalReleaseDate)` and `ItemKey::RecordingDate`, `tag.track()/track_total()/disk()/disk_total()`, `tag.pictures()`. (`Accessor` has no `album_artist`/original-date methods and the native tags have no `get_string(ItemKey)`, so reading these off the native tag directly will NOT compile — the `Tag::from` conversion keeps it ONE parse while preserving behavior. Read the MBIDs + sort frames off the native tag *before* converting.)
  Set `codec` from the detected `FileType`: `Mpeg`→`"mp3"`, `Flac`→`"flac"`, `Vorbis`→`"vorbis"`, `Opus`→`"opus"`, `Mp4`→`"m4a"`. (Phase 1 stores `"m4a"` for MP4; the AAC-vs-ALAC split is deferred — relax the spec §4 codec enum accordingly. Note: lofty's MP3 variant is `FileType::Mpeg`, not `Mp3`.)
  > This is a refactor of working code — keep behavior identical for the existing tag/MBID/date assertions, add the sort fields, and ensure only one parse occurs. If a lofty API for a sort frame differs, adapt and report.

- [ ] **Step 5: Run** `cd rust && cargo test --test tags_test` → ALL pass (common, MBIDs, dates, sort). `cargo clippy --all-targets -- -D warnings` clean.

- [ ] **Step 6: Format + lint + commit.**
```bash
cd /home/autarch/projects/olivier && mise exec -- precious tidy --all && mise exec -- precious lint --all
git add rust/src/tags.rs rust/tests/tags_test.rs scripts/make_fixtures.py rust/tests/fixtures
git commit -m "feat(core): read sort names; collapse read_tags to a single parse"
```

---

## Task 3: Scanner — `ignore` walk + incremental upsert (Rust, TDD)

**Files:** Create `rust/src/catalog/scan.rs`; Modify `rust/tests/catalog_test.rs`.

- [ ] **Step 1: Implement the scanner.** `rust/src/catalog/scan.rs`:
  - `pub struct ScanProgress { pub files_seen: u64, pub files_changed: u64, pub current: String, pub done: bool }`
  - `pub fn scan_roots(conn: &mut Connection, roots: &[String], mut on_progress: impl FnMut(ScanProgress)) -> anyhow::Result<()>`:
    1. Pick a new `epoch` = `now_unix()`.
    2. Walk each root with `ignore::WalkBuilder` (`.standard_filters(false)`, audio-extension filter for mp3/flac/m4a/ogg/oga/opus), single-threaded for Phase 1 (parallelism is a later optimization — keep the writer simple and correct first).
    3. Per file: `stat` for `(mtime, size)`. Pre-filter: `SELECT mtime, size FROM file WHERE path=?`; if unchanged, just bump `scan_epoch` and continue (no parse). Else `read_tags(path)` and **upsert** (Step 2), counting `files_changed`.
    4. Emit throttled `ScanProgress` (e.g. every 50 files).
    5. Deletion sweep — **FKs ARE enforced** (libsqlite3-sys bundles SQLite with `SQLITE_DEFAULT_FOREIGN_KEYS=1`, so the `REFERENCES` clauses bite). Two consequences: (a) `track_stats` must be deleted **before** `track` (it references it), not after; (b) the file deletion is **scoped to the roots being scanned** (`DELETE FROM file WHERE scan_epoch != ?epoch AND substr(path,1,N)=?prefix` per root) so scanning one folder never deletes another folder's files. Order: scoped `file` delete; then `DELETE FROM track_stats WHERE track_id NOT IN (SELECT track_id FROM file)`; `DELETE FROM track WHERE id NOT IN (SELECT track_id FROM file)`; `DELETE FROM release WHERE mbid NOT IN (SELECT release_mbid FROM track)`; `DELETE FROM release_group WHERE mbid NOT IN (SELECT release_group_mbid FROM release WHERE release_group_mbid IS NOT NULL)`; `DELETE FROM artist WHERE mbid NOT IN (SELECT album_artist_mbid FROM release WHERE album_artist_mbid IS NOT NULL)`. (The orphan cascade is factored into `prune_orphans()`.)
    6. Final `on_progress(ScanProgress{ done: true, .. })`.
  - `fn upsert_file(tx, tags, path, mtime, size, epoch)`: compute keys via `catalog::ids` (`album_artist_key`/`release_group_key`/`release_key` from the album-artist + album names + any embedded MBIDs). Then upsert in this order — each `INSERT ... ON CONFLICT DO UPDATE`, using `COALESCE` so a re-scan of a file lacking a tag never overwrites a real value with NULL:
    - **artist** `(mbid, name, sort_name)` where `sort_name = ids::sort_name(album_artist_name, tags.album_artist_sort.as_deref())`.
    - **release_group** `(mbid, title=album, first_release_date=tags.original_date)`; on conflict `first_release_date = COALESCE(excluded.first_release_date, first_release_date)`.
    - **release** `(mbid, release_group_mbid, album_artist_mbid, title=album, date=tags.reissue_date)`; on conflict `date = COALESCE(excluded.date, date)`.
    - **track** keyed `(release_mbid, disc, position)` — set `recording_mbid=tags.recording_mbid`, **`artist=tags.artist`**, `title=tags.title`, `length_ms`; `RETURNING id` (or re-select) for `track_id`.
    - **file** keyed on `path`: `ON CONFLICT(path) DO UPDATE SET mtime=?,size=?,codec=?,track_id=?,has_cover=?,scan_epoch=?` — **stamp `added_at` only on first insert** (don't touch it on conflict).
    - `INSERT OR IGNORE INTO track_stats(track_id) VALUES(?)`.
    Wrap each file in a transaction.

- [ ] **Step 2: Test against a fixture dir.** Append to `rust/tests/catalog_test.rs` a test that copies the six fixtures into a temp dir, runs `scan_roots`, and asserts: one album-artist (`椎名林檎`), the album present, ≥1 track, and that a re-scan reports `files_changed == 0`. (The six fixtures intentionally share one album-artist and one album/release — Task 2's fixture edits preserve this — so `artist count == 1` and `album count == 1` hold.) Use `tempfile` (add `tempfile = "3"` to `[dev-dependencies]`). Example skeleton:
```rust
#[test]
fn scan_populates_catalog_and_is_incremental() {
    let dir = tempfile::tempdir().unwrap();
    for f in ["sample.mp3","sample.flac"] {
        std::fs::copy(format!("{}/tests/fixtures/{f}", env!("CARGO_MANIFEST_DIR")),
                      dir.path().join(f)).unwrap();
    }
    let mut conn = open(":memory:").unwrap();
    let root = dir.path().to_string_lossy().to_string();
    let mut changed = 0u64;
    scan_roots(&mut conn, &[root.clone()], |p| if p.done { changed = p.files_changed }).unwrap();
    assert!(changed >= 2);
    let artists: i64 = conn.query_row("SELECT count(*) FROM artist", [], |r| r.get(0)).unwrap();
    assert_eq!(artists, 1);
    // re-scan: nothing changed
    let mut changed2 = u64::MAX;
    scan_roots(&mut conn, &[root], |p| if p.done { changed2 = p.files_changed }).unwrap();
    assert_eq!(changed2, 0);
}
```

- [ ] **Step 3: Run** `cd rust && cargo test --test catalog_test` → pass. Clippy clean.

- [ ] **Step 4: Format + lint + commit.**
```bash
cd /home/autarch/projects/olivier && mise exec -- precious tidy --all && mise exec -- precious lint --all
git add rust/src/catalog/scan.rs rust/tests/catalog_test.rs rust/Cargo.toml rust/Cargo.lock
git commit -m "feat(catalog): incremental filesystem scanner + tag upsert"
```

---

## Task 4: Catalog queries — artists/albums/tracks (Rust, TDD)

**Files:** Create/fill `rust/src/catalog/query.rs`; Modify `rust/tests/catalog_test.rs`.

- [ ] **Step 1: Implement queries** in `rust/src/catalog/query.rs`:
```rust
use crate::catalog::schema::{Album, Artist, Track};
use rusqlite::Connection;

/// Keyset page of album-artists ordered by sort_name. Pass the previous page's
/// last sort_name as `after` (None for the first page).
pub fn artists_page(conn: &Connection, after: Option<&str>, limit: u32) -> anyhow::Result<Vec<Artist>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT a.mbid, a.name, a.sort_name FROM artist a
         WHERE a.mbid IN (SELECT DISTINCT album_artist_mbid FROM release)
           AND (?1 IS NULL OR a.sort_name > ?1)
         ORDER BY a.sort_name LIMIT ?2",
    )?;
    let rows = stmt.query_map(rusqlite::params![after, limit], |r| {
        Ok(Artist { mbid: r.get(0)?, name: r.get(1)?, sort_name: r.get(2)? })
    })?;
    for r in rows { out.push(r?); }
    Ok(out)
}

/// Albums for one album-artist, ordered by original year then title (spec §6.1).
pub fn albums_for_artist(conn: &Connection, album_artist_mbid: &str) -> anyhow::Result<Vec<Album>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT r.mbid, r.title, a.name, substr(rg.first_release_date, 1, 4), substr(r.date, 1, 4)
         FROM release r
         JOIN artist a ON a.mbid = r.album_artist_mbid
         LEFT JOIN release_group rg ON rg.mbid = r.release_group_mbid
         WHERE r.album_artist_mbid = ?1
         ORDER BY COALESCE(rg.first_release_date, r.date, '9999'), r.title",
    )?;
    let rows = stmt.query_map([album_artist_mbid], |r| {
        Ok(Album {
            release_mbid: r.get(0)?, title: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
            album_artist: r.get(2)?, original_year: r.get(3)?, reissue_year: r.get(4)?,
        })
    })?;
    for r in rows { out.push(r?); }
    Ok(out)
}

/// Tracks for one album (release), ordered by disc then position (spec §6.1).
pub fn tracks_for_album(conn: &Connection, release_mbid: &str) -> anyhow::Result<Vec<Track>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT t.id, t.disc, t.position, t.title, t.artist, t.length_ms,
                s.last_played, MIN(f.added_at)
         FROM track t
         LEFT JOIN track_stats s ON s.track_id = t.id
         LEFT JOIN file f ON f.track_id = t.id
         WHERE t.release_mbid = ?1
         GROUP BY t.id
         ORDER BY t.disc, t.position",
    )?;
    let rows = stmt.query_map([release_mbid], |r| {
        Ok(Track {
            id: r.get(0)?, disc: r.get::<_, i64>(1)? as u32, position: r.get::<_, i64>(2)? as u32,
            title: r.get::<_, Option<String>>(3)?.unwrap_or_default(), artist: r.get(4)?,
            length_ms: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
            last_played: r.get(6)?, added_at: r.get::<_, Option<i64>>(7)?.unwrap_or(0),
        })
    })?;
    for r in rows { out.push(r?); }
    Ok(out)
}

/// Absolute file paths for an album in track order (for building the play queue).
pub fn file_paths_for_album(conn: &Connection, release_mbid: &str) -> anyhow::Result<Vec<String>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT f.path FROM track t JOIN file f ON f.track_id = t.id
         WHERE t.release_mbid = ?1 ORDER BY t.disc, t.position",
    )?;
    let rows = stmt.query_map([release_mbid], |r| r.get::<_, String>(0))?;
    for r in rows { out.push(r?); }
    Ok(out)
}
```

- [ ] **Step 2: Test** (append to `catalog_test.rs`): after a scan of the fixtures, `artists_page(&conn, None, 50)` returns the one artist; `albums_for_artist(&conn, &that.mbid)` returns the album; `tracks_for_album(&conn, &album.release_mbid)` returns the tracks ordered by position. Assert ordering and the bilingual-deferred single titles.

- [ ] **Step 3: Run + lint + commit** (`feat(catalog): paged browse queries (artists/albums/tracks)`).

---

## Task 5: Sort-name application in the scanner (Rust, TDD)

> Task 1 added the `sort_name` helper; Task 3 stores `artist.sort_name`. This task locks the behavior with a focused test, since it drives the whole browse ordering.

- [ ] **Step 1: Test** (append to `catalog_test.rs`): scan a temp dir of fixtures whose album-artist sort tag is `Shiina, Ringo`; assert the stored `artist.sort_name == "Shiina, Ringo"` — the embedded-sort path, end-to-end through the scanner. The article-stripping fallback (`The Beatles` → `Beatles`, `A Perfect Circle` → `Perfect Circle`) is already unit-tested on the `ids::sort_name` helper in Task 1 Step 6, so no extra no-sort fixture is needed here.
- [ ] **Step 2: Ensure the scanner passes `album_artist_sort` into `sort_name(...)`** when upserting the artist. Run, lint, commit (`feat(catalog): derive artist sort names from Picard tags`).

---

## Task 6: Play tracking (Rust, TDD)

**Files:** Modify `rust/src/catalog/query.rs` (the Task 7 FFI wrapper calls `query::record_play`, so keep it here); `rust/tests/catalog_test.rs`.

- [ ] **Step 1: Implement** `record_play(conn, track_id, played_at_unix)`: `INSERT INTO track_stats(track_id, last_played, play_count, first_played) VALUES(?, ?, 1, ?) ON CONFLICT(track_id) DO UPDATE SET last_played=excluded.last_played, play_count=play_count+1, first_played=COALESCE(first_played, excluded.first_played)`. (The "what counts as a play" threshold — finish/≥50%/4 min — is enforced Dart-side; Rust just records.) Spec §4's append-only `play(track_id, played_at)` event table is **deferred** — Phase 1 maintains only the `track_stats` aggregate, which is all the UI needs now.
- [ ] **Step 2: Test:** seed a track, `record_play` twice, assert `play_count==2`, `last_played` updated, `first_played` unchanged.
- [ ] **Step 3: Run + lint + commit** (`feat(catalog): record_play / play stats`).

---

## Task 7: FFI surface — scan stream + queries + record_play (Rust→Dart)

**Files:** Create `rust/src/api/catalog.rs`; Modify `rust/src/api/mod.rs`; regenerate bindings; Create `integration_test/catalog_ffi_test.dart`.

- [ ] **Step 1: FFI wrappers** in `rust/src/api/catalog.rs`. Each opens the DB by path (like `api/queue.rs`); the scan takes a `StreamSink`:
```rust
use crate::catalog::{query, scan, schema::{Album, Artist, Track}};
use crate::db;
use crate::frb_generated::StreamSink;

pub fn scan_library(db_path: String, roots: Vec<String>, sink: StreamSink<scan::ScanProgress>) -> anyhow::Result<()> {
    let mut conn = db::open(&db_path)?;
    scan::scan_roots(&mut conn, &roots, |p| { let _ = sink.add(p); })
}
pub fn list_artists(db_path: String, after: Option<String>, limit: u32) -> anyhow::Result<Vec<Artist>> {
    query::artists_page(&db::open(&db_path)?, after.as_deref(), limit)
}
pub fn list_albums(db_path: String, album_artist_mbid: String) -> anyhow::Result<Vec<Album>> {
    query::albums_for_artist(&db::open(&db_path)?, &album_artist_mbid)
}
pub fn list_tracks(db_path: String, release_mbid: String) -> anyhow::Result<Vec<Track>> {
    query::tracks_for_album(&db::open(&db_path)?, &release_mbid)
}
pub fn album_file_paths(db_path: String, release_mbid: String) -> anyhow::Result<Vec<String>> {
    query::file_paths_for_album(&db::open(&db_path)?, &release_mbid)
}
pub fn record_play(db_path: String, track_id: i64, played_at: i64) -> anyhow::Result<()> {
    query::record_play(&db::open(&db_path)?, track_id, played_at)
}
```
Add `pub mod catalog;` to `rust/src/api/mod.rs`. Make `ScanProgress`, `Artist`, `Album`, `Track` FFI-friendly (plain fields — they are).

- [ ] **Step 2: Regenerate** `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`.

- [ ] **Step 3: Dart integration test** `integration_test/catalog_ffi_test.dart`: copy two fixtures into a temp dir (use `dart:io` `Directory.systemTemp`), open a temp db path, `await for` over `scanLibrary(...)` until `done`, then assert `listArtists(...)` returns 1 artist and `listTracks(...)` returns the album's tracks across the bridge. Run headless: `xvfb-run -a mise exec -- flutter test integration_test/catalog_ffi_test.dart -d linux`.

- [ ] **Step 4: Add it to CI** — extend the `flutter` job's integration step to run the whole dir: `xvfb-run -a mise exec -- flutter test integration_test/ -d linux`.

- [ ] **Step 5: Format + lint + commit** (`feat(ffi): catalog scan stream + browse queries + record_play`).

---

## Task 8: Riverpod + 3-column Miller browser (Flutter)

**Files:** Modify `pubspec.yaml`, `lib/main.dart`; Create `lib/state/providers.dart`, `lib/catalog/browser_page.dart`, `lib/catalog/{artist,album,track}_column.dart`.

- [ ] **Step 1: Deps** — add `flutter_riverpod: ^3.3.2`, `multi_split_view: ^3.6.2`, `rxdart: ^0.28.0`; `flutter pub get`. Wrap the app in `ProviderScope` in `main.dart`.

- [ ] **Step 2: Providers** (`lib/state/providers.dart`): a `dbPathProvider` (the existing `dbPath`), `selectedArtistProvider` / `selectedAlbumProvider` (`NotifierProvider<...,String?>`), and `FutureProvider`s `artistsProvider` (calls `listArtists(dbPath: ..., after: null, limit: 500)` — paging can come later; 500 covers a few hundred album-artists), `albumsProvider` (watches `selectedArtistProvider`, calls `listAlbums`), `tracksProvider` (watches `selectedAlbumProvider`, calls `listTracks`). Each returns the generated DTO lists.

- [ ] **Step 3: Browser page** (`lib/catalog/browser_page.dart`): build a `MultiSplitViewController(areas: [Area(min: 160, builder: (ctx, a) => const ArtistColumn()), Area(min: 160, builder: (ctx, a) => const AlbumColumn()), Area(min: 240, builder: (ctx, a) => const TrackColumn())])` and pass it to `MultiSplitView(controller: controller)`. (In multi_split_view 3.x, `Area` content is supplied via `builder:`, not a `widget:` field.) The page is the app home.

- [ ] **Step 4: Column widgets.** Each is a `ConsumerWidget` watching its provider and rendering a `ListView.builder` with `itemExtent: 48`, `cacheExtent: 600`, `ValueKey`. Selecting a row sets the corresponding selection provider (artist→album→track). Rows render the single display title now; wrap the label in a small `RowLabel` widget so Phase 2 can add a second line. Tracks column also shows track number + length; clicking a track (or an album's "play" affordance) calls into the playback controller (Task 9).

- [ ] **Step 5: Verify (widget + manual).** Add a widget test for a column rendering a fake provider list (pump with `ProviderScope(overrides: [...])`). Manual: `xvfb`/run shows the three columns; selecting an artist populates albums, etc. Build-verify `flutter build linux --debug`.

- [ ] **Step 6: Format + lint + commit** (`feat(ui): riverpod state + 3-column Miller browser`).

---

## Task 9: Real queue playback + now-playing bar (Flutter)

**Files:** Create `lib/audio/playback_controller.dart`, `lib/widgets/now_playing_bar.dart`; Modify `lib/catalog/*` (play affordances), `lib/main.dart`.

- [ ] **Step 1: Playback controller** (`lib/audio/playback_controller.dart`): given a `release_mbid`, fetch `albumFilePaths(...)` + `listTracks(...)`, build the `List<MediaItem>` (Task 10) and the `QueueController.setQueue(paths)`, set the audio_service queue, and `audioHandler.play()`. Expose `playAlbum(releaseMbid)` and `playTrack(releaseMbid, index)` (sets the queue, then `player.seek(Duration.zero, index: index)` to start the chosen track at 0). Reuse the existing `QueueController` (it already does app-side shuffle + persistence).

- [ ] **Step 2: Now-playing bar** (`lib/widgets/now_playing_bar.dart`): a bottom bar bound to `audioHandler.player` streams. Combine position/buffered/duration with rxdart:
```dart
final _posData = Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
  player.positionStream, player.bufferedPositionStream, player.durationStream,
  (p, b, d) => PositionData(p, b, d ?? Duration.zero));
```
`StreamBuilder`s drive: play/pause (from `playerStateStream`), a seek slider (`PositionData` → `player.seek`), prev/next (`seekToPrevious`/`seekToNext`), and the current track title/artist (from `currentIndexStream` → the queue's `MediaItem`). Place it as the `Scaffold.bottomNavigationBar` (or a bottom-anchored bar) under the browser.

- [ ] **Step 3: Play tracking.** Subscribe to `player.positionStream`/`playerStateStream`; when a track passes the threshold (first of: completed, ≥50%, or 4:00), call `recordPlay(dbPath:, trackId:, playedAt:)` once per play. Get the current `track_id` from the active queue item's `MediaItem.extras['trackId']` (via `player.currentIndexStream` → `audioHandler.queue.value[index]`), set in Task 10.

- [ ] **Step 4: Verify (manual).** Build-verify; manual: select album → play → bar shows track + advances; seek/next/prev work. (Audible check is the human's.)

- [ ] **Step 5: Format + lint + commit** (`feat(audio): real album/track playback + now-playing bar`).

---

## Task 10: MediaItem metadata + MPRIS cover art (Flutter)

**Files:** Modify `lib/audio/audio_handler.dart`, `lib/audio/playback_controller.dart`; possibly a Rust helper to extract cover art to a temp file.

- [ ] **Step 1: Build `MediaItem`s** from `listTracks` + `albumFilePaths` (same track order). **`MediaItem.id` is a `String` and must be the file path** (matching the `AudioSource.file(path)` entries the queue is built from); carry the catalog id in `extras`:
```dart
MediaItem(
  id: path,
  title: track.title,
  artist: track.artist,
  album: albumTitle,
  duration: track.lengthMs == null ? null : Duration(milliseconds: track.lengthMs!.toInt()),
  extras: {'trackId': track.id},
)
```
Set the audio_service queue (`queue.add(items)`) and, on `player.currentIndexStream`, `mediaItem.add(items[i])` so MPRIS/notification show the current track. (Task 9's play-tracking reads `extras['trackId']` for `record_play`.)

- [ ] **Step 2: Cover art via `file://`.** MPRIS reads a URL, not bytes. Add a Rust FFI `extract_cover(file_path) -> Option<String>` that writes the embedded picture (via `lofty` `Tag::pictures()`) to a cache file (e.g. `<cache>/olivier/cover-<hash>.jpg`) and returns its path; set `MediaItem.artUri = Uri.file(coverPath)`. (If no embedded art, leave `artUri` null.) Regenerate bindings.

- [ ] **Step 3: Verify (manual).** Build-verify; manual on Linux: `playerctl metadata` shows title/artist/album and `mpris:artUrl`; the GNOME/KDE media widget shows the cover.

- [ ] **Step 4: Format + lint + commit** (`feat(audio): MediaItem metadata + MPRIS cover art`).

---

## Task 11: Settings — root folders + scan with progress (Flutter)

**Files:** Create `lib/settings/settings_page.dart`; a Rust settings store (or reuse a simple `setting` table); Modify providers.

- [ ] **Step 1: Settings store.** Add a `setting(key TEXT PRIMARY KEY, value TEXT)` migration (append-only) + FFI `get_setting/set_setting`. Store `root_folders` as a newline-joined string. (Keep minimal.)

- [ ] **Step 2: Settings page.** Add/remove root folders (use `file_picker` directory mode — add `file_picker: ^8` — or a simple text field). Add/remove **persists via `set_setting`** (single source of truth). A "Scan now" button **reads the persisted `root_folders` via `get_setting`** and passes that list to `scanLibrary(dbPath:, roots:)`, showing a progress indicator bound to the `Stream<ScanProgress>` (`files_seen`/`files_changed`/`current`) and refreshing the artist list on `done`.

- [ ] **Step 3: Verify (manual).** Point it at a real music folder, scan, watch progress, then browse the populated catalog.

- [ ] **Step 4: Format + lint + commit** (`feat(ui): settings — root folders + scan with progress`).

---

## Task 12: Retire the spike UI; wire end-to-end (Flutter)

**Files:** Modify `lib/main.dart` (remove the Play/Queue/Shuffle spike buttons + fixture paths); ensure the home is the browser + now-playing bar; settings reachable from an app bar action.

- [ ] **Step 1: Remove** the Task-9/10/12 spike buttons and `_fixtureDir`/`_fixtureQueue` from `main.dart`; the home becomes `BrowserPage` (Task 8) + `NowPlayingBar` (Task 9), with a Settings action in the `AppBar`. Keep `RustLib.init`, `JustAudioMediaKit.ensureInitialized`, `AudioService.init`, MPRIS init, and the queue hydration (`loadQueue`) on startup.
- [ ] **Step 2: Verify.** Build-verify; `precious lint --all` green; the existing integration tests still pass. Manual: full flow (scan → browse → play → now-playing → MPRIS).
- [ ] **Step 3: Commit** (`refactor(ui): replace Phase-0 spike UI with the real browse+play app`).

---

## Task 13: Manual verification + Phase 1 results doc

- [ ] **Step 1:** Create `docs/superpowers/spikes/phase1-results.md` (mirroring phase0-results): record automated outcomes (schema/scan/query/sort/play tests, FFI integration test in CI) and a human checklist (scan a real library; browse artists→albums→tracks correct + grouped by album artist + sorted; play an album; seek/next/prev; now-playing bar; MPRIS metadata + cover; play tracking updates last-played).
- [ ] **Step 2:** Commit (`docs: record Phase 1 outcomes`).

---

## Done criteria for Phase 1

- `cd rust && cargo test` green (schema, sort, scan+incremental, queries, play stats, plus the Phase-0 suites).
- `mise exec -- precious lint --all` green; CI runs it + `flutter test integration_test/ -d linux` (catalog + tags FFI).
- Scanning a real folder populates the catalog; the 3-column browser shows Artists → Albums → Tracks grouped by **album artist**, albums ordered by original year, tracks by disc/position, artists by sort name.
- Selecting an album/track plays it; the now-playing bar reflects state and seeks; next/prev work; MPRIS shows title/artist/album + cover.
- Play tracking updates `last_played`/`play_count`.
- No MusicBrainz enrichment yet (single-language display) — that's Phase 2.
