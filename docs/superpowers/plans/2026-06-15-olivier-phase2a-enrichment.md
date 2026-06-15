# Phase 2a — MusicBrainz Enrichment Backend Implementation Plan

> For agentic workers: This is a **backend-only**, **TDD** plan. Work top to bottom. Every task is a self-contained loop: write a failing test, run it and watch it fail, write the minimum code to pass, run it and watch it pass, then commit. Do **not** batch tasks. All paths are relative to the repo root `/home/autarch/projects/olivier`. Rust crate name is `rust_lib_olivier`; the crate lives in `rust/`. Run Rust tests with `cd rust && cargo test`. Run lint with `mise exec -- precious lint --all`. Regenerate the FFI bridge with `mise exec -- flutter_rust_bridge_codegen generate` **from the repo root** after any change to a bridged function signature or any struct reachable from `crate::api`. This is **Phase 2a**; Phase 2b (bilingual display queries, layout-A/B toggle UI, FTS bilingual search) is planned separately once 2a lands and leaves the data ready for it.

## Open questions / decisions I made

1. **Artist transliteration storage: new `artist.transliteration` column, NOT the spec's `artist_alias` table.** The §5.1 selection algorithm picks exactly **one** alias for both display and sort. Storing the whole alias set buys nothing in 2a (no UI consumes alternates) and would mean re-running the selection at query time. I add two columns to `artist`: `transliteration TEXT` (the chosen alias `name`, e.g. "Ringo Sheena" — used by 2b's display) and I **overwrite `sort_name`** with the chosen alias `sort-name` (e.g. "Sheena, Ringo") per §6.1 sort-key priority tier 1. This keeps the existing `idx_artist_sort` index and `artists_page` query working unchanged. The spec note that `artist_alias` is where the transliteration "is derived from" is satisfied — we derive it during enrichment and persist the single result. (A full `artist_alias` table can be added in a later phase if a manual-override UI ever needs the alternates; YAGNI for now.)

2. **`reqwest` testability: inject the HTTP layer behind a trait.** I define a small `MbHttp` trait (`async fn get(&self, url: &str) -> Result<MbResponse>`) with a real `ReqwestHttp` impl and a `FakeHttp` test impl that serves recorded JSON fixtures keyed by URL. The enrichment logic, rate limiter, and cache read-through are written against the trait, so **tests never touch the network and never sleep for the rate limit** (the fake reports zero elapsed). This is the cleanest seam and mirrors how the catalog code already isolates I/O.

3. **Auto-trigger wiring: the enrich FFI fn is a separate streaming call the Dart scan-completion path invokes; Rust does NOT chain it inside `scan_roots`.** `scan_roots` already streams `ScanProgress` and ends with `done: true`. Coupling enrichment into it would block the scan stream, mix two progress shapes, and break the "manual re-enrich" path. Instead I add `enrich_library(db_path, sink)` as its own streaming FFI fn (mirroring `scan_library`). Phase 2b/Dart calls it after a scan's `done` event for automatic enrichment, and the Settings "Re-enrich all" action calls the same fn with a `force` flag. This plan delivers the Rust fn + its resumability; the Dart auto-call is a one-line wiring noted in the done criteria (it is trivially a `ref` call and does not need its own Rust work).

4. **Re-enrich semantics: "Re-enrich all" re-reads from cache by default; a separate "Refresh from MusicBrainz" clears the cache.** Two distinct operations. `enrich_library(force=false)` skips already-`enriched` files and cached entities — this is the resumable auto path. `enrich_library(force=true)` ("Re-enrich all" in Settings) re-runs the enrichment **logic** over every file (re-deriving transliterations/alts/dates) but still reads entity JSON **from the cache** — fast, no network, useful after a logic change. A separate `clear_mb_cache()` FFI fn empties `mb_cache` so the next enrich refetches from the network (the spec's "manual refresh only"). This separation means a logic fix doesn't force thousands of network calls.

5. **Resumability granularity is per-file `enriched` flag + per-entity cache.** A file is marked `enriched = 1` only after its release, pseudo-releases, and album-artist have all been processed and its alts/dates/sort persisted. An interrupted run resumes by skipping `enriched = 1` files. Entity fetches dedupe through `mb_cache`, so re-touching an album whose release JSON is cached costs no network.

6. **Cancellation: cooperative via the StreamSink.** `sink.add(...)` returns an error once the Dart side drops the stream; the enrichment loop checks that result and returns early (exactly the `let _ = sink.add(p)` pattern the scanner uses, but we inspect the result). No separate cancel token needed for 2a.

7. **`track_title_alt` keyed by recording MBID, `release_title_alt` by release MBID** — per §4, so a translation carries to every owned release of the same recording. The pseudo-release join is by recording MBID (§5.1 step 2), matching `media[].tracks[].recording.id` against our tracks.

---

## Goal

Add a rate-limited, cached MusicBrainz client and a resumable, progress-streaming enrichment pipeline (plus a `setting` store) to the Rust core that populates artist transliterations/sort keys, release/track title alternates, and original/reissue dates from MusicBrainz, leaving the catalog ready for Phase 2b bilingual display.

## Architecture

Enrichment is a new Rust subsystem (`rust/src/enrich/`) that walks un-enriched files, dedupes them to unique album-artists and releases, and fetches MusicBrainz JSON through an injectable `MbHttp` trait wrapped by a 1 req/s rate limiter with 503 backoff and a `mb_cache` read-through. Pure selection/parse functions (alias selection per §5.1, pseudo-release discovery via the `transl-tracklisting` rel, title-alt extraction) are tested against recorded JSON fixtures with no network. The FFI surface gains a streaming `enrich_library` command (mirroring `scan_library`'s `StreamSink<ScanProgress>` pattern), a cache-clear command, and generic `get_setting`/`set_setting` accessors over a new `setting` table.

**Sync FFI + `block_on` seam (critical architecture decision).** The `enrich_library` FFI entry point is a **synchronous** `fn`, dispatched on frb's normal worker-thread path exactly like the existing `scan_library` (verified: `rust/src/api/catalog.rs` has **zero** async fns today, and the existing streaming pattern is sync). It must **not** be an `async fn`: frb 2.12's async executor requires the returned `Future` to be `Send + 'static`, but this design intentionally uses **non-`Send`** types held across `.await` — a `rusqlite::Connection`, the `RefCell`-based `WallClockPacer`, and `#[async_trait(?Send)]` traits — so an `async fn` entry point would not compile on that executor. Instead, the sync `enrich_library` fn builds a **private current-thread tokio runtime** (`tokio::runtime::Builder::new_current_thread().enable_time().build()?`) and `block_on(run::enrich(...))`. The internal client/pacer/run code stays `async` + `?Send`; it is driven entirely by `block_on` on a single thread, never crossing an executor boundary, so `Connection`/`RefCell`/`?Send` remain valid throughout. (The pacer's `tokio::time::sleep` is why the runtime needs `enable_time()`/the `time` feature; the `rt` feature provides the current-thread runtime itself — see Task 1.)

## Tech Stack

- **Rust** (crate `rust_lib_olivier`, edition 2021): `rusqlite` 0.40 (bundled SQLite, FKs enforced), `rusqlite_migration` 2.6 (append-only `MIGRATION_SLICE`), `reqwest` (new, async, `rustls-tls` + `json`), `serde`/`serde_json` (new, JSON parsing), `tokio` (new dep with `rt`+`time` features — the transitive frb copy does **not** enable these; the internal async enrichment is driven by a private current-thread runtime via `block_on`, not by frb's executor), `async-trait` (new, for the `?Send` HTTP/pacer traits), `anyhow`.
- **flutter_rust_bridge** 2.12.0: streaming via `StreamSink`. Bridged fns here are **synchronous** (dispatched on frb's worker-thread path, like the existing `scan_library`); the enrichment fn builds its own current-thread tokio runtime and `block_on`s the async core. frb's async-fn path is **not** used (its executor requires `Send + 'static`, incompatible with the non-`Send` `Connection`/`RefCell`/`?Send` design). Codegen config `flutter_rust_bridge.yaml` (`rust_input: crate::api`).
- **Testing**: `cargo test` integration tests in `rust/tests/`, recorded MusicBrainz JSON fixtures under `rust/tests/fixtures/mb/`, `tempfile` for temp DBs, `:memory:` SQLite. New dev-dep: none required (fake HTTP is hand-rolled).
- **Lint/tidy**: `precious` (clippy `-D warnings`, rustfmt, prettier, taplo) via `mise exec -- precious lint --all`.

---

## File structure

### New files

| Path | Responsibility |
|---|---|
| `rust/src/enrich/mod.rs` | Module declarations for the enrich subsystem. |
| `rust/src/enrich/http.rs` | `MbHttp` trait, `MbResponse` (status + body), real `ReqwestHttp` impl (User-Agent, `fmt=json`), and the test-only `FakeHttp` is in the test crate — see note. |
| `rust/src/enrich/client.rs` | `MbClient<H: MbHttp>`: rate limiter (≥1.05 s spacing), 503 exponential backoff, `mb_cache` read-through keyed by `(entity_type, mbid, inc_set)`; typed fetch helpers (`fetch_release`, `fetch_artist`). |
| `rust/src/enrich/model.rs` | `serde` structs for the MB JSON shapes we read (release w/ recordings + relations + release-group + artist-credit; artist w/ aliases; release-group browse list). Only the fields §5.1 needs. |
| `rust/src/enrich/select.rs` | Pure functions: `select_transliteration(&[Alias]) -> Option<ChosenAlias>` (§5.1 algorithm), `find_pseudo_release_targets(&Release) -> Vec<PseudoLink>` (`transl-tracklisting` `fc399d47-…`), `classify_pseudo(original_title, &Release) -> AltKind` (translit vs translate, from `text-representation` script/language with a title-pair fallback). |
| `rust/src/enrich/store.rs` | DB writes: upsert `release_title_alt`, `track_title_alt`, set `release.date`/`release_group.first_release_date`, set `artist.transliteration`/`artist.sort_name`, flip `file.enriched`. |
| `rust/src/enrich/run.rs` | Orchestration: `enrich(conn, client, force, on_progress)` — selects work, dedupes to unique entities, drives the per-album algorithm (§5.1), streams `EnrichProgress`, resumable. |
| `rust/src/enrich/progress.rs` | `EnrichProgress` struct (bridged DTO). |
| `rust/src/settings.rs` | `get_setting` / `set_setting` / `get_setting_or_default`, the defaults table (keys from the spec). |
| `rust/src/api/enrich.rs` | FFI: `enrich_library(db_path, force, sink)`, `clear_mb_cache(db_path)`. |
| `rust/src/api/settings.rs` | FFI: `get_setting(db_path, key)`, `set_setting(db_path, key, value)`. |
| `rust/tests/fixtures/mb/*.json` | Recorded MusicBrainz JSON (Shiina Ringo artist `9e414497-…` w/ aliases; 無罪モラトリアム release w/ recordings+release-rels+release-group; the translit + translate pseudo-releases). |
| `rust/tests/enrich_test.rs` | Integration tests for selection, pseudo-release discovery, client cache/rate-limit/backoff, store writes, and the end-to-end orchestration against `FakeHttp`. |
| `rust/tests/settings_test.rs` | Tests for the `setting` table + get/set + defaults. |

### Modified files

| Path | Change |
|---|---|
| `rust/Cargo.toml` | Add `reqwest`, `serde`, `serde_json`, `tokio` (`rt`+`time`), `async-trait` deps. |
| `rust/src/db.rs` | Append migrations: `setting`, `mb_cache`, `release_title_alt`, `track_title_alt`, `artist.transliteration` + `artist.sort_name_embedded` columns. **Append-only** — never edit existing `M::up` entries. |
| `rust/src/lib.rs` | `pub mod enrich;`, `pub mod settings;`. |
| `rust/src/api/mod.rs` | `pub mod enrich;`, `pub mod settings;`. |
| `rust/src/frb_generated.rs` | Regenerated by codegen (do not hand-edit). |
| `lib/src/rust/**` | Regenerated Dart bindings (do not hand-edit). |

---

## Tasks

### Task 1: Add dependencies (reqwest, serde, serde_json)

**Files:**
- Modify: `rust/Cargo.toml`

**Steps:**

- [ ] Add the new dependencies to `rust/Cargo.toml`'s `[dependencies]` table. Use `rustls-tls` to avoid an OpenSSL system dependency (matters for the eventual Flatpak/Android builds), and disable reqwest default features to keep the link surface small. **`tokio` and `async-trait` MUST be added to `[dependencies]`, not just dev-deps**: `tokio` because the library's `WallClockPacer` calls `tokio::time::sleep` and the FFI fn (Task 14) builds a current-thread tokio runtime to `block_on` the async enrichment — both need the `rt` and `time` features, which frb's transitive `tokio` does **not** enable; and `async-trait` because the `MbHttp` and `Pacer` traits use it and it is **not** in the lockfile at all. (Only the `tokio` *crate* is present transitively via frb — not the `rt`/`time` features; `async-trait` is absent entirely. Do not assume either is "already available.")
  ```toml
  reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
  serde = { version = "1", features = ["derive"] }
  serde_json = "1"
  tokio = { version = "1", features = ["rt", "time"] }
  async-trait = "0.1"
  ```
- [ ] Run `cd rust && cargo build` and confirm it compiles and resolves (downloads reqwest/hyper/rustls + async-trait). Expected: `Finished` with no errors. This also updates `Cargo.lock`.
- [ ] Run `mise exec -- precious lint --all` (taplo will reformat the TOML if needed; run `mise exec -- precious tidy rust/Cargo.toml` if taplo flags formatting). Expected: green.
- [ ] Commit: `git commit -am "build(rust): add reqwest, serde, serde_json for MB enrichment"`.

---

### Task 2: Migrations — `setting`, `mb_cache`, title-alt tables, `artist.transliteration`

These are **append-only** additions to `MIGRATION_SLICE` in `rust/src/db.rs`. Never modify the four existing entries; add new `M::up(...)` entries at the end of the slice.

**Files:**
- Modify: `rust/src/db.rs`
- Test: `rust/tests/enrich_test.rs` (new), `rust/tests/settings_test.rs` (new)

**Steps:**

- [ ] Write a failing test in a new file `rust/tests/enrich_test.rs` asserting the new tables and column exist:
  ```rust
  use rust_lib_olivier::db::open;

  #[test]
  fn migration_creates_enrichment_tables() {
      let conn = open(":memory:").unwrap();
      let n: i64 = conn
          .query_row(
              "SELECT count(*) FROM sqlite_master WHERE type='table'
               AND name IN ('setting','mb_cache','release_title_alt','track_title_alt')",
              [],
              |r| r.get(0),
          )
          .unwrap();
      assert_eq!(n, 4);

      // artist.transliteration + artist.sort_name_embedded columns added.
      let cols: i64 = conn
          .query_row(
              "SELECT count(*) FROM pragma_table_info('artist')
               WHERE name IN ('transliteration','sort_name_embedded')",
              [],
              |r| r.get(0),
          )
          .unwrap();
      assert_eq!(cols, 2);
  }
  ```
- [ ] Run `cd rust && cargo test --test enrich_test migration_creates_enrichment_tables`. Expected: **fails** (tables/column don't exist; query returns 0 or `count` mismatch).
- [ ] Append new migrations to the end of `MIGRATION_SLICE` in `rust/src/db.rs` (after the `root` table entry). Note: `mb_cache` PK is the composite `(entity_type, mbid, inc_set)` per §4's "one canonical inc_set per entity type"; `release_title_alt`/`track_title_alt` use the spec's `(fk, kind)` grain with `kind` constrained to the two enum values:
  ```rust
      // ── Phase 2a: enrichment ────────────────────────────────────────────
      M::up(
          "CREATE TABLE setting (
              key   TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL
           );
           CREATE TABLE mb_cache (
              entity_type TEXT NOT NULL,
              mbid        TEXT NOT NULL,
              inc_set     TEXT NOT NULL,
              json        TEXT NOT NULL,
              fetched_at  INTEGER NOT NULL,
              PRIMARY KEY (entity_type, mbid, inc_set)
           );
           CREATE TABLE release_title_alt (
              release_mbid TEXT NOT NULL REFERENCES release(mbid),
              kind         TEXT NOT NULL CHECK (kind IN ('translit','translate')),
              title        TEXT NOT NULL,
              PRIMARY KEY (release_mbid, kind)
           );
           CREATE TABLE track_title_alt (
              recording_mbid TEXT NOT NULL,
              kind           TEXT NOT NULL CHECK (kind IN ('translit','translate')),
              title          TEXT NOT NULL,
              PRIMARY KEY (recording_mbid, kind)
           );
           ALTER TABLE artist ADD COLUMN transliteration TEXT;
           ALTER TABLE artist ADD COLUMN sort_name_embedded TEXT;",
      ),
  ```
  Note: `track_title_alt.recording_mbid` is intentionally **not** a FK — `track.recording_mbid` is nullable/non-unique and there's no `recording` table; the join is by value (§4).
  Note: `artist.sort_name_embedded` preserves the pre-enrichment `sort_name` (the embedded `albumartistsort` tag, §6.1 tier 3 fallback) before enrichment overwrites `sort_name` with the MB alias sort-name, so a future manual-override UI (2b/post-v1) can recover the embedded value. It is populated by Task 11 (only on first enrichment, when still NULL).
- [ ] Run `cd rust && cargo test --test enrich_test migration_creates_enrichment_tables`. Expected: **passes**.
- [ ] Run `cargo test` (full suite) to confirm no existing migration test broke (e.g. `migration_creates_catalog_tables` still passes — we only appended). Expected: all green.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(db): add enrichment + settings migrations (append-only)"`.

---

### Task 3: `setting` store — get/set/defaults

**Files:**
- Create: `rust/src/settings.rs`
- Modify: `rust/src/lib.rs`
- Test: `rust/tests/settings_test.rs`

**Steps:**

- [ ] Write a failing test `rust/tests/settings_test.rs`:
  ```rust
  use rust_lib_olivier::db::open;
  use rust_lib_olivier::settings::{get_setting, get_setting_or_default, set_setting};

  #[test]
  fn unset_key_returns_none_then_default() {
      let conn = open(":memory:").unwrap();
      assert_eq!(get_setting(&conn, "language_leads").unwrap(), None);
      // Known key falls back to its spec default.
      assert_eq!(
          get_setting_or_default(&conn, "language_leads").unwrap(),
          "A"
      );
      assert_eq!(
          get_setting_or_default(&conn, "mb_contact_email").unwrap(),
          "autarch@urth.org"
      );
      assert_eq!(
          get_setting_or_default(&conn, "play_threshold_percent").unwrap(),
          "50"
      );
      assert_eq!(
          get_setting_or_default(&conn, "play_threshold_seconds").unwrap(),
          "240"
      );
  }

  #[test]
  fn set_then_get_roundtrips_and_overwrites() {
      let conn = open(":memory:").unwrap();
      set_setting(&conn, "language_leads", "B").unwrap();
      assert_eq!(
          get_setting(&conn, "language_leads").unwrap(),
          Some("B".to_string())
      );
      // get_setting_or_default returns the stored value, not the default.
      assert_eq!(get_setting_or_default(&conn, "language_leads").unwrap(), "B");
      set_setting(&conn, "language_leads", "A").unwrap();
      assert_eq!(
          get_setting(&conn, "language_leads").unwrap(),
          Some("A".to_string())
      );
  }

  #[test]
  fn unknown_key_has_no_default() {
      let conn = open(":memory:").unwrap();
      // get_setting_or_default on an unknown key errors (caller bug), not silently "".
      assert!(get_setting_or_default(&conn, "nope").is_err());
  }
  ```
- [ ] Run `cd rust && cargo test --test settings_test`. Expected: **fails to compile** (`rust_lib_olivier::settings` does not exist).
- [ ] Create `rust/src/settings.rs`:
  ```rust
  use rusqlite::{Connection, OptionalExtension};

  /// Spec §4 setting keys and their defaults. `root_folders` lives in the
  /// dedicated `root` table (Phase 1), so it is intentionally absent here.
  const DEFAULTS: &[(&str, &str)] = &[
      ("language_leads", "A"),
      ("mb_contact_email", "autarch@urth.org"),
      ("play_threshold_percent", "50"),
      ("play_threshold_seconds", "240"),
  ];

  /// Read a raw setting; `None` if never written.
  pub fn get_setting(conn: &Connection, key: &str) -> anyhow::Result<Option<String>> {
      let v = conn
          .query_row(
              "SELECT value FROM setting WHERE key = ?1",
              [key],
              |r| r.get::<_, String>(0),
          )
          .optional()?;
      Ok(v)
  }

  /// Read a setting, falling back to the spec default for a known key.
  /// Errors if `key` is neither stored nor a known default — that's a caller bug.
  pub fn get_setting_or_default(conn: &Connection, key: &str) -> anyhow::Result<String> {
      if let Some(v) = get_setting(conn, key)? {
          return Ok(v);
      }
      DEFAULTS
          .iter()
          .find(|(k, _)| *k == key)
          .map(|(_, v)| v.to_string())
          .ok_or_else(|| anyhow::anyhow!("unknown setting key with no default: {key}"))
  }

  /// Write (upsert) a setting.
  pub fn set_setting(conn: &Connection, key: &str, value: &str) -> anyhow::Result<()> {
      conn.execute(
          "INSERT INTO setting(key, value) VALUES (?1, ?2)
           ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          rusqlite::params![key, value],
      )?;
      Ok(())
  }
  ```
- [ ] Add `pub mod settings;` to `rust/src/lib.rs` (alongside the existing `pub mod` lines).
- [ ] Run `cd rust && cargo test --test settings_test`. Expected: **3 tests pass**.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(settings): setting table get/set with spec defaults"`.

---

### Task 4: Settings FFI surface

**Files:**
- Create: `rust/src/api/settings.rs`
- Modify: `rust/src/api/mod.rs`
- Regenerate: `rust/src/frb_generated.rs`, `lib/src/rust/**`

**Steps:**

- [ ] Create `rust/src/api/settings.rs` following the per-call `db::open` pattern used throughout `rust/src/api/catalog.rs`:
  ```rust
  use crate::db;
  use crate::settings;

  pub fn get_setting(db_path: String, key: String) -> anyhow::Result<Option<String>> {
      settings::get_setting(&db::open(&db_path)?, &key)
  }

  pub fn set_setting(db_path: String, key: String, value: String) -> anyhow::Result<()> {
      settings::set_setting(&db::open(&db_path)?, &key, &value)
  }
  ```
- [ ] Add `pub mod settings;` to `rust/src/api/mod.rs`.
- [ ] Run `cd rust && cargo build`. Expected: compiles.
- [ ] Regenerate the bridge from the repo root: `mise exec -- flutter_rust_bridge_codegen generate`. Expected: updates `rust/src/frb_generated.rs` and `lib/src/rust/api/settings.dart` (new). 
- [ ] Run `cd rust && cargo build` again to confirm the regenerated glue compiles.
- [ ] Run `mise exec -- precious lint --all`. Expected: green (generated files are excluded from lint per `precious.toml`).
- [ ] Commit: `git commit -am "feat(ffi): get_setting/set_setting bridge"`.

---

### Task 5: Recorded MusicBrainz JSON fixtures

Capture the real JSON the spec §8 names. These fixtures drive every enrichment test with **no network**. Capture by hand from the live API (the worker may run `curl` read-only — this is allowed; it does not modify the repo) and save the bodies under `rust/tests/fixtures/mb/`. If the network is unavailable, hand-construct minimal-but-faithful JSON matching the shapes in `model.rs` (Task 7) — the fixtures only need the fields we read.

**Files:**
- Create: `rust/tests/fixtures/mb/artist_9e414497_aliases.json`
- Create: `rust/tests/fixtures/mb/release_muzai.json`
- Create: `rust/tests/fixtures/mb/release_muzai_translit.json`
- Create: `rust/tests/fixtures/mb/release_muzai_translate.json`
- Create: `rust/tests/fixtures/mb/release_group_browse_muzai.json` (for the fallback path)

**Steps:**

- [ ] Capture the artist with aliases (Shiina Ringo, `9e414497-…`). The real MBID is `9e414497-1f44-4f0c-b031-f01923a3c5d2`. Read-only capture:
  ```
  curl -s -H 'User-Agent: Olivier/0.1.0 ( autarch@urth.org )' \
    'https://musicbrainz.org/ws/2/artist/9e414497-1f44-4f0c-b031-f01923a3c5d2?inc=aliases&fmt=json'
  ```
  Save the body to `rust/tests/fixtures/mb/artist_9e414497_aliases.json`. Verify it contains an `aliases` array with at least one `{ "type": "Artist name", "locale": "en", "primary": true, "name": "Ringo Sheena", "sort-name": "Sheena, Ringo" }`-shaped entry (the exact values are what the §5.1 test asserts; record what MB actually returns and write the test to match).
- [ ] Capture the release 無罪モラトリアム with the full inc-bundle (find its release MBID via `curl '.../ws/2/release-group?query=...'` or the MB website; record the actual MBID in a comment at the top of the test). Capture:
  ```
  curl -s -H 'User-Agent: Olivier/0.1.0 ( autarch@urth.org )' \
    'https://musicbrainz.org/ws/2/release/<release-mbid>?inc=recordings+release-rels+release-groups+artist-credits&fmt=json'
  ```
  Save to `rust/tests/fixtures/mb/release_muzai.json`. Confirm it includes: `media[].tracks[].recording.id`, a `release-group` object with `first-release-date`, a top-level `date`, and a `relations` array containing a `transl-tracklisting` relation (`type-id` `fc399d47-23a7-4c28-bfcf-0607a562b644`) whose `release.id` is a pseudo-release MBID. (If this specific release has no pseudo-release rel, capture one that does — e.g. a release in the same group — and update the fallback-browse fixture accordingly so both code paths have data.)
- [ ] Capture each pseudo-release target (`inc=recordings`), saving the romaji one to `release_muzai_translit.json` and the English one to `release_muzai_translate.json`. Each must have its own `title` (the album alt) and `media[].tracks[]` with `recording.id` + `title` (the track alts). **Also confirm each pseudo-release fixture carries a `text-representation` object** (`{ "script": ..., "language": ... }`) — Task 9 classifies translit-vs-translate from it (romaji ⇒ `script:"Latn"`; the English one ⇒ `language:"eng"`). If MB omits `text-representation` on a pseudo-release, note it in the fixture-MBID comment block (below) so the Task 9 fallback test is the one exercised for that release.
- [ ] Capture the release-group browse fallback (page of releases with `release-rels`) to `release_group_browse_muzai.json`:
  ```
  curl -s -H 'User-Agent: Olivier/0.1.0 ( autarch@urth.org )' \
    'https://musicbrainz.org/ws/2/release?release-group=<rg-mbid>&inc=release-rels&limit=100&fmt=json'
  ```
- [ ] **Record the captured MBIDs and the exercised discovery path** as a comment block at the very top of `rust/tests/enrich_test.rs`, so the end-to-end test (Task 13) is deterministic about which code path it drives. The block MUST record: the artist MBID, the main release MBID, the release-group MBID, each pseudo-release MBID (translit + translate), and **whether the pseudo-releases were found via the direct `transl-tracklisting` rel on the main release OR via the release-group browse fallback**. Example:
  ```rust
  // ── Recorded MB fixture MBIDs (captured Task 5) ──────────────────────────
  // artist (Shiina Ringo):     9e414497-1f44-4f0c-b031-f01923a3c5d2
  // release (無罪モラトリアム): <rel-mbid>
  // release-group:             <rg-mbid>
  // pseudo translit (romaji):  <pseudo-translit-mbid>  text-representation: script=Latn
  // pseudo translate (en):     <pseudo-translate-mbid> text-representation: language=eng
  // pseudo discovery path:     DIRECT transl-tracklisting rel on the main release
  //                            (NOT the release-group browse fallback)
  // ─────────────────────────────────────────────────────────────────────────
  ```
  If the data instead requires the browse fallback (no direct rel on the main release), record `pseudo discovery path: RELEASE-GROUP BROWSE FALLBACK` and capture `release_group_browse_muzai.json` to contain the rels. Task 13 asserts exactly this recorded path.
- [ ] Confirm the files are present and non-empty: `cd rust && ls -l tests/fixtures/mb/`. (These are committed as test data; they are excluded from prettier/typos via being under `tests/fixtures/`? — note: `precious.toml` excludes `rust/tests/fixtures/**` only for the binary audio fixtures glob `rust/tests/fixtures/**`, which **does** cover `mb/*.json`. Good — no lint churn.)
- [ ] Commit: `git commit -am "test(enrich): record MusicBrainz JSON fixtures (Shiina Ringo, Muzai Moratorium)"`.

---

### Task 6: `MbHttp` trait + `MbResponse` + real reqwest impl

**Files:**
- Create: `rust/src/enrich/mod.rs`, `rust/src/enrich/http.rs`
- Modify: `rust/src/lib.rs`
- Test: `rust/tests/enrich_test.rs`

**Steps:**

- [ ] Add a failing unit-style test to `rust/tests/enrich_test.rs` exercising a hand-rolled `FakeHttp` against the trait (proving the seam; the real reqwest impl is exercised only by manual/integration smoke, never in unit tests):
  ```rust
  use rust_lib_olivier::enrich::http::{MbHttp, MbResponse};

  /// Test double: serves canned bodies by URL, records the calls made.
  struct FakeHttp {
      responses: std::collections::HashMap<String, MbResponse>,
      calls: std::cell::RefCell<Vec<String>>,
  }
  impl FakeHttp {
      fn new() -> Self {
          Self { responses: Default::default(), calls: Default::default() }
      }
      fn with(mut self, url: &str, status: u16, body: &str) -> Self {
          self.responses.insert(url.to_string(), MbResponse { status, body: body.to_string() });
          self
      }
  }
  #[async_trait::async_trait(?Send)]
  impl MbHttp for FakeHttp {
      async fn get(&self, url: &str) -> anyhow::Result<MbResponse> {
          self.calls.borrow_mut().push(url.to_string());
          self.responses
              .get(url)
              .cloned()
              .ok_or_else(|| anyhow::anyhow!("no canned response for {url}"))
      }
  }

  #[tokio::test]
  async fn fake_http_serves_canned_body() {
      let http = FakeHttp::new().with("http://x/a", 200, "{\"ok\":true}");
      let resp = http.get("http://x/a").await.unwrap();
      assert_eq!(resp.status, 200);
      assert_eq!(resp.body, "{\"ok\":true}");
      assert_eq!(http.calls.borrow().as_slice(), ["http://x/a"]);
  }
  ```
  Note: this introduces `async_trait` and a `tokio` test runtime. `tokio` (`rt`+`time`) and `async-trait` were already added to `[dependencies]` in Task 1 (they are needed by the library itself — the pacer's `tokio::time::sleep` and the trait `?Send` definitions). The only thing to add to `[dev-dependencies]` here is the `macros` feature for `#[tokio::test]`: `tokio = { version = "1", features = ["macros"] }` (cargo unifies this with the `rt`+`time` features from `[dependencies]`). Do **not** claim `tokio`/`async-trait` are "already in the lockfile transitively" — frb pulls in the `tokio` crate but **not** the `rt`/`time` features, and `async-trait` is absent entirely; Task 1 is what actually adds them.
- [ ] Run `cd rust && cargo test --test enrich_test fake_http_serves_canned_body`. Expected: **fails to compile** (`enrich::http` missing).
- [ ] Create `rust/src/enrich/mod.rs`:
  ```rust
  pub mod http;
  ```
- [ ] Create `rust/src/enrich/http.rs`:
  ```rust
  /// A single MusicBrainz HTTP response, reduced to what the client needs.
  #[derive(Debug, Clone)]
  pub struct MbResponse {
      pub status: u16,
      pub body: String,
  }

  /// The injectable HTTP seam. Real impl talks to MusicBrainz; tests serve
  /// recorded JSON. `?Send` because the enrichment core is driven by a private
  /// current-thread tokio runtime via `block_on` (see `api/enrich.rs`), so the
  /// future never needs to be `Send`; the test double also holds a non-Send
  /// `RefCell`.
  #[async_trait::async_trait(?Send)]
  pub trait MbHttp {
      async fn get(&self, url: &str) -> anyhow::Result<MbResponse>;
  }

  /// Production HTTP via reqwest with the MusicBrainz-required User-Agent.
  pub struct ReqwestHttp {
      client: reqwest::Client,
      user_agent: String,
  }

  impl ReqwestHttp {
      /// `contact_email` comes from the `mb_contact_email` setting; `version`
      /// from CARGO_PKG_VERSION. User-Agent: `Olivier/<version> ( <email> )`.
      pub fn new(version: &str, contact_email: &str) -> anyhow::Result<Self> {
          let user_agent = format!("Olivier/{version} ( {contact_email} )");
          let client = reqwest::Client::builder()
              .build()
              .map_err(|e| anyhow::anyhow!("build reqwest client: {e}"))?;
          Ok(Self { client, user_agent })
      }
  }

  #[async_trait::async_trait(?Send)]
  impl MbHttp for ReqwestHttp {
      async fn get(&self, url: &str) -> anyhow::Result<MbResponse> {
          let resp = self
              .client
              .get(url)
              .header(reqwest::header::USER_AGENT, &self.user_agent)
              .send()
              .await?;
          let status = resp.status().as_u16();
          let body = resp.text().await?;
          Ok(MbResponse { status, body })
      }
  }
  ```
- [ ] Add `pub mod enrich;` to `rust/src/lib.rs`.
- [ ] Run `cd rust && cargo test --test enrich_test fake_http_serves_canned_body`. Expected: **passes**.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(enrich): MbHttp trait + reqwest impl + test double"`.

---

### Task 7: MB JSON model structs (serde)

**Files:**
- Create: `rust/src/enrich/model.rs`
- Modify: `rust/src/enrich/mod.rs`
- Test: `rust/tests/enrich_test.rs`

**Steps:**

- [ ] Add a failing test that deserializes the recorded fixtures into the model (loads from `rust/tests/fixtures/mb/`):
  ```rust
  use rust_lib_olivier::enrich::model::{Artist, Release};

  fn fixture(name: &str) -> String {
      std::fs::read_to_string(format!(
          "{}/tests/fixtures/mb/{name}",
          env!("CARGO_MANIFEST_DIR")
      ))
      .unwrap()
  }

  #[test]
  fn parses_artist_aliases_fixture() {
      let a: Artist = serde_json::from_str(&fixture("artist_9e414497_aliases.json")).unwrap();
      assert!(!a.aliases.is_empty());
      assert!(a.aliases.iter().any(|al| al.alias_type.as_deref() == Some("Artist name")));
  }

  #[test]
  fn parses_release_fixture_with_recordings_and_rels() {
      let r: Release = serde_json::from_str(&fixture("release_muzai.json")).unwrap();
      // release-group first-release-date is present (original year source).
      assert!(r.release_group.as_ref().and_then(|g| g.first_release_date.as_deref()).is_some());
      // recordings present on media tracks.
      assert!(r.media.iter().flat_map(|m| &m.tracks).any(|t| t.recording.is_some()));
      // at least one relation carrying a target release.
      assert!(r.relations.iter().any(|rel| rel.release.is_some()));
  }
  ```
- [ ] Run `cd rust && cargo test --test enrich_test parses_`. Expected: **fails to compile** (`enrich::model` missing).
- [ ] Create `rust/src/enrich/model.rs` with `serde` structs covering only the fields §5.1 reads. Use `#[serde(rename = "...")]` for the hyphenated MB keys and `#[serde(default)]` so missing arrays deserialize as empty:
  ```rust
  use serde::Deserialize;

  // ── artist?inc=aliases ──────────────────────────────────────────────────
  #[derive(Debug, Deserialize)]
  pub struct Artist {
      pub id: String,
      pub name: String,
      #[serde(rename = "sort-name")]
      pub sort_name: String,
      #[serde(default)]
      pub aliases: Vec<Alias>,
  }

  #[derive(Debug, Deserialize)]
  pub struct Alias {
      pub name: String,
      #[serde(rename = "sort-name")]
      pub sort_name: Option<String>,
      pub locale: Option<String>,
      #[serde(default)]
      pub primary: bool,
      #[serde(rename = "type")]
      pub alias_type: Option<String>,
  }

  // ── release?inc=recordings+release-rels+release-groups+artist-credits ────
  #[derive(Debug, Deserialize)]
  pub struct Release {
      pub id: String,
      pub title: String,
      pub date: Option<String>,
      /// Script/language of THIS (pseudo-)release's titles. Drives translit-vs-
      /// translate classification (Task 9): `script == "Latn"` ⇒ transliteration;
      /// a non-Latn script, or `language == "eng"`, ⇒ translation.
      #[serde(rename = "text-representation")]
      pub text_representation: Option<TextRepresentation>,
      #[serde(rename = "release-group")]
      pub release_group: Option<ReleaseGroup>,
      #[serde(default)]
      pub media: Vec<Medium>,
      #[serde(default)]
      pub relations: Vec<Relation>,
  }

  /// MB `text-representation`: the script the titles are written in and the
  /// language they are in. Both fields are optional in MB's data.
  #[derive(Debug, Deserialize)]
  pub struct TextRepresentation {
      pub script: Option<String>,
      pub language: Option<String>,
  }

  #[derive(Debug, Deserialize)]
  pub struct ReleaseGroup {
      pub id: String,
      #[serde(rename = "first-release-date")]
      pub first_release_date: Option<String>,
  }

  #[derive(Debug, Deserialize)]
  pub struct Medium {
      #[serde(default)]
      pub tracks: Vec<MbTrack>,
  }

  #[derive(Debug, Deserialize)]
  pub struct MbTrack {
      pub title: String,
      pub recording: Option<Recording>,
  }

  #[derive(Debug, Deserialize)]
  pub struct Recording {
      pub id: String,
  }

  #[derive(Debug, Deserialize)]
  pub struct Relation {
      #[serde(rename = "type-id")]
      pub type_id: Option<String>,
      pub release: Option<RelationRelease>,
  }

  #[derive(Debug, Deserialize)]
  pub struct RelationRelease {
      pub id: String,
  }

  // ── release?release-group=<mbid>&inc=release-rels (browse fallback) ──────
  #[derive(Debug, Deserialize)]
  pub struct ReleaseBrowse {
      #[serde(default)]
      pub releases: Vec<Release>,
      #[serde(rename = "release-count", default)]
      pub release_count: u32,
  }
  ```
- [ ] Add `pub mod model;` to `rust/src/enrich/mod.rs`.
- [ ] Run `cd rust && cargo test --test enrich_test parses_`. Expected: **2 tests pass**. (If a field name mismatches the recorded JSON, fix the `rename`/optionality against the real fixture — the fixture is ground truth.)
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(enrich): serde model for MusicBrainz JSON shapes"`.

---

### Task 8: §5.1 artist-alias selection (pure)

**Files:**
- Create: `rust/src/enrich/select.rs`
- Modify: `rust/src/enrich/mod.rs`
- Test: `rust/tests/enrich_test.rs`

**Steps:**

- [ ] Add failing tests covering each §5.1 branch and the tie-break:
  ```rust
  use rust_lib_olivier::enrich::model::{Alias, Artist};
  use rust_lib_olivier::enrich::select::select_transliteration;

  fn alias(name: &str, sort: &str, locale: Option<&str>, primary: bool, ty: &str) -> Alias {
      Alias {
          name: name.into(),
          sort_name: Some(sort.into()),
          locale: locale.map(str::to_string),
          primary,
          alias_type: Some(ty.into()),
      }
  }
  fn artist(sort: &str, aliases: Vec<Alias>) -> Artist {
      Artist { id: "x".into(), name: "椎名林檎".into(), sort_name: sort.into(), aliases }
  }

  #[test]
  fn prefers_en_primary_artist_name() {
      let a = artist("Sheena, Ringo", vec![
          alias("Sheena Ringo", "Sheena, Ringo", Some("en"), false, "Artist name"),
          alias("Ringo Sheena", "Sheena, Ringo", Some("en"), true, "Artist name"),
          alias("椎名林檎", "椎名林檎", Some("ja"), true, "Artist name"),
      ]);
      let chosen = select_transliteration(&a).unwrap();
      assert_eq!(chosen.name, "Ringo Sheena");
      assert_eq!(chosen.sort_name, "Sheena, Ringo");
  }

  #[test]
  fn skips_legal_name_and_search_hint() {
      let a = artist("Sheena, Ringo", vec![
          alias("Yumiko Shiina", "Shiina, Yumiko", Some("en"), true, "Legal name"),
          alias("Ringo", "Ringo", Some("en"), false, "Search hint"),
          alias("Ringo Sheena", "Sheena, Ringo", Some("en"), false, "Artist name"),
      ]);
      assert_eq!(select_transliteration(&a).unwrap().name, "Ringo Sheena");
  }

  #[test]
  fn tie_break_by_name_ascending() {
      // Two en+primary "Artist name" candidates -> name asc picks "Ringo Sheena".
      let a = artist("Sheena, Ringo", vec![
          alias("Sheena Ringo", "Sheena, Ringo", Some("en"), true, "Artist name"),
          alias("Ringo Sheena", "Sheena, Ringo", Some("en"), true, "Artist name"),
      ]);
      assert_eq!(select_transliteration(&a).unwrap().name, "Ringo Sheena");
  }

  #[test]
  fn falls_back_to_any_en_then_entity_sort_name() {
      // No primary -> any en "Artist name".
      let a1 = artist("Sheena, Ringo", vec![
          alias("Ringo Sheena", "Sheena, Ringo", Some("en"), false, "Artist name"),
      ]);
      assert_eq!(select_transliteration(&a1).unwrap().name, "Ringo Sheena");

      // No en alias at all -> entity sort-name, name == sort-name.
      let a2 = artist("Sheena, Ringo", vec![
          alias("椎名林檎", "椎名林檎", Some("ja"), true, "Artist name"),
      ]);
      let chosen = select_transliteration(&a2).unwrap();
      assert_eq!(chosen.name, "Sheena, Ringo");
      assert_eq!(chosen.sort_name, "Sheena, Ringo");
      assert!(chosen.from_entity_sort_name);
  }
  ```
- [ ] Run `cd rust && cargo test --test enrich_test transliteration`. Expected: **fails to compile** (`enrich::select` missing). (Adjust: run `cargo test --test enrich_test prefers_ skips_ tie_ falls_` or just `cargo test --test enrich_test` — the four new test names are distinctive.)
- [ ] Create `rust/src/enrich/select.rs` implementing the §5.1 algorithm exactly:
  ```rust
  use crate::enrich::model::{Artist, Alias};

  /// The chosen display transliteration for an artist (§5.1).
  #[derive(Debug, Clone, PartialEq, Eq)]
  pub struct ChosenAlias {
      pub name: String,
      pub sort_name: String,
      /// True when no usable alias existed and we fell back to the entity
      /// sort-name (sort-key priority tier 2/3 in §6.1).
      pub from_entity_sort_name: bool,
  }

  /// §5.1 artist-transliteration selection.
  /// 1. keep type == "Artist name"
  /// 2. prefer locale=="en" && primary; else any locale=="en"; else entity sort-name
  /// 3. tie-break: name ascending, take first (deterministic).
  pub fn select_transliteration(artist: &Artist) -> Option<ChosenAlias> {
      let artist_names: Vec<&Alias> = artist
          .aliases
          .iter()
          .filter(|a| a.alias_type.as_deref() == Some("Artist name"))
          .collect();

      // Tier 1: en + primary.
      if let Some(a) = pick_min_by_name(
          artist_names.iter().copied().filter(|a| is_en(a) && a.primary),
      ) {
          return Some(chosen(a));
      }
      // Tier 2: any en.
      if let Some(a) = pick_min_by_name(artist_names.iter().copied().filter(|a| is_en(a))) {
          return Some(chosen(a));
      }
      // Tier 3: entity sort-name (display name == sort-name; flagged).
      Some(ChosenAlias {
          name: artist.sort_name.clone(),
          sort_name: artist.sort_name.clone(),
          from_entity_sort_name: true,
      })
  }

  fn is_en(a: &Alias) -> bool {
      a.locale.as_deref() == Some("en")
  }

  fn pick_min_by_name<'a>(it: impl Iterator<Item = &'a Alias>) -> Option<&'a Alias> {
      it.min_by(|x, y| x.name.cmp(&y.name))
  }

  fn chosen(a: &Alias) -> ChosenAlias {
      ChosenAlias {
          name: a.name.clone(),
          // An alias may omit sort-name; fall back to its display name.
          sort_name: a.sort_name.clone().unwrap_or_else(|| a.name.clone()),
          from_entity_sort_name: false,
      }
  }
  ```
- [ ] Add `pub mod select;` to `rust/src/enrich/mod.rs`.
- [ ] Run `cd rust && cargo test --test enrich_test`. Expected: the four selection tests pass (plus earlier tasks' tests).
- [ ] Also add a property-style test (spec §8 mentions property tests for alias selection) using a fixed set: assert determinism — calling `select_transliteration` twice on the same artist returns the same result, and that reversing the alias vector order does not change the chosen name (proves the tie-break is order-independent). Run it; expect pass.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(enrich): §5.1 artist transliteration selection"`.

---

### Task 9: Pseudo-release discovery + alt-kind classification (pure)

**Files:**
- Create/extend: `rust/src/enrich/select.rs` (add pseudo-release fns)
- Test: `rust/tests/enrich_test.rs`

**Steps:**

- [ ] Add failing tests for discovering `transl-tracklisting` targets on a release and classifying a pseudo-release as translit vs translate. Use both the recorded `release_muzai.json` and small inline JSON:
  ```rust
  use rust_lib_olivier::enrich::model::Release;
  use rust_lib_olivier::enrich::select::{pseudo_release_targets, TRANSL_TRACKLISTING_TYPE_ID};

  #[test]
  fn finds_transl_tracklisting_targets() {
      let r: Release =
          serde_json::from_str(&fixture("release_muzai.json")).unwrap();
      let targets = pseudo_release_targets(&r);
      assert!(!targets.is_empty(), "expected at least one pseudo-release link");
      // Each target MBID is non-empty.
      assert!(targets.iter().all(|id| !id.is_empty()));
  }

  #[test]
  fn ignores_non_transl_relations() {
      let json = r#"{
        "id":"rel-x","title":"X",
        "relations":[
          {"type-id":"00000000-0000-0000-0000-000000000000","release":{"id":"other"}},
          {"type-id":"fc399d47-23a7-4c28-bfcf-0607a562b644","release":{"id":"pseudo"}}
        ],
        "media":[]
      }"#;
      let r: Release = serde_json::from_str(json).unwrap();
      assert_eq!(pseudo_release_targets(&r), vec!["pseudo".to_string()]);
  }

  #[test]
  fn type_id_constant_matches_spec() {
      assert_eq!(TRANSL_TRACKLISTING_TYPE_ID, "fc399d47-23a7-4c28-bfcf-0607a562b644");
  }
  ```
- [ ] Run `cd rust && cargo test --test enrich_test pseudo`. Expected: **fails to compile**.
- [ ] Extend `rust/src/enrich/select.rs`:
  ```rust
  use crate::enrich::model::Release;

  /// MusicBrainz `transl-tracklisting` relationship type-id (§5.1, Appendix B).
  pub const TRANSL_TRACKLISTING_TYPE_ID: &str = "fc399d47-23a7-4c28-bfcf-0607a562b644";

  /// Pseudo-release target MBIDs linked from `release` via `transl-tracklisting`.
  pub fn pseudo_release_targets(release: &Release) -> Vec<String> {
      release
          .relations
          .iter()
          .filter(|rel| rel.type_id.as_deref() == Some(TRANSL_TRACKLISTING_TYPE_ID))
          .filter_map(|rel| rel.release.as_ref().map(|r| r.id.clone()))
          .collect()
  }
  ```
- [ ] Run `cd rust && cargo test --test enrich_test pseudo type_id`. Expected: **3 pass**.
- [ ] Now add alt-kind classification. The kind (`translit` vs `translate`) is decided from the pseudo-release's **`text-representation { script, language }`** (added to the `Release` model in Task 7), NOT from a fragile ASCII/token-count heuristic — a mislabel here feeds 2b's bilingual display the wrong data. **Primary rule (deterministic):**
  - `script == "Latn"` ⇒ **`Translit`** (a Latin-script rendering of the original = romanization/transliteration), **unless** `language == "eng"`, which marks an English **`Translate`** (an English-language Latin-script title is a translation, not a romanization).
  - any non-`Latn` script ⇒ **`Translate`** (a different script that is not the original is treated as a translation for 2a).
  - **Fallback (only when `text-representation` is absent / both fields `None`):** the legacy ASCII/token heuristic, made deterministic and documented (no "TODO refine in 2b"): if the pseudo title is all-ASCII (Latin-only, ignoring whitespace) **and** has the same whitespace-token count as the original, classify `Translit`; otherwise `Translate`. This fallback exists only because some old MB releases omit `text-representation`; the script/language path is authoritative when present.
  Implement on the pseudo-release struct (`classify_pseudo`) with the title-pair fallback (`classify_alt`):
  ```rust
  use crate::enrich::model::{Release, TextRepresentation};

  /// Which kind of alternate a pseudo-release supplies. Authoritative source is
  /// the pseudo-release's `text-representation`; the title-pair heuristic is only
  /// a documented fallback for releases that omit it.
  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum AltKind {
      Translit,
      Translate,
  }

  /// Classify a pseudo-release using its `text-representation` (preferred), or
  /// the title-pair fallback when that metadata is absent. `original_title` is
  /// only consulted by the fallback.
  pub fn classify_pseudo(original_title: &str, pseudo: &Release) -> AltKind {
      if let Some(kind) = classify_from_text_representation(pseudo.text_representation.as_ref()) {
          return kind;
      }
      // No usable text-representation: deterministic title-pair fallback.
      classify_alt(original_title, &pseudo.title)
  }

  /// Returns `None` when `text-representation` carries no script and no language
  /// (caller then falls back to the title heuristic).
  fn classify_from_text_representation(tr: Option<&TextRepresentation>) -> Option<AltKind> {
      let tr = tr?;
      // English-language title is a translation regardless of script.
      if tr.language.as_deref() == Some("eng") {
          return Some(AltKind::Translate);
      }
      match tr.script.as_deref() {
          Some("Latn") => Some(AltKind::Translit),
          Some(_) => Some(AltKind::Translate), // non-Latn script that isn't the original
          None => None,                        // no script + non-eng language => fall back
      }
  }

  /// Deterministic title-pair fallback (no MB metadata available): all-ASCII +
  /// same token count as the original ⇒ transliteration, else translation.
  pub fn classify_alt(original_title: &str, pseudo_title: &str) -> AltKind {
      let romaji_like = pseudo_title.chars().all(|c| c.is_ascii() || c.is_whitespace())
          && pseudo_title.split_whitespace().count()
              == original_title.split_whitespace().count().max(1);
      if romaji_like {
          AltKind::Translit
      } else {
          AltKind::Translate
      }
  }
  ```
  Add `Translit`/`Translate` mapping to the DB string in `store.rs` (Task 11). Add tests covering BOTH the primary (script/language) path and the fallback:
  ```rust
  use rust_lib_olivier::enrich::model::{Release, TextRepresentation};
  use rust_lib_olivier::enrich::select::{classify_alt, classify_pseudo, AltKind};

  fn pseudo_with_text_rep(title: &str, script: Option<&str>, language: Option<&str>) -> Release {
      Release {
          id: "p".into(),
          title: title.into(),
          date: None,
          text_representation: Some(TextRepresentation {
              script: script.map(str::to_string),
              language: language.map(str::to_string),
          }),
          release_group: None,
          media: vec![],
          relations: vec![],
      }
  }

  #[test]
  fn classify_uses_text_representation_when_present() {
      // Latn script (romaji) => translit.
      assert_eq!(
          classify_pseudo("無罪モラトリアム", &pseudo_with_text_rep("Muzai Moratorium", Some("Latn"), Some("jpn"))),
          AltKind::Translit
      );
      // English language => translate even though script is Latn.
      assert_eq!(
          classify_pseudo("無罪モラトリアム", &pseudo_with_text_rep("Innocence Moratorium", Some("Latn"), Some("eng"))),
          AltKind::Translate
      );
      // Non-Latn script => translate.
      assert_eq!(
          classify_pseudo("無罪モラトリアム", &pseudo_with_text_rep("무죄 모라토리엄", Some("Hang"), Some("kor"))),
          AltKind::Translate
      );
  }

  #[test]
  fn classify_falls_back_to_title_heuristic_without_text_representation() {
      // text-representation absent (None) => deterministic title-pair fallback.
      let mut p = pseudo_with_text_rep("Muzai Moratorium", None, None);
      p.text_representation = None;
      assert_eq!(classify_pseudo("無罪モラトリアム", &p), AltKind::Translit);
      // 無罪モラトリアム -> "Muzai Moratorium" (translit), "Innocence Moratorium" (translate).
      assert_eq!(classify_alt("無罪モラトリアム", "Muzai Moratorium"), AltKind::Translit);
      assert_eq!(classify_alt("無罪モラトリアム", "Innocence Moratorium"), AltKind::Translate);
  }
  ```
  Note for the implementer: the §5.1 spec explicitly allows **both** kinds present. The `text-representation` script/language is the authoritative discriminator and is deterministic; the title-pair heuristic is a documented fallback for the rare release that omits `text-representation` (it is **not** a "TODO to refine in 2b" — it is the defined behavior). Storing both alts under their classified kinds is the deliverable.
- [ ] Run `cd rust && cargo test --test enrich_test classify`. Expected: pass (tune the rule against the captured fixtures until the two Muzai pseudo titles classify correctly).
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(enrich): pseudo-release discovery + alt-kind classification"`.

---

### Task 10: `MbClient` — rate limiter, 503 backoff, cache read-through

**Files:**
- Create: `rust/src/enrich/client.rs`
- Modify: `rust/src/enrich/mod.rs`
- Test: `rust/tests/enrich_test.rs`

The client owns: building MB URLs (base `https://musicbrainz.org/ws/2/`, `fmt=json`), the cache read-through against `mb_cache`, the 1 req/s spacing, and 503 exponential backoff. To keep the rate-limit + backoff testable without real time, inject a **clock + sleeper**. Use a small `Pacer` trait so `FakeHttp` tests run instantly.

**Steps:**

- [ ] Add failing tests:
  ```rust
  use rust_lib_olivier::db::open;
  use rust_lib_olivier::enrich::client::MbClient;

  #[tokio::test]
  async fn fetch_reads_through_and_writes_cache() {
      let conn = open(":memory:").unwrap();
      let body = fixture("artist_9e414497_aliases.json");
      let url = "https://musicbrainz.org/ws/2/artist/9e414497-1f44-4f0c-b031-f01923a3c5d2?inc=aliases&fmt=json";
      let http = FakeHttp::new().with(url, 200, &body);

      let client = MbClient::new(http); // test pacer = no-op
      let a = client
          .fetch_artist(&conn, "9e414497-1f44-4f0c-b031-f01923a3c5d2")
          .await
          .unwrap();
      assert!(!a.aliases.is_empty());

      // Cached: a SECOND fetch makes no new HTTP call.
      let _ = client
          .fetch_artist(&conn, "9e414497-1f44-4f0c-b031-f01923a3c5d2")
          .await
          .unwrap();
      assert_eq!(client.http().calls.borrow().len(), 1, "second fetch must hit cache");

      // mb_cache row exists.
      let n: i64 = conn
          .query_row("SELECT count(*) FROM mb_cache WHERE entity_type='artist'", [], |r| r.get(0))
          .unwrap();
      assert_eq!(n, 1);
  }

  #[tokio::test]
  async fn retries_on_503_then_succeeds() {
      let conn = open(":memory:").unwrap();
      let url = "https://musicbrainz.org/ws/2/artist/abc?inc=aliases&fmt=json";
      // FakeHttp variant that returns 503 the first N calls, then 200.
      let http = FlakyHttp::new(url, 2 /* 503s */, &fixture("artist_9e414497_aliases.json"));
      let client = MbClient::new(http);
      let a = client.fetch_artist(&conn, "abc").await.unwrap();
      assert!(!a.aliases.is_empty());
      assert_eq!(client.http().call_count(), 3); // 2 failures + 1 success
  }
  ```
  Add `FlakyHttp` to the test file (counts calls, returns 503 then 200). The client's `Pacer` in tests is a no-op so no real sleeping occurs; assert correctness, not timing.
- [ ] Run `cd rust && cargo test --test enrich_test fetch_reads retries_on_503`. Expected: **fails to compile**.
- [ ] Create `rust/src/enrich/client.rs`:
  ```rust
  use std::time::Duration;

  use rusqlite::{Connection, OptionalExtension};

  use crate::enrich::http::MbHttp;
  use crate::enrich::model::{Artist, Release, ReleaseBrowse};

  const BASE: &str = "https://musicbrainz.org/ws/2";
  const ARTIST_INC: &str = "aliases";
  const RELEASE_INC: &str = "recordings+release-rels+release-groups+artist-credits";
  const PSEUDO_INC: &str = "recordings";
  /// MusicBrainz rate limit is 1 req/s; space ≥1.05 s (Appendix B).
  const MIN_SPACING: Duration = Duration::from_millis(1050);
  const MAX_503_RETRIES: u32 = 5;

  /// Abstracts "wait until it's safe to make the next request" and "sleep for a
  /// backoff" so tests run instantly. Production uses real wall-clock sleeps.
  #[async_trait::async_trait(?Send)]
  pub trait Pacer {
      async fn pace(&self);
      async fn backoff(&self, attempt: u32);
  }

  /// Real pacer: enforces MIN_SPACING between calls + exponential backoff.
  pub struct WallClockPacer {
      last: std::cell::RefCell<Option<std::time::Instant>>,
  }
  impl Default for WallClockPacer {
      fn default() -> Self {
          Self { last: std::cell::RefCell::new(None) }
      }
  }
  #[async_trait::async_trait(?Send)]
  impl Pacer for WallClockPacer {
      async fn pace(&self) {
          let wait = {
              let last = self.last.borrow();
              last.map(|t| MIN_SPACING.saturating_sub(t.elapsed()))
          };
          if let Some(w) = wait {
              if !w.is_zero() {
                  tokio::time::sleep(w).await;
              }
          }
          *self.last.borrow_mut() = Some(std::time::Instant::now());
      }
      async fn backoff(&self, attempt: u32) {
          // 1s, 2s, 4s, 8s, 16s.
          let secs = 1u64 << attempt.min(4);
          tokio::time::sleep(Duration::from_secs(secs)).await;
      }
  }

  /// No-op pacer for tests.
  pub struct NoopPacer;
  #[async_trait::async_trait(?Send)]
  impl Pacer for NoopPacer {
      async fn pace(&self) {}
      async fn backoff(&self, _attempt: u32) {}
  }

  pub struct MbClient<H: MbHttp, P: Pacer = WallClockPacer> {
      http: H,
      pacer: P,
  }

  impl<H: MbHttp> MbClient<H, NoopPacer> {
      /// Test constructor: no real sleeping.
      pub fn new(http: H) -> Self {
          Self { http, pacer: NoopPacer }
      }
  }

  impl<H: MbHttp, P: Pacer> MbClient<H, P> {
      pub fn with_pacer(http: H, pacer: P) -> Self {
          Self { http, pacer }
      }
      pub fn http(&self) -> &H {
          &self.http
      }

      pub async fn fetch_artist(&self, conn: &Connection, mbid: &str) -> anyhow::Result<Artist> {
          let url = format!("{BASE}/artist/{mbid}?inc={ARTIST_INC}&fmt=json");
          let body = self.get_cached(conn, "artist", mbid, ARTIST_INC, &url).await?;
          Ok(serde_json::from_str(&body)?)
      }

      pub async fn fetch_release(&self, conn: &Connection, mbid: &str) -> anyhow::Result<Release> {
          let url = format!("{BASE}/release/{mbid}?inc={RELEASE_INC}&fmt=json");
          let body = self.get_cached(conn, "release", mbid, RELEASE_INC, &url).await?;
          Ok(serde_json::from_str(&body)?)
      }

      pub async fn fetch_pseudo_release(
          &self,
          conn: &Connection,
          mbid: &str,
      ) -> anyhow::Result<Release> {
          let url = format!("{BASE}/release/{mbid}?inc={PSEUDO_INC}&fmt=json");
          let body = self.get_cached(conn, "release", mbid, PSEUDO_INC, &url).await?;
          Ok(serde_json::from_str(&body)?)
      }

      pub async fn browse_release_group(
          &self,
          conn: &Connection,
          rg_mbid: &str,
          offset: u32,
      ) -> anyhow::Result<ReleaseBrowse> {
          let inc = format!("release-rels:offset={offset}");
          let url = format!(
              "{BASE}/release?release-group={rg_mbid}&inc=release-rels&limit=100&offset={offset}&fmt=json"
          );
          let body = self.get_cached(conn, "release-browse", rg_mbid, &inc, &url).await?;
          Ok(serde_json::from_str(&body)?)
      }

      /// Cache read-through. On miss: pace, fetch (retrying 503), store, return.
      async fn get_cached(
          &self,
          conn: &Connection,
          entity_type: &str,
          mbid: &str,
          inc_set: &str,
          url: &str,
      ) -> anyhow::Result<String> {
          if let Some(body) = self.cache_get(conn, entity_type, mbid, inc_set)? {
              return Ok(body);
          }
          let body = self.fetch_with_backoff(url).await?;
          self.cache_put(conn, entity_type, mbid, inc_set, &body)?;
          Ok(body)
      }

      async fn fetch_with_backoff(&self, url: &str) -> anyhow::Result<String> {
          let mut attempt = 0;
          loop {
              self.pacer.pace().await;
              let resp = self.http.get(url).await?;
              match resp.status {
                  200 => return Ok(resp.body),
                  503 if attempt < MAX_503_RETRIES => {
                      self.pacer.backoff(attempt).await;
                      attempt += 1;
                  }
                  s => return Err(anyhow::anyhow!("MB returned HTTP {s} for {url}")),
              }
          }
      }

      fn cache_get(
          &self,
          conn: &Connection,
          entity_type: &str,
          mbid: &str,
          inc_set: &str,
      ) -> anyhow::Result<Option<String>> {
          let body = conn
              .query_row(
                  "SELECT json FROM mb_cache WHERE entity_type=?1 AND mbid=?2 AND inc_set=?3",
                  rusqlite::params![entity_type, mbid, inc_set],
                  |r| r.get::<_, String>(0),
              )
              .optional()?;
          Ok(body)
      }

      fn cache_put(
          &self,
          conn: &Connection,
          entity_type: &str,
          mbid: &str,
          inc_set: &str,
          json: &str,
      ) -> anyhow::Result<()> {
          let now = std::time::SystemTime::now()
              .duration_since(std::time::UNIX_EPOCH)?
              .as_secs() as i64;
          conn.execute(
              "INSERT INTO mb_cache(entity_type, mbid, inc_set, json, fetched_at)
               VALUES (?1, ?2, ?3, ?4, ?5)
               ON CONFLICT(entity_type, mbid, inc_set)
                 DO UPDATE SET json=excluded.json, fetched_at=excluded.fetched_at",
              rusqlite::params![entity_type, mbid, inc_set, json, now],
          )?;
          Ok(())
      }
  }
  ```
- [ ] Add `pub mod client;` to `rust/src/enrich/mod.rs`.
- [ ] Run `cd rust && cargo test --test enrich_test`. Expected: cache + 503 tests pass. (Add `FlakyHttp` to the test file if not yet present.)
- [ ] Add a test asserting the constructed artist URL contains `inc=aliases&fmt=json` and the release URL contains the full `recordings+release-rels+release-groups+artist-credits` bundle (assert via the recorded call in `FakeHttp.calls`). Run it; expect pass.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(enrich): MbClient with rate-limit, 503 backoff, cache read-through"`.

---

### Task 11: `store.rs` — persist alts, dates, transliteration, sort key, enriched flag

**Files:**
- Create: `rust/src/enrich/store.rs`
- Modify: `rust/src/enrich/mod.rs`
- Test: `rust/tests/enrich_test.rs`

**Steps:**

- [ ] Add failing tests seeding a tiny catalog then asserting each write:
  ```rust
  use rust_lib_olivier::db::open;
  use rust_lib_olivier::enrich::select::{AltKind, ChosenAlias};
  use rust_lib_olivier::enrich::store;

  fn seed_one_release(conn: &rusqlite::Connection) {
      conn.execute("INSERT INTO artist(mbid,name,sort_name) VALUES ('art1','椎名林檎','椎名林檎')", []).unwrap();
      conn.execute("INSERT INTO release_group(mbid,title,first_release_date) VALUES ('rg1','無罪モラトリアム',NULL)", []).unwrap();
      conn.execute("INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title,date) VALUES ('rel1','rg1','art1','無罪モラトリアム',NULL)", []).unwrap();
      conn.execute("INSERT INTO track(release_mbid,recording_mbid,disc,position,title) VALUES ('rel1','rec1',1,1,'歌舞伎町の女王')", []).unwrap();
      conn.execute("INSERT INTO file(path,mtime,size,track_id,added_at) VALUES ('/m/a.flac',0,0,1,0)", []).unwrap();
  }

  #[test]
  fn applies_artist_transliteration_and_sort_key() {
      let conn = open(":memory:").unwrap();
      seed_one_release(&conn);
      // Seeded sort_name is the embedded albumartistsort value "椎名林檎".
      store::apply_artist_transliteration(&conn, "art1", &ChosenAlias {
          name: "Ringo Sheena".into(),
          sort_name: "Sheena, Ringo".into(),
          from_entity_sort_name: false,
      }).unwrap();
      let (translit, sort, embedded): (Option<String>, String, Option<String>) = conn.query_row(
          "SELECT transliteration, sort_name, sort_name_embedded FROM artist WHERE mbid='art1'", [],
          |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
      assert_eq!(translit.as_deref(), Some("Ringo Sheena"));
      assert_eq!(sort, "Sheena, Ringo");
      // The pre-enrichment embedded sort_name is preserved for the §6.1 tier-3 fallback.
      assert_eq!(embedded.as_deref(), Some("椎名林檎"));

      // A re-enrich must NOT clobber the preserved embedded value.
      store::apply_artist_transliteration(&conn, "art1", &ChosenAlias {
          name: "Ringo Sheena".into(),
          sort_name: "Sheena, Ringo".into(),
          from_entity_sort_name: false,
      }).unwrap();
      let embedded2: Option<String> = conn.query_row(
          "SELECT sort_name_embedded FROM artist WHERE mbid='art1'", [],
          |r| r.get(0)).unwrap();
      assert_eq!(embedded2.as_deref(), Some("椎名林檎"));
  }

  #[test]
  fn applies_dates_from_release_and_group() {
      let conn = open(":memory:").unwrap();
      seed_one_release(&conn);
      store::apply_dates(&conn, "rel1", "rg1", "無罪モラトリアム", Some("1999-02-24"), Some("1999-02-24")).unwrap();
      let (orig, reissue): (Option<String>, Option<String>) = conn.query_row(
          "SELECT rg.first_release_date, r.date FROM release r JOIN release_group rg ON rg.mbid=r.release_group_mbid WHERE r.mbid='rel1'",
          [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
      assert_eq!(orig.as_deref(), Some("1999-02-24"));
      assert_eq!(reissue.as_deref(), Some("1999-02-24"));
  }

  #[test]
  fn original_year_lands_on_real_rg_when_catalog_rg_is_synthetic() {
      // The catalog release points at a synth:rg:… key (file tags lacked the RG
      // MBID). apply_dates must write the original year to the REAL RG from the
      // MB JSON and re-point the release, not to the synth key.
      let conn = open(":memory:").unwrap();
      conn.execute("INSERT INTO artist(mbid,name,sort_name) VALUES ('art1','椎名林檎','椎名林檎')", []).unwrap();
      conn.execute("INSERT INTO release_group(mbid,title) VALUES ('synth:rg:art1|無罪モラトリアム','無罪モラトリアム')", []).unwrap();
      conn.execute("INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title,date) VALUES ('rel1','synth:rg:art1|無罪モラトリアム','art1','無罪モラトリアム',NULL)", []).unwrap();

      store::apply_dates(&conn, "rel1", "realrg1", "無罪モラトリアム", Some("1999-02-24"), Some("1999-02-24")).unwrap();

      // The release now points at the real RG, and the original year lives there.
      let (rg_mbid, orig): (String, Option<String>) = conn.query_row(
          "SELECT rg.mbid, rg.first_release_date
           FROM release r JOIN release_group rg ON rg.mbid = r.release_group_mbid
           WHERE r.mbid='rel1'",
          [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
      assert_eq!(rg_mbid, "realrg1");
      assert_eq!(orig.as_deref(), Some("1999-02-24"));
      // The synthetic RG did NOT receive the original year.
      let synth_date: Option<String> = conn.query_row(
          "SELECT first_release_date FROM release_group WHERE mbid='synth:rg:art1|無罪モラトリアム'",
          [], |r| r.get(0)).unwrap();
      assert_eq!(synth_date, None);
  }

  #[test]
  fn upserts_release_and_track_alts() {
      let conn = open(":memory:").unwrap();
      seed_one_release(&conn);
      store::upsert_release_alt(&conn, "rel1", AltKind::Translit, "Muzai Moratorium").unwrap();
      store::upsert_release_alt(&conn, "rel1", AltKind::Translate, "Innocence Moratorium").unwrap();
      store::upsert_track_alt(&conn, "rec1", AltKind::Translit, "Kabukichou no Joou").unwrap();
      let n: i64 = conn.query_row("SELECT count(*) FROM release_title_alt WHERE release_mbid='rel1'", [], |r| r.get(0)).unwrap();
      assert_eq!(n, 2);
      // Re-applying the same kind overwrites, not duplicates.
      store::upsert_release_alt(&conn, "rel1", AltKind::Translit, "Muzai Moratorium 2").unwrap();
      let title: String = conn.query_row("SELECT title FROM release_title_alt WHERE release_mbid='rel1' AND kind='translit'", [], |r| r.get(0)).unwrap();
      assert_eq!(title, "Muzai Moratorium 2");
  }

  #[test]
  fn marks_files_enriched_for_release() {
      let conn = open(":memory:").unwrap();
      seed_one_release(&conn);
      store::mark_release_files_enriched(&conn, "rel1").unwrap();
      let enriched: i64 = conn.query_row("SELECT enriched FROM file WHERE path='/m/a.flac'", [], |r| r.get(0)).unwrap();
      assert_eq!(enriched, 1);
  }
  ```
- [ ] Run `cd rust && cargo test --test enrich_test applies_ upserts_ marks_ original_year_`. Expected: **fails to compile**.
- [ ] Create `rust/src/enrich/store.rs`:
  ```rust
  use rusqlite::Connection;

  use crate::enrich::select::{AltKind, ChosenAlias};

  fn kind_str(k: AltKind) -> &'static str {
      match k {
          AltKind::Translit => "translit",
          AltKind::Translate => "translate",
      }
  }

  /// §5.1 + §6.1 tier 1: store the chosen transliteration and overwrite the
  /// artist sort key with the alias sort-name.
  ///
  /// Before overwriting `sort_name`, preserve the pre-enrichment value (the
  /// embedded `albumartistsort` tag, §6.1 tier 3 fallback) into
  /// `sort_name_embedded` — but only on FIRST enrichment, i.e. when
  /// `sort_name_embedded IS NULL`, so a re-enrich (`force=true`) never clobbers
  /// the original embedded value with an already-overwritten alias sort-name.
  /// This keeps the embedded fallback recoverable for a future manual-override
  /// UI (2b/post-v1).
  pub fn apply_artist_transliteration(
      conn: &Connection,
      artist_mbid: &str,
      chosen: &ChosenAlias,
  ) -> anyhow::Result<()> {
      // Snapshot the embedded sort_name once (first enrichment only).
      conn.execute(
          "UPDATE artist
              SET sort_name_embedded = sort_name
            WHERE mbid = ?1 AND sort_name_embedded IS NULL",
          rusqlite::params![artist_mbid],
      )?;
      conn.execute(
          "UPDATE artist SET transliteration = ?1, sort_name = ?2 WHERE mbid = ?3",
          rusqlite::params![chosen.name, chosen.sort_name, artist_mbid],
      )?;
      Ok(())
  }

  /// Original year ← release-group first-release-date; reissue year ← release date.
  /// Only overwrites when MB supplies a value (COALESCE keeps any embedded tag value).
  ///
  /// `real_rg_mbid` MUST be the release-group id read from the MB release JSON
  /// (`release.release-group.id`), NOT the catalog's stored
  /// `release.release_group_mbid` — which may be a `synth:rg:…` key when the
  /// file's tags lacked the RG MBID. We (a) ensure the real RG row exists, (b)
  /// write the original date onto it, and (c) re-point this release at the real
  /// RG so future joins (and 2b's display) land the original year correctly.
  pub fn apply_dates(
      conn: &Connection,
      release_mbid: &str,
      real_rg_mbid: &str,
      rg_title: &str,
      first_release_date: Option<&str>,
      release_date: Option<&str>,
  ) -> anyhow::Result<()> {
      // (a) Insert the real RG row if absent (keep an existing title/date).
      conn.execute(
          "INSERT INTO release_group(mbid, title) VALUES (?1, ?2)
           ON CONFLICT(mbid) DO NOTHING",
          rusqlite::params![real_rg_mbid, rg_title],
      )?;
      // (b) Write the original date onto the REAL release-group.
      conn.execute(
          "UPDATE release_group SET first_release_date = COALESCE(?1, first_release_date) WHERE mbid = ?2",
          rusqlite::params![first_release_date, real_rg_mbid],
      )?;
      // (c) Re-point this release at the real RG (it may have been a synth:rg:… key).
      conn.execute(
          "UPDATE release SET release_group_mbid = ?1 WHERE mbid = ?2",
          rusqlite::params![real_rg_mbid, release_mbid],
      )?;
      // Reissue date on the release itself.
      conn.execute(
          "UPDATE release SET date = COALESCE(?1, date) WHERE mbid = ?2",
          rusqlite::params![release_date, release_mbid],
      )?;
      Ok(())
  }

  pub fn upsert_release_alt(
      conn: &Connection,
      release_mbid: &str,
      kind: AltKind,
      title: &str,
  ) -> anyhow::Result<()> {
      conn.execute(
          "INSERT INTO release_title_alt(release_mbid, kind, title) VALUES (?1, ?2, ?3)
           ON CONFLICT(release_mbid, kind) DO UPDATE SET title = excluded.title",
          rusqlite::params![release_mbid, kind_str(kind), title],
      )?;
      Ok(())
  }

  pub fn upsert_track_alt(
      conn: &Connection,
      recording_mbid: &str,
      kind: AltKind,
      title: &str,
  ) -> anyhow::Result<()> {
      conn.execute(
          "INSERT INTO track_title_alt(recording_mbid, kind, title) VALUES (?1, ?2, ?3)
           ON CONFLICT(recording_mbid, kind) DO UPDATE SET title = excluded.title",
          rusqlite::params![recording_mbid, kind_str(kind), title],
      )?;
      Ok(())
  }

  /// Flip `enriched` for every file whose track belongs to this release.
  pub fn mark_release_files_enriched(conn: &Connection, release_mbid: &str) -> anyhow::Result<()> {
      conn.execute(
          "UPDATE file SET enriched = 1 WHERE track_id IN
             (SELECT id FROM track WHERE release_mbid = ?1)",
          rusqlite::params![release_mbid],
      )?;
      Ok(())
  }
  ```
- [ ] Add `pub mod store;` to `rust/src/enrich/mod.rs`.
- [ ] Run `cd rust && cargo test --test enrich_test`. Expected: store tests pass.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(enrich): persist transliterations, dates, title alts, enriched flag"`.

---

### Task 12: `progress.rs` — `EnrichProgress` DTO

**Files:**
- Create: `rust/src/enrich/progress.rs`
- Modify: `rust/src/enrich/mod.rs`

**Steps:**

- [ ] Create `rust/src/enrich/progress.rs` mirroring `ScanProgress`'s shape so Dart can reuse the streaming UI pattern:
  ```rust
  /// Streamed enrichment progress, mirroring `catalog::scan::ScanProgress`.
  #[derive(Clone)]
  pub struct EnrichProgress {
      /// Unique album-artists + releases processed so far.
      pub entities_done: u64,
      /// Total entities to process this run (artists + releases).
      pub entities_total: u64,
      /// Human-readable label of the current entity (artist/album name).
      pub current: String,
      pub done: bool,
  }
  ```
- [ ] Add `pub mod progress;` to `rust/src/enrich/mod.rs`.
- [ ] Run `cd rust && cargo build`. Expected: compiles. (No test yet; it's a plain DTO exercised by Task 13.)
- [ ] Commit: `git commit -am "feat(enrich): EnrichProgress streamed DTO"`.

---

### Task 13: `run.rs` — enrichment orchestration (resumable, streaming)

This is the heart: select work, dedupe to unique entities, drive the §5.1 per-album algorithm (release → pseudo-releases → album-artist), with release-group browse fallback, write everything, mark files enriched, stream progress, honor `force`, and stop early on stream cancellation.

**Files:**
- Create: `rust/src/enrich/run.rs`
- Modify: `rust/src/enrich/mod.rs`
- Test: `rust/tests/enrich_test.rs`

**Steps:**

- [ ] Add a failing **end-to-end** test driving `enrich` against `FakeHttp` wired with all the recorded fixtures, then asserting the catalog is fully enriched:
  ```rust
  use rust_lib_olivier::enrich::run::enrich;
  use rust_lib_olivier::enrich::client::MbClient;

  fn seed_taggable_catalog(conn: &rusqlite::Connection) {
      // Real MBIDs so the client builds the fixture URLs. Use the MBIDs recorded
      // at the top of the fixture files.
      conn.execute("INSERT INTO artist(mbid,name,sort_name) VALUES ('9e414497-1f44-4f0c-b031-f01923a3c5d2','椎名林檎','椎名林檎')", []).unwrap();
      conn.execute("INSERT INTO release_group(mbid,title) VALUES ('<rg-mbid>','無罪モラトリアム')", []).unwrap();
      conn.execute("INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title) VALUES ('<rel-mbid>','<rg-mbid>','9e414497-1f44-4f0c-b031-f01923a3c5d2','無罪モラトリアム')", []).unwrap();
      // recording MBIDs must match media[].tracks[].recording.id in the pseudo fixtures.
      conn.execute("INSERT INTO track(release_mbid,recording_mbid,disc,position,title) VALUES ('<rel-mbid>','<rec1>',1,1,'歌舞伎町の女王')", []).unwrap();
      conn.execute("INSERT INTO file(path,mtime,size,track_id,added_at,enriched) VALUES ('/m/a.flac',0,0,1,0,0)", []).unwrap();
  }

  #[tokio::test]
  async fn enriches_catalog_end_to_end() {
      let conn = open(":memory:").unwrap();
      seed_taggable_catalog(&conn);

      let http = FakeHttp::new()
          .with("<artist url>", 200, &fixture("artist_9e414497_aliases.json"))
          .with("<release url>", 200, &fixture("release_muzai.json"))
          .with("<translit pseudo url>", 200, &fixture("release_muzai_translit.json"))
          .with("<translate pseudo url>", 200, &fixture("release_muzai_translate.json"));
      let client = MbClient::new(http);

      let mut last = None;
      enrich(&conn, &client, false, |p| { last = Some(p.clone()); }).await.unwrap();
      assert!(last.unwrap().done);

      // Artist transliteration + sort key set.
      let (translit, sort): (Option<String>, String) = conn.query_row(
          "SELECT transliteration, sort_name FROM artist WHERE mbid='9e414497-1f44-4f0c-b031-f01923a3c5d2'",
          [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
      assert_eq!(translit.as_deref(), Some("Ringo Sheena"));
      assert_eq!(sort, "Sheena, Ringo");

      // Release + track alts present.
      let ra: i64 = conn.query_row("SELECT count(*) FROM release_title_alt", [], |r| r.get(0)).unwrap();
      assert!(ra >= 1);
      let ta: i64 = conn.query_row("SELECT count(*) FROM track_title_alt WHERE recording_mbid='<rec1>'", [], |r| r.get(0)).unwrap();
      assert!(ta >= 1);

      // File marked enriched.
      let e: i64 = conn.query_row("SELECT enriched FROM file WHERE path='/m/a.flac'", [], |r| r.get(0)).unwrap();
      assert_eq!(e, 1);
  }

  #[tokio::test]
  async fn resumes_skipping_already_enriched_and_cached() {
      let conn = open(":memory:").unwrap();
      seed_taggable_catalog(&conn);
      conn.execute("UPDATE file SET enriched = 1", []).unwrap();
      // FakeHttp with NO responses: if enrich tried to fetch anything it would error.
      let client = MbClient::new(FakeHttp::new());
      enrich(&conn, &client, false, |_| {}).await.unwrap();
      assert_eq!(client.http().calls.borrow().len(), 0, "nothing to do => no HTTP");
  }

  #[tokio::test]
  async fn synthetic_mbids_are_skipped() {
      let conn = open(":memory:").unwrap();
      // A synth-keyed artist/release (no real MBID) must never be fetched.
      conn.execute("INSERT INTO artist(mbid,name,sort_name) VALUES ('synth:aa:foo','Foo','Foo')", []).unwrap();
      conn.execute("INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('synth:rel:foo|bar','synth:aa:foo','Bar')", []).unwrap();
      conn.execute("INSERT INTO track(release_mbid,disc,position,title) VALUES ('synth:rel:foo|bar',1,1,'T')", []).unwrap();
      conn.execute("INSERT INTO file(path,mtime,size,track_id,added_at,enriched) VALUES ('/m/s.flac',0,0,1,0,0)", []).unwrap();
      let client = MbClient::new(FakeHttp::new());
      enrich(&conn, &client, false, |_| {}).await.unwrap();
      assert_eq!(client.http().calls.borrow().len(), 0);
      // Synthetic file stays unenriched (correctly — no MB data exists).
      let e: i64 = conn.query_row("SELECT enriched FROM file WHERE path='/m/s.flac'", [], |r| r.get(0)).unwrap();
      assert_eq!(e, 0);
  }
  ```
- [ ] Run `cd rust && cargo test --test enrich_test enriches_ resumes_ synthetic_`. Expected: **fails to compile**.
- [ ] Create `rust/src/enrich/run.rs`. Structure: (a) gather the unique real-MBID releases that own at least one un-enriched file (skip `synth:%` and `enriched=1` unless `force`); gather the unique real-MBID album-artists; (b) for each artist, fetch + select + apply transliteration/sort; (c) for each release, fetch, apply dates, discover pseudo-releases (with release-group browse fallback), fetch each pseudo, extract + classify + store album/track alts joined by recording MBID, then mark files enriched; (d) stream `EnrichProgress`; (e) return early if `on_progress` signals cancellation (the FFI wrapper checks `sink.add`):
  ```rust
  use rusqlite::Connection;

  use crate::enrich::client::{MbClient, Pacer};
  use crate::enrich::http::MbHttp;
  use crate::enrich::model::Release;
  use crate::enrich::progress::EnrichProgress;
  use crate::enrich::select::{
      classify_pseudo, pseudo_release_targets, select_transliteration,
  };
  use crate::enrich::store;

  fn is_real_mbid(mbid: &str) -> bool {
      !mbid.is_empty() && !mbid.starts_with("synth:")
  }

  /// Unique real-MBID album-artists owning ≥1 un-enriched file (or all, if force).
  fn artists_to_enrich(conn: &Connection, force: bool) -> anyhow::Result<Vec<String>> {
      let sql = if force {
          "SELECT DISTINCT r.album_artist_mbid FROM release r
           WHERE r.album_artist_mbid NOT LIKE 'synth:%'"
      } else {
          "SELECT DISTINCT r.album_artist_mbid FROM release r
           JOIN track t ON t.release_mbid = r.mbid
           JOIN file f ON f.track_id = t.id
           WHERE r.album_artist_mbid NOT LIKE 'synth:%' AND f.enriched = 0"
      };
      let mut stmt = conn.prepare(sql)?;
      let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
      Ok(rows.collect::<Result<Vec<_>, _>>()?)
  }

  /// Unique real-MBID releases owning ≥1 un-enriched file (or all, if force),
  /// paired with their release-group MBID for the fallback browse + dates.
  fn releases_to_enrich(
      conn: &Connection,
      force: bool,
  ) -> anyhow::Result<Vec<(String, Option<String>, String)>> {
      let filter = if force { "" } else { "AND f.enriched = 0" };
      let sql = format!(
          "SELECT DISTINCT r.mbid, r.release_group_mbid, COALESCE(r.title,'')
           FROM release r
           JOIN track t ON t.release_mbid = r.mbid
           JOIN file f ON f.track_id = t.id
           WHERE r.mbid NOT LIKE 'synth:%' {filter}"
      );
      let mut stmt = conn.prepare(&sql)?;
      let rows = stmt.query_map([], |r| {
          Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, String>(2)?))
      })?;
      Ok(rows.collect::<Result<Vec<_>, _>>()?)
  }

  /// Orchestrate enrichment. `on_progress` returns false to request cancellation.
  pub async fn enrich<H: MbHttp, P: Pacer>(
      conn: &Connection,
      client: &MbClient<H, P>,
      force: bool,
      mut on_progress: impl FnMut(EnrichProgress) -> bool,
  ) -> anyhow::Result<()> {
      let artists = artists_to_enrich(conn, force)?;
      let releases = releases_to_enrich(conn, force)?;
      let total = (artists.len() + releases.len()) as u64;
      let mut done = 0u64;

      // ── artists ──
      for artist_mbid in &artists {
          let mb = client.fetch_artist(conn, artist_mbid).await?;
          if let Some(chosen) = select_transliteration(&mb) {
              store::apply_artist_transliteration(conn, artist_mbid, &chosen)?;
          }
          done += 1;
          if !on_progress(EnrichProgress {
              entities_done: done,
              entities_total: total,
              current: mb.name.clone(),
              done: false,
          }) {
              return Ok(()); // cancelled
          }
      }

      // ── releases ──
      // `rg_mbid` is the CATALOG's stored release_group_mbid (may be `synth:rg:…`);
      // it is used only for the release-group browse fallback URL. The original
      // date is written to the REAL RG read from the release JSON below.
      for (rel_mbid, rg_mbid, title) in &releases {
          // Network fetches happen OUTSIDE the per-release transaction (a tokio
          // sleep must not hold a SQLite write lock). The pseudo-releases are
          // fetched first, then all DB writes for this release commit atomically.
          let release = client.fetch_release(conn, rel_mbid).await?;

          // pseudo-releases on this release, else fall back to browsing the group
          // (browse keyed by the catalog RG mbid — it's only a fetch URL).
          let mut targets = pseudo_release_targets(&release);
          if targets.is_empty() {
              if let Some(rg) = rg_mbid {
                  targets = find_pseudo_via_browse(conn, client, rg).await?;
              }
          }
          let mut pseudos = Vec::new();
          for pseudo_mbid in targets {
              pseudos.push(client.fetch_pseudo_release(conn, &pseudo_mbid).await?);
          }

          // ── per-release unit of work: ONE transaction (FIX 5) ──
          // apply dates + all pseudo title-alts + mark files enriched commit
          // together, so a crash can't leave dates committed but files
          // un-enriched (inconsistent). Uses the codebase's existing
          // `conn.unchecked_transaction()` pattern (cf. save_queue /
          // reconcile_album_artists). One commit per release.
          let tx = conn.unchecked_transaction()?;

          // dates: original ← release-group first-release-date written to the REAL
          // RG (release.release-group.id), NOT the catalog's possibly-synthetic
          // release_group_mbid; reissue ← release date.
          if let Some(rg) = release.release_group.as_ref() {
              store::apply_dates(
                  &tx,
                  rel_mbid,
                  &rg.id,
                  title,
                  rg.first_release_date.as_deref(),
                  release.date.as_deref(),
              )?;
          }

          for pseudo in &pseudos {
              apply_pseudo_alts(&tx, rel_mbid, title, pseudo)?;
          }

          store::mark_release_files_enriched(&tx, rel_mbid)?;
          tx.commit()?;

          done += 1;
          if !on_progress(EnrichProgress {
              entities_done: done,
              entities_total: total,
              current: title.clone(),
              done: false,
          }) {
              return Ok(());
          }
      }

      on_progress(EnrichProgress {
          entities_done: done,
          entities_total: total,
          current: String::new(),
          done: true,
      });
      Ok(())
  }

  /// Album title alt = pseudo-release `title`; track title alts joined by
  /// recording MBID against media[].tracks[].recording.id.
  fn apply_pseudo_alts(
      conn: &Connection,
      release_mbid: &str,
      original_title: &str,
      pseudo: &Release,
  ) -> anyhow::Result<()> {
      // Authoritative: the pseudo-release's text-representation (script/language);
      // falls back to the title-pair heuristic only when that metadata is absent.
      let kind = classify_pseudo(original_title, pseudo);
      store::upsert_release_alt(conn, release_mbid, kind, &pseudo.title)?;
      for medium in &pseudo.media {
          for tr in &medium.tracks {
              if let Some(rec) = &tr.recording {
                  // classify each track title against… the original track title is
                  // unknown here cheaply; reuse the release-level kind (a pseudo
                  // release is uniformly translit OR translate per MB convention).
                  store::upsert_track_alt(conn, &rec.id, kind, &tr.title)?;
              }
          }
      }
      Ok(())
  }

  /// Release-group browse fallback (§5.1): page release-rels, collect any
  /// transl-tracklisting targets found on sibling releases.
  async fn find_pseudo_via_browse<H: MbHttp, P: Pacer>(
      conn: &Connection,
      client: &MbClient<H, P>,
      rg_mbid: &str,
  ) -> anyhow::Result<Vec<String>> {
      let mut offset = 0u32;
      let mut out = Vec::new();
      loop {
          let page = client.browse_release_group(conn, rg_mbid, offset).await?;
          for rel in &page.releases {
              out.extend(pseudo_release_targets(rel));
          }
          offset += page.releases.len() as u32;
          if page.releases.is_empty() || offset >= page.release_count {
              break;
          }
      }
      out.sort();
      out.dedup();
      Ok(out)
  }
  ```
  Note on per-track kind reuse: a single pseudo-release is uniformly one kind (MB attaches a transliteration pseudo-release OR a translation pseudo-release, not mixed), so `classify_pseudo` is called once at the release level — using that pseudo-release's `text-representation` — and the resulting kind is applied to all its track titles. This is correct and avoids needing each original track title. Document this in the code comment (shown above).
  Note on the per-release transaction (FIX 5): each release's full unit of work — `apply_dates` (which also re-points a `synth:rg:…` release at its real RG) + all pseudo title-alts + `mark_release_files_enriched` — is wrapped in ONE `conn.unchecked_transaction()` that commits once per release, exactly as `save_queue`/`reconcile_album_artists` do. This is the transaction boundary: a crash can never leave dates committed but the file un-enriched (or vice-versa) — either the whole release's enrichment lands or none of it does. **Network fetches (release + pseudo-releases + browse) run BEFORE the transaction opens** so a `tokio::time::sleep` (rate-limit/backoff) never holds a SQLite write lock; the `mb_cache` writes those fetches perform are autocommitted independently and are intentionally outside the per-release transaction.
- [ ] Add `pub mod run;` to `rust/src/enrich/mod.rs`.
- [ ] Fill in the `<...>` URL/MBID placeholders in the test with the real values recorded in the fixtures (read the MBIDs from the **fixture-MBID comment block** at the top of `rust/tests/enrich_test.rs`, recorded in Task 5). Build the expected URLs exactly as `client.rs` constructs them.
- [ ] **Make the end-to-end test deterministic about the discovery path it exercises** (FIX 7): assert the SPECIFIC path recorded in the Task 5 comment block, so the test isn't ambiguous about direct-rel vs browse-fallback.
  - If the recorded path is **DIRECT** (`transl-tracklisting` rel on the main release): wire `FakeHttp` with the artist + main-release + two pseudo-release fixtures only (do **not** provide a browse-fallback response), and add `assert!(!client.http().calls.borrow().iter().any(|u| u.contains("release-group=")), "must not browse — direct rel path");`. The absence of a browse response also means any accidental fallback would error, making a regression loud.
  - If the recorded path is **BROWSE FALLBACK** (no direct rel on the main release): wire `FakeHttp` with the artist + main-release + `release_group_browse_muzai.json` + the two pseudo-release fixtures, and add `assert!(client.http().calls.borrow().iter().any(|u| u.contains("release-group=")), "must browse — fallback path");`.
- [ ] Run `cd rust && cargo test --test enrich_test`. Expected: all enrichment tests pass. Iterate on URL strings / recording-MBID alignment until green.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(enrich): resumable streaming enrichment orchestration"`.

---

### Task 14: Enrichment FFI — `enrich_library` (streaming) + `clear_mb_cache`

**Files:**
- Create: `rust/src/api/enrich.rs`
- Modify: `rust/src/api/mod.rs`
- Regenerate: `rust/src/frb_generated.rs`, `lib/src/rust/**`

This bridges the async orchestration **from a synchronous FFI fn** — exactly like the existing `scan_library` (a sync `fn`, not async). `enrich_library` opens the DB, builds a `ReqwestHttp` from the `mb_contact_email` setting + `CARGO_PKG_VERSION`, wraps it in `MbClient::with_pacer(http, WallClockPacer::default())`, builds a **private current-thread tokio runtime**, and `block_on`s `run::enrich`, streaming `EnrichProgress` to Dart. **It must NOT be an `async fn`:** frb 2.12's async executor requires the future to be `Send + 'static`, but the enrichment core holds a non-`Send` `Connection`/`RefCell` pacer across `.await` and uses `#[async_trait(?Send)]`, so an async entry point would not compile. Driving the async core with `block_on` on a single current thread keeps `?Send`/`Connection`/`RefCell` valid (it never crosses an executor boundary). Cancellation: when `sink.add` errors (Dart dropped the stream), the closure returns `false` and `enrich` stops (Decision #6).

**Steps:**

- [ ] Create `rust/src/api/enrich.rs`. `enrich_library` is a plain **synchronous** `fn` that builds a current-thread runtime and `block_on`s the async core:
  ```rust
  use crate::db;
  use crate::enrich::client::{MbClient, WallClockPacer};
  use crate::enrich::http::ReqwestHttp;
  use crate::enrich::progress::EnrichProgress;
  use crate::enrich::run;
  use crate::frb_generated::StreamSink;
  use crate::settings;

  /// Stream enrichment progress to Dart. `force=false` is the resumable auto path
  /// (skips already-enriched files + cached entities); `force=true` re-runs the
  /// logic over everything, still reading entity JSON from the cache.
  ///
  /// SYNC fn (like `scan_library`): dispatched on frb's worker-thread path. The
  /// async enrichment core is driven by a private current-thread tokio runtime
  /// via `block_on` — NOT frb's async executor, which would reject the non-`Send`
  /// `Connection`/`RefCell`/`?Send` types this design holds across `.await`.
  pub fn enrich_library(
      db_path: String,
      force: bool,
      sink: StreamSink<EnrichProgress>,
  ) -> anyhow::Result<()> {
      let conn = db::open(&db_path)?;
      let email = settings::get_setting_or_default(&conn, "mb_contact_email")?;
      let http = ReqwestHttp::new(env!("CARGO_PKG_VERSION"), &email)?;
      let client = MbClient::with_pacer(http, WallClockPacer::default());

      // Private current-thread runtime: single thread, never crosses an executor
      // boundary, so `Connection`/`RefCell`/`?Send` stay valid. `enable_time()`
      // is required because the pacer calls `tokio::time::sleep`. `run::enrich`
      // takes `&Connection` (its per-release transactions use the
      // `conn.unchecked_transaction()` pattern, which works on `&self`).
      let rt = tokio::runtime::Builder::new_current_thread()
          .enable_time()
          .build()?;
      rt.block_on(run::enrich(&conn, &client, force, |p| sink.add(p).is_ok()))
  }

  /// Empty the MusicBrainz response cache so the next enrich refetches from the
  /// network (spec §4: manual refresh only).
  pub fn clear_mb_cache(db_path: String) -> anyhow::Result<()> {
      let conn = db::open(&db_path)?;
      conn.execute("DELETE FROM mb_cache", [])?;
      Ok(())
  }
  ```
- [ ] Add `pub mod enrich;` to `rust/src/api/mod.rs`.
- [ ] Run `cd rust && cargo build`. Expected: compiles. (No async attribute is involved — this is a plain sync `fn` with a `StreamSink` param, dispatched exactly like the existing sync `scan_library`. frb's async-fn path is deliberately **not** used.)
- [ ] Regenerate the bridge from the repo root: `mise exec -- flutter_rust_bridge_codegen generate`. Expected: `rust/src/frb_generated.rs` and `lib/src/rust/api/enrich.dart` updated; `EnrichProgress` gains a Dart class.
- [ ] Run `cd rust && cargo build` again. Expected: regenerated glue compiles.
- [ ] Run the existing Dart FFI smoke tests to confirm the bridge still loads: `mise exec -- flutter test integration_test/catalog_ffi_test.dart -d linux` (per phase1 results, FFI tests run one file per `flutter test -d linux` invocation under xvfb in CI). Expected: green. (If the environment can't run a Linux device here, defer to CI and note it.)
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "feat(ffi): enrich_library streaming + clear_mb_cache bridge"`.

---

### Task 15: Wire the auto-trigger contract (Rust-side verification)

The Dart scan-completion path will call `enrich_library(dbPath, force: false, ...)` after a scan emits `done: true`. The only Rust-side requirement is that calling `enrich_library` right after a scan is correct and idempotent. Verify with an integration test that scans a fixture library then enriches; since the fixtures lack real MBIDs, this primarily proves the post-scan call is safe (no-op when there's nothing to enrich) and that a forced enrich over synthetic-only data does nothing.

**Files:**
- Test: `rust/tests/enrich_test.rs`

**Steps:**

- [ ] Add a test scanning the existing audio fixtures then enriching, asserting it completes without error and does not fetch (fixtures are synth/unknown-MBID):
  ```rust
  use rust_lib_olivier::catalog::scan::scan_roots;

  #[tokio::test]
  async fn enrich_after_scan_is_safe_noop_for_untagged_fixtures() {
      let dir = tempfile::tempdir().unwrap();
      for f in ["sample.mp3", "sample.flac"] {
          std::fs::copy(
              format!("{}/tests/fixtures/{f}", env!("CARGO_MANIFEST_DIR")),
              dir.path().join(f),
          ).unwrap();
      }
      let mut conn = open(":memory:").unwrap();
      let root = dir.path().to_string_lossy().to_string();
      scan_roots(&mut conn, std::slice::from_ref(&root), |_| {}).unwrap();

      let client = MbClient::new(FakeHttp::new()); // no canned responses
      let mut saw_done = false;
      enrich(&conn, &client, false, |p| { saw_done |= p.done; true }).await.unwrap();
      assert!(saw_done);
      assert_eq!(client.http().calls.borrow().len(), 0,
          "fixture files carry no real MBIDs, so nothing is fetched");
  }
  ```
  (If a fixture *does* carry a real MBID — check by reading its tags — adjust the assertion: either provide that fixture's recorded JSON or assert only that enrich completes. The point is post-scan enrich is safe.)
- [ ] Run `cd rust && cargo test --test enrich_test enrich_after_scan`. Expected: pass.
- [ ] Run `mise exec -- precious lint --all`. Expected: green.
- [ ] Commit: `git commit -am "test(enrich): post-scan enrich is a safe no-op for untagged libraries"`.

---

### Task 16: Full suite, lint, codegen sanity, and docs

**Files:**
- (No source changes expected; verification + optional doc note.)

**Steps:**

- [ ] Run the complete Rust suite: `cd rust && cargo test`. Expected: all tests green (Phase 1's 33+ plus the new enrichment + settings tests).
- [ ] Run clippy explicitly as CI does: `cd rust && cargo clippy --all-targets --all-features -- -D warnings`. Expected: no warnings. (The async traits with `?Send` and the generic `MbClient` are the most likely clippy hot-spots — fix any `needless_lifetimes`/`new_without_default` lints by adding `#[derive(Default)]` or `Default` impls as clippy suggests.)
- [ ] Re-run codegen to confirm it's a no-op (the committed `frb_generated.rs` matches sources): `mise exec -- flutter_rust_bridge_codegen generate` then `git status --porcelain`. Expected: clean (no diff) — proves Tasks 4 and 14 committed the regenerated output.
- [ ] Run `mise exec -- precious lint --all`. Expected: green across clippy, rustfmt, dart-format, flutter-analyze, prettier, taplo, typos.
- [ ] (Optional) If the project keeps a running phase-results doc, the human will record Phase 2a outcomes; this plan does not write docs. No commit unless source changed.

---

## Done criteria for Phase 2a

- [ ] **Migrations (append-only):** `setting`, `mb_cache`, `release_title_alt`, `track_title_alt` tables and the `artist.transliteration` + `artist.sort_name_embedded` columns exist; all Phase 1 migration tests still pass; FKs remain enforced.
- [ ] **Settings store:** `get_setting`/`set_setting`/`get_setting_or_default` work with the spec defaults (`language_leads`=A, `mb_contact_email`=autarch@urth.org, `play_threshold_percent`=50, `play_threshold_seconds`=240); exposed over FFI.
- [ ] **MB client:** rate-limited (≥1.05 s spacing via an injectable pacer), exponential backoff on HTTP 503, and a `mb_cache` read-through keyed by `(entity_type, mbid, inc_set)`; the HTTP layer is behind the `MbHttp` trait so tests never hit the network and never sleep.
- [ ] **§5.1 algorithm:** artist transliteration selection (type=="Artist name", prefer en+primary, else any en, else entity sort-name; tie-break by name ascending) is implemented, deterministic, and property-tested (椎名林檎 → display "Ringo Sheena", sort "Sheena, Ringo").
- [ ] **Pseudo-releases:** discovered via the `transl-tracklisting` rel (`fc399d47-…`) on the release, with a release-group browse fallback; both translit and translate alts stored when present; kind classified from each pseudo-release's `text-representation` (script `Latn` ⇒ translit; non-Latn script or `language` `eng` ⇒ translate) with a documented title-pair fallback only when `text-representation` is absent; track alts joined by **recording MBID**.
- [ ] **Dates:** original year ← release-group `first-release-date` written to the **real** release-group read from `release.release-group.id` (re-pointing the release when its catalog RG was a `synth:rg:…` key), reissue year ← release `date`, written to the catalog.
- [ ] **Sort key:** `artist.sort_name` overwritten from the chosen alias sort-name (§6.1 tier 1), keeping `artists_page` ordered queries working; the pre-enrichment embedded sort-name preserved into `artist.sort_name_embedded` on first enrichment (§6.1 tier 3 fallback, recoverable for a future manual-override UI).
- [ ] **Resumability:** enrichment skips already-`enriched` files and cached entities; `force=true` re-runs logic over everything while reading JSON from cache; synthetic-MBID rows are never fetched; cancellation via dropped stream stops the run promptly.
- [ ] **FFI:** `enrich_library(db_path, force, sink)` streams `EnrichProgress` (mirroring `scan_library`), and `clear_mb_cache(db_path)` empties the cache; the bridge is regenerated and committed, and `flutter_rust_bridge_codegen generate` is a no-op against committed sources.
- [ ] **Tests:** recorded MusicBrainz JSON fixtures (Shiina Ringo artist `9e414497-…`, 無罪モラトリアム release + translit/translate pseudo-releases) drive selection, pseudo-discovery, client cache/backoff, store, and an end-to-end orchestration test — all green; `cargo clippy -D warnings` and `precious lint --all` green.
- [ ] **Auto-trigger contract:** post-scan `enrich_library(force=false)` is verified safe/idempotent in Rust; the one-line Dart call after a scan's `done` event (and the Settings "Re-enrich all" → `force=true`, "Refresh from MusicBrainz" → `clear_mb_cache` + enrich) is the only remaining wiring, deferred to the Phase 2b UI work.
- [ ] **Out of scope, confirmed deferred to 2b:** bilingual display queries (joining alts for layout-A rows), the Flutter bilingual rows, the A/B toggle UI, and FTS bilingual search. 2a leaves the data ready for all of them.

---

### Critical Files for Implementation
- /home/autarch/projects/olivier/rust/src/db.rs (append-only migrations + `open()`)
- /home/autarch/projects/olivier/rust/src/enrich/run.rs (new — orchestration heart)
- /home/autarch/projects/olivier/rust/src/enrich/client.rs (new — rate limit, 503 backoff, cache read-through)
- /home/autarch/projects/olivier/rust/src/api/catalog.rs (the FFI/`StreamSink` pattern `api/enrich.rs` must mirror)
- /home/autarch/projects/olivier/rust/tests/enrich_test.rs (new — fixtures-driven TDD suite)