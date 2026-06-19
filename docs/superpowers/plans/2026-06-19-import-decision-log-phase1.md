# Import Decision Log — Phase 1 (Scanner) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write the scanner's import decisions (ADD / DEDUP / MERGE / REMOVE / PRUNE / FAIL) to a plain-text `import-log.log` beside the DB, stop a bad file from aborting a scan, and view/clear the log in Settings.

**Architecture:** A best-effort `DecisionLog` file appender (internal Rust, constructed from `db_path` — no FFI/bridge changes). `upsert_file` returns the decisions it made; the deletion sweep / `prune_orphans` / `reconcile_album_artists` switch to enumerate-then-act so removals/merges can be named. The Dart viewer reads the file directly with `dart:io`.

**Tech Stack:** Rust (rusqlite), Flutter + Riverpod. NO flutter_rust_bridge changes in Phase 1.

**Spec:** `docs/superpowers/specs/2026-06-19-import-decision-log-design.md`. Phase 2 (MusicBrainz/enrich decisions) is a separate later plan.

**Conventions for every task:**
- Branch `import-decision-log`. NEVER stage `TODO` / `#TODO#`.
- Rust: `cd rust && cargo test`. Flutter: `mise exec -- flutter test`. Lint: `mise exec -- precious lint --all`. Run `cargo fmt` before committing Rust (the linter checks rustfmt). Use `git -C /home/autarch/projects/olivier` for git.
- ACTUALLY RUN every command (guard flutter with `timeout`); report real output.
- End commit messages with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.

---

## Task 1: `DecisionLog` appender + `Decision` enum + UTC timestamp

**Files:**
- Create: `rust/src/decision_log.rs`
- Modify: `rust/src/lib.rs` (declare the module)

- [ ] **Step 1: Declare the module.** In `rust/src/lib.rs`, add next to the other top-level `pub mod` lines (e.g. after `pub mod catalog;`):

```rust
pub mod decision_log;
```

- [ ] **Step 2: Write the failing tests.** Create `rust/src/decision_log.rs` with ONLY this test module first (the types it references don't exist yet, so it fails to compile):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn fmt_utc_formats_known_epochs() {
        assert_eq!(fmt_utc(0), "1970-01-01 00:00:00");
        assert_eq!(fmt_utc(86400), "1970-01-02 00:00:00");
        assert_eq!(fmt_utc(1_700_000_000), "2023-11-14 22:13:20");
    }

    #[test]
    fn appends_header_and_decisions() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("import-log.log");
        let log = DecisionLog::to_path(Some(path.clone()));
        log.header("Scan /m/Music");
        log.record(&Decision::AddTrack {
            title: "T".into(),
            artist: "A".into(),
            album: "Al".into(),
            path: "/m/x.flac".into(),
        });
        log.record(&Decision::Dedup {
            path: "/m/y.flac".into(),
            track_title: "T".into(),
            album: "Al".into(),
            disc: 1,
            position: 2,
            existing_path: "/m/x.flac".into(),
        });

        let body = std::fs::read_to_string(&path).unwrap();
        // Assert on category words + detail substrings (not exact column padding).
        assert!(body.contains("=== Scan /m/Music @ "), "got: {body}");
        assert!(body.contains("ADD"), "got: {body}");
        assert!(body.contains("track \"T\" — A [Al]"), "got: {body}");
        assert!(body.contains("DEDUP"), "got: {body}");
        assert!(body.contains("/m/y.flac → existing track \"T\""), "got: {body}");
    }

    #[test]
    fn disabled_and_bad_path_never_panic() {
        DecisionLog::to_path(None).record(&Decision::Remove { path: "/x".into() });
        // A path under a non-existent parent dir is best-effort: no panic, no error.
        let bad = std::path::PathBuf::from("/nonexistent-dir-xyz/import-log.log");
        DecisionLog::to_path(Some(bad)).record(&Decision::Remove { path: "/x".into() });
    }
}
```

- [ ] **Step 3: Run, verify it fails.**

Run: `cd rust && cargo test --lib decision_log 2>&1 | tail -15`
Expected: FAIL to compile (`DecisionLog`, `Decision`, `fmt_utc` undefined).

- [ ] **Step 4: Implement.** Prepend the implementation ABOVE the test module in `rust/src/decision_log.rs`:

```rust
//! A best-effort, human-readable decision log written to a plain text file
//! beside the DB. Every write is best-effort: any IO error is swallowed so
//! logging can never break or fail a scan/enrich.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

/// File name of the decision log, kept beside the SQLite DB.
pub const LOG_FILENAME: &str = "import-log.log";

/// One import/enrichment decision worth recording. The scanner emits the first
/// six variants; enrich (Phase 2) reuses this log with its own lines.
pub enum Decision {
    AddArtist { name: String },
    AddAlbum { title: String, artist: String },
    AddTrack { title: String, artist: String, album: String, path: String },
    Dedup {
        path: String,
        track_title: String,
        album: String,
        disc: i64,
        position: i64,
        existing_path: String,
    },
    Remove { path: String },
    PruneTrack { title: String, album: String },
    PruneAlbum { title: String, artist: String },
    PruneArtist { name: String },
    Merge { synth_name: String, real_name: String, real_mbid: String },
    Fail { path: String, error: String },
}

impl Decision {
    pub fn category(&self) -> &'static str {
        match self {
            Decision::AddArtist { .. }
            | Decision::AddAlbum { .. }
            | Decision::AddTrack { .. } => "ADD",
            Decision::Dedup { .. } => "DEDUP",
            Decision::Remove { .. } => "REMOVE",
            Decision::PruneTrack { .. }
            | Decision::PruneAlbum { .. }
            | Decision::PruneArtist { .. } => "PRUNE",
            Decision::Merge { .. } => "MERGE",
            Decision::Fail { .. } => "FAIL",
        }
    }

    pub fn detail(&self) -> String {
        match self {
            Decision::AddArtist { name } => format!("artist \"{name}\""),
            Decision::AddAlbum { title, artist } => format!("album \"{title}\" — {artist}"),
            Decision::AddTrack { title, artist, album, path } => {
                format!("track \"{title}\" — {artist} [{album}]  [{path}]")
            }
            Decision::Dedup { path, track_title, album, disc, position, existing_path } => {
                format!(
                    "{path} → existing track \"{track_title}\" [{album}] (disc {disc}, pos {position}; also {existing_path})"
                )
            }
            Decision::Remove { path } => format!("file {path} (gone from disk)"),
            Decision::PruneTrack { title, album } => format!("track \"{title}\" [{album}] (no files remain)"),
            Decision::PruneAlbum { title, artist } => format!("album \"{title}\" — {artist} (no files remain)"),
            Decision::PruneArtist { name } => format!("artist \"{name}\" (no files remain)"),
            Decision::Merge { synth_name, real_name, real_mbid } => {
                format!("synth artist \"{synth_name}\" → {real_name} (mbid {real_mbid})")
            }
            Decision::Fail { path, error } => format!("{path}: {error}"),
        }
    }
}

/// Append-only decision log. `None` path = disabled (all writes no-op).
pub struct DecisionLog {
    path: Option<PathBuf>,
}

impl DecisionLog {
    /// Log beside the DB: `<dir of db_path>/import-log.log`. A `:memory:` or
    /// parent-less db_path yields a relative file name (fine — production
    /// db_path is always an absolute file path).
    pub fn for_db(db_path: &str) -> Self {
        let dir = Path::new(db_path).parent().map(Path::to_path_buf).unwrap_or_default();
        Self { path: Some(dir.join(LOG_FILENAME)) }
    }

    /// Explicit path (tests) or `None` to disable.
    pub fn to_path(path: Option<PathBuf>) -> Self {
        Self { path }
    }

    /// Write a run-delimiter header line.
    pub fn header(&self, text: &str) {
        self.write_line(&format!("=== {text} @ {} ===", fmt_utc(now_secs())));
    }

    /// Record one decision (timestamp + padded category + detail).
    pub fn record(&self, d: &Decision) {
        self.write_line(&format!("{}  {:<7} {}", fmt_utc(now_secs()), d.category(), d.detail()));
    }

    fn write_line(&self, line: &str) {
        let Some(path) = &self.path else { return };
        // Best-effort: ignore every IO error.
        let _ = (|| -> std::io::Result<()> {
            let mut f = OpenOptions::new().create(true).append(true).open(path)?;
            writeln!(f, "{line}")
        })();
    }
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Format a unix-seconds instant as UTC `YYYY-MM-DD HH:MM:SS` (no deps;
/// Howard Hinnant's civil-from-days algorithm).
fn fmt_utc(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (h, mi, s) = (sod / 3600, (sod % 3600) / 60, sod % 60);

    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };

    format!("{year:04}-{m:02}-{d:02} {h:02}:{mi:02}:{s:02}")
}
```

- [ ] **Step 5: Run, verify it passes.**

Run: `cd rust && cargo test --lib decision_log 2>&1 | tail -8`
Expected: PASS (3 tests). Then `cd rust && cargo fmt && cargo test 2>&1 | tail -3` — full suite green.

- [ ] **Step 6: Commit.**

```bash
git -C /home/autarch/projects/olivier add rust/src/decision_log.rs rust/src/lib.rs
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Add DecisionLog appender for the import decision log

Best-effort plain-text appender + Decision enum + dependency-free UTC
timestamp formatter. No scan wiring yet.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Scan ADD / DEDUP (upsert_file returns decisions)

**Files:**
- Modify: `rust/src/catalog/scan.rs` (`upsert_file` returns `Vec<Decision>`; `scan_roots` + `reread_track_tags` take a `&DecisionLog`)
- Modify: `rust/src/api/catalog.rs` (`scan_library` / `reread_track_tags` construct the log)
- Test: `rust/tests/scan_dedup_test.rs`

- [ ] **Step 1: Write the failing test.** Create `rust/tests/scan_dedup_test.rs` (an end-to-end scan over two copies of the same fixture, which share tags → the same `(release, disc, position)` → DEDUP — no `TrackTags` construction needed):

```rust
use rust_lib_olivier::catalog::scan::scan_roots;
use rust_lib_olivier::db::open;
use rust_lib_olivier::decision_log::DecisionLog;
use std::fs;
use tempfile::TempDir;

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

#[test]
fn first_copy_adds_and_a_second_same_track_copy_dedups() {
    let tmp = TempDir::new().unwrap();
    let music = tmp.path().join("music");
    fs::create_dir_all(&music).unwrap();
    // Two copies of one file => identical tags => same (release, disc, position).
    fs::copy(fixture("sample.flac"), music.join("a.flac")).unwrap();
    fs::copy(fixture("sample.flac"), music.join("b.flac")).unwrap();

    let mut conn = open(":memory:").unwrap();
    let log_path = tmp.path().join("import-log.log");
    let log = DecisionLog::to_path(Some(log_path.clone()));
    scan_roots(&mut conn, &[music.to_string_lossy().to_string()], &log, |_| {}).unwrap();

    // Both files import but collapse to a single track.
    assert_eq!(conn.query_row("SELECT COUNT(*) FROM file", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
    assert_eq!(conn.query_row("SELECT COUNT(*) FROM track", [], |r| r.get::<_, i64>(0)).unwrap(), 1);

    let body = fs::read_to_string(&log_path).unwrap();
    assert!(body.contains("ADD"), "expected an ADD line: {body}");
    assert!(body.contains("DEDUP"), "expected a DEDUP line: {body}");
}
```

- [ ] **Step 2: Run, verify it fails.**

Run: `cd rust && cargo test --test scan_dedup_test 2>&1 | tail -15`
Expected: FAIL to compile — `scan_roots` currently takes 3 args (no `&DecisionLog`); the log param is added in this task.

- [ ] **Step 3: Make `upsert_file` return decisions.** In `rust/src/catalog/scan.rs`:

Add the import near the top (with the other `use crate::...` lines):

```rust
use crate::decision_log::{Decision, DecisionLog};
```

Change the `upsert_file` signature and body. The signature becomes:

```rust
fn upsert_file(
    tx: &Transaction,
    tags: &TrackTags,
    path: &str,
    mtime: i64,
    size: i64,
    epoch: i64,
    now_secs: i64,
) -> anyhow::Result<Vec<Decision>> {
```

Immediately AFTER the three `let *_mbid = …` key computations and `let sort_name = …` (i.e. just before `// Upsert artist`), capture prior existence:

```rust
    let artist_existed = tx
        .query_row("SELECT 1 FROM artist WHERE mbid = ?1", rusqlite::params![artist_mbid], |_| Ok(()))
        .optional()?
        .is_some();
    let album_existed = tx
        .query_row("SELECT 1 FROM release WHERE mbid = ?1", rusqlite::params![rel_mbid], |_| Ok(()))
        .optional()?
        .is_some();
```

Immediately AFTER `let position = tags.track_no.unwrap_or(1) as i64;` (and before the track upsert), capture the prior track + any other file already backing that position:

```rust
    let prior_track_id: Option<i64> = tx
        .query_row(
            "SELECT id FROM track WHERE release_mbid = ?1 AND disc = ?2 AND position = ?3",
            rusqlite::params![rel_mbid, disc, position],
            |r| r.get(0),
        )
        .optional()?;
    let prior_other_file: Option<String> = match prior_track_id {
        Some(tid) => tx
            .query_row(
                "SELECT path FROM file WHERE track_id = ?1 AND path != ?2 LIMIT 1",
                rusqlite::params![tid, path],
                |r| r.get(0),
            )
            .optional()?,
        None => None,
    };
```

Then REPLACE the final `Ok(())` (the last line of the fn) with the decision assembly:

```rust
    let mut decisions = Vec::new();
    if !artist_existed {
        decisions.push(Decision::AddArtist { name: album_artist_name.to_string() });
    }
    if !album_existed {
        decisions.push(Decision::AddAlbum {
            title: album.to_string(),
            artist: album_artist_name.to_string(),
        });
    }
    match (prior_track_id, prior_other_file) {
        (None, _) => decisions.push(Decision::AddTrack {
            title: tags.title.clone().unwrap_or_default(),
            artist: album_artist_name.to_string(),
            album: album.to_string(),
            path: path.to_string(),
        }),
        (Some(_), Some(existing_path)) => decisions.push(Decision::Dedup {
            path: path.to_string(),
            track_title: tags.title.clone().unwrap_or_default(),
            album: album.to_string(),
            disc,
            position,
            existing_path,
        }),
        // prior track with no *other* file == a re-scan/update of this same file:
        // not a new decision.
        (Some(_), None) => {}
    }
    Ok(decisions)
```

Ensure `use rusqlite::OptionalExtension;` is present at the top of `scan.rs` (the `.optional()` calls need it — add it if missing).

- [ ] **Step 4: Thread `&DecisionLog` into the callers.** Change `scan_roots` and `reread_track_tags` signatures to take `log: &DecisionLog`, write a header, and log the returned decisions.

`scan_roots` signature → add the param:
```rust
pub fn scan_roots(
    conn: &mut Connection,
    roots: &[String],
    log: &DecisionLog,
    mut on_progress: impl FnMut(ScanProgress),
) -> anyhow::Result<()> {
```
Right after the `files_seen`/`files_changed` locals (before `for root in roots`), add:
```rust
    log.header(&format!("Scan {}", roots.join(", ")));
```
Where `upsert_file(&tx, …)?;` is called (currently `upsert_file(&tx, &tags, &path_str, mtime, size, epoch, now_secs)?;`), capture and log its result:
```rust
            let decisions = upsert_file(&tx, &tags, &path_str, mtime, size, epoch, now_secs)?;
            tx.commit()?;
            for d in &decisions {
                log.record(d);
            }
```

`reread_track_tags` signature → add the param:
```rust
pub fn reread_track_tags(conn: &mut Connection, track_id: i64, log: &DecisionLog) -> anyhow::Result<()> {
```
At its `upsert_file(&tx, …)?;` call, capture + log likewise:
```rust
        let decisions = upsert_file(&tx, &tags, path, mtime, size, epoch, now_secs)?;
        tx.commit()?;
        for d in &decisions {
            log.record(d);
        }
```

- [ ] **Step 5: Update the FFI callers.** In `rust/src/api/catalog.rs`, add the import and construct the log:

```rust
use crate::decision_log::DecisionLog;
```
`scan_library`:
```rust
pub fn scan_library(
    db_path: String,
    roots: Vec<String>,
    sink: StreamSink<ScanProgress>,
) -> anyhow::Result<()> {
    let mut conn = db::open(&db_path)?;
    let log = DecisionLog::for_db(&db_path);
    scan::scan_roots(&mut conn, &roots, &log, |p| {
        let _ = sink.add(p);
    })
}
```
`reread_track_tags`:
```rust
pub fn reread_track_tags(db_path: String, track_id: i64) -> anyhow::Result<()> {
    let mut conn = db::open(&db_path)?;
    let log = DecisionLog::for_db(&db_path);
    scan::reread_track_tags(&mut conn, track_id, &log)
}
```

- [ ] **Step 6: Fix the other `scan_roots`/`reread_track_tags` callers.** Search and update any remaining callers in non-test code and tests:

Run: `cd /home/autarch/projects/olivier && grep -rn 'scan_roots(\|reread_track_tags(' rust/src rust/tests | grep -v 'fn scan_roots\|fn reread_track_tags'`

For each call site, pass a log. In production callers (e.g. `rust/src/catalog/roots.rs` if it scans), use `DecisionLog::for_db(db_path)` if a db_path is available, else thread one through. In tests, pass `&DecisionLog::to_path(None)` (disabled) unless the test asserts log output. Show each edit you make.

- [ ] **Step 7: Run, verify it passes.**

Run: `cd rust && cargo test 2>&1 | tail -5`
Expected: PASS — the new `scan_dedup_test` passes and all existing scan/catalog tests still pass (they now pass a disabled log).

- [ ] **Step 8: Commit.**

```bash
cd rust && cargo fmt && cd ..
git -C /home/autarch/projects/olivier add rust/src/catalog/scan.rs rust/src/api/catalog.rs rust/tests/scan_dedup_test.rs
# plus any caller files Step 6 touched
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Log ADD/DEDUP scan decisions from upsert_file

upsert_file returns the decisions it made; scan_roots and reread_track_tags
write a run header and record them to the import log.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Bad file logs FAIL and no longer aborts the scan

**Files:**
- Modify: `rust/src/catalog/scan.rs` (the `read_tags` call in `scan_roots`)
- Test: `rust/tests/scan_fail_test.rs`

- [ ] **Step 1: Write the failing test.** Create `rust/tests/scan_fail_test.rs`:

```rust
use rust_lib_olivier::catalog::scan::scan_roots;
use rust_lib_olivier::db::open;
use rust_lib_olivier::decision_log::DecisionLog;
use std::fs;
use tempfile::TempDir;

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

#[test]
fn a_bad_file_logs_fail_and_the_scan_still_imports_the_good_one() {
    let tmp = TempDir::new().unwrap();
    let music = tmp.path().join("music");
    fs::create_dir_all(&music).unwrap();
    // One real audio file …
    fs::copy(fixture("sample.flac"), music.join("good.flac")).unwrap();
    // … and one file with an audio extension but garbage contents.
    fs::write(music.join("broken.flac"), b"not a real flac").unwrap();

    let mut conn = open(":memory:").unwrap();
    let log_path = tmp.path().join("import-log.log");
    let log = DecisionLog::to_path(Some(log_path.clone()));

    // Must NOT error despite the broken file.
    scan_roots(&mut conn, &[music.to_string_lossy().to_string()], &log, |_| {}).unwrap();

    // The good file imported.
    let tracks: i64 = conn.query_row("SELECT COUNT(*) FROM track", [], |r| r.get(0)).unwrap();
    assert_eq!(tracks, 1, "the good file should have imported");

    // The bad file produced a FAIL line.
    let body = fs::read_to_string(&log_path).unwrap();
    assert!(body.contains("FAIL"), "expected a FAIL line, got: {body}");
    assert!(body.contains("broken.flac"), "FAIL should name the bad file: {body}");
}
```

- [ ] **Step 2: Run, verify it fails.**

Run: `cd rust && cargo test --test scan_fail_test 2>&1 | tail -15`
Expected: FAIL — `scan_roots` returns `Err` (the `?` on `read_tags` aborts), so `.unwrap()` panics.

- [ ] **Step 3: Skip + log instead of abort.** In `rust/src/catalog/scan.rs`, replace the tag-read line in `scan_roots`:

```rust
            // Parse tags and upsert
            let tags = read_tags(path).with_context(|| format!("read_tags for {path_str}"))?;
```
with:
```rust
            // Parse tags and upsert. A single unreadable file is logged and
            // skipped — it must not abort the whole scan.
            let tags = match read_tags(path) {
                Ok(t) => t,
                Err(e) => {
                    log.record(&Decision::Fail { path: path_str.clone(), error: e.to_string() });
                    files_seen += 1;
                    on_progress(ScanProgress {
                        files_seen,
                        files_changed,
                        current: path_str,
                        done: false,
                    });
                    continue;
                }
            };
```

- [ ] **Step 4: Run, verify it passes.**

Run: `cd rust && cargo test --test scan_fail_test 2>&1 | tail -6`
Expected: PASS. Then `cd rust && cargo test 2>&1 | tail -3` — full suite green.

- [ ] **Step 5: Commit.**

```bash
cd rust && cargo fmt && cd ..
git -C /home/autarch/projects/olivier add rust/src/catalog/scan.rs rust/tests/scan_fail_test.rs
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Log unreadable files as FAIL and keep scanning

A bad file no longer aborts the entire scan: it is recorded as a FAIL
decision and skipped, so the rest of the library still imports.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: REMOVE / PRUNE / MERGE

**Files:**
- Modify: `rust/src/catalog/scan.rs` (deletion sweep + `prune_orphans` + `reconcile_album_artists` take `&DecisionLog`; SELECT-then-DELETE)
- Test: `rust/tests/scan_remove_test.rs`

- [ ] **Step 1: Write the failing test.** Create `rust/tests/scan_remove_test.rs`:

```rust
use rust_lib_olivier::catalog::scan::scan_roots;
use rust_lib_olivier::db::open;
use rust_lib_olivier::decision_log::DecisionLog;
use std::fs;
use tempfile::TempDir;

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

#[test]
fn deleting_a_file_then_rescanning_logs_remove_and_prune() {
    let tmp = TempDir::new().unwrap();
    let music = tmp.path().join("music");
    fs::create_dir_all(&music).unwrap();
    let track = music.join("one.flac");
    fs::copy(fixture("sample.flac"), &track).unwrap();

    let mut conn = open(":memory:").unwrap();
    let log_path = tmp.path().join("import-log.log");
    let log = DecisionLog::to_path(Some(log_path.clone()));
    let roots = vec![music.to_string_lossy().to_string()];

    // First scan imports the file.
    scan_roots(&mut conn, &roots, &log, |_| {}).unwrap();
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM file", [], |r| r.get::<_, i64>(0)).unwrap(),
        1
    );

    // Delete the file on disk and re-scan.
    fs::remove_file(&track).unwrap();
    scan_roots(&mut conn, &roots, &log, |_| {}).unwrap();

    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM file", [], |r| r.get::<_, i64>(0)).unwrap(),
        0,
        "the deleted file should be swept"
    );
    let body = fs::read_to_string(&log_path).unwrap();
    assert!(body.contains("REMOVE") && body.contains("one.flac"), "expected REMOVE: {body}");
    assert!(body.contains("PRUNE"), "expected PRUNE of the now-orphaned track/album: {body}");
}
```

- [ ] **Step 2: Run, verify it fails.**

Run: `cd rust && cargo test --test scan_remove_test 2>&1 | tail -15`
Expected: FAIL — the test compiles and runs (`scan_roots` already takes a log from Task 2), but the deletion sweep / `prune_orphans` don't record anything yet, so the `REMOVE`/`PRUNE` assertions fail (the structural deletion still happens — the file count drops to 0 — but the log lacks those lines).

- [ ] **Step 3: Log the deletion sweep.** In `scan_roots`, replace the sweep loop body so it names files before deleting. Replace:

```rust
    for root in roots {
        let prefix = format!("{}/", root.trim_end_matches('/'));
        conn.execute(
            "DELETE FROM file WHERE scan_epoch != ?1 AND substr(path, 1, ?2) = ?3",
            rusqlite::params![epoch, prefix.chars().count() as i64, prefix],
        )?;
    }
```
with:
```rust
    for root in roots {
        let prefix = format!("{}/", root.trim_end_matches('/'));
        let plen = prefix.chars().count() as i64;
        {
            let mut stmt = conn.prepare(
                "SELECT path FROM file WHERE scan_epoch != ?1 AND substr(path, 1, ?2) = ?3",
            )?;
            let gone = stmt
                .query_map(rusqlite::params![epoch, plen, prefix], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            for path in gone {
                log.record(&Decision::Remove { path });
            }
        }
        conn.execute(
            "DELETE FROM file WHERE scan_epoch != ?1 AND substr(path, 1, ?2) = ?3",
            rusqlite::params![epoch, plen, prefix],
        )?;
    }
```

- [ ] **Step 4: Log orphan prunes.** Change `prune_orphans` to take `&DecisionLog` and name rows before deleting them. New signature + body:

```rust
pub(crate) fn prune_orphans(conn: &Connection, log: &DecisionLog) -> anyhow::Result<()> {
    // Name orphaned tracks/albums/artists before deleting (child-first as before).
    {
        let mut stmt = conn.prepare(
            "SELECT t.title, COALESCE(r.title, '') FROM track t \
             LEFT JOIN release r ON r.mbid = t.release_mbid \
             WHERE t.id NOT IN (SELECT track_id FROM file)",
        )?;
        for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (title, album) = row?;
            log.record(&Decision::PruneTrack { title, album });
        }
    }
    {
        let mut stmt = conn.prepare(
            "SELECT r.title, COALESCE(a.name, '') FROM release r \
             LEFT JOIN artist a ON a.mbid = r.album_artist_mbid \
             WHERE r.mbid NOT IN (SELECT release_mbid FROM track)",
        )?;
        for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (title, artist) = row?;
            log.record(&Decision::PruneAlbum { title, artist });
        }
    }
    {
        let mut stmt = conn.prepare(
            "SELECT name FROM artist \
             WHERE mbid NOT IN (SELECT album_artist_mbid FROM release WHERE album_artist_mbid IS NOT NULL)",
        )?;
        for row in stmt.query_map([], |r| r.get::<_, String>(0))? {
            log.record(&Decision::PruneArtist { name: row? });
        }
    }

    conn.execute("DELETE FROM track_stats WHERE track_id NOT IN (SELECT track_id FROM file)", [])?;
    conn.execute("DELETE FROM track WHERE id NOT IN (SELECT track_id FROM file)", [])?;
    conn.execute("DELETE FROM release WHERE mbid NOT IN (SELECT release_mbid FROM track)", [])?;
    conn.execute(
        "DELETE FROM release_group WHERE mbid NOT IN (SELECT release_group_mbid FROM release WHERE release_group_mbid IS NOT NULL)",
        [],
    )?;
    conn.execute(
        "DELETE FROM artist WHERE mbid NOT IN (SELECT album_artist_mbid FROM release WHERE album_artist_mbid IS NOT NULL)",
        [],
    )?;
    Ok(())
}
```

- [ ] **Step 5: Log artist merges.** Change `reconcile_album_artists` to take `&DecisionLog` and record each synth→real re-point that actually moves rows. Update its signature to `pub fn reconcile_album_artists(conn: &Connection, log: &DecisionLog) -> anyhow::Result<()>` and inside the `for (mbid, name) in &reals` loop, log when the UPDATE affected rows:

```rust
    for (mbid, name) in &reals {
        let synth_key = format!("synth:aa:{}", ids::normalize(name));
        let moved = tx.execute(
            "UPDATE release SET album_artist_mbid = ?1 WHERE album_artist_mbid = ?2",
            rusqlite::params![mbid, synth_key],
        )?;
        if moved > 0 {
            log.record(&Decision::Merge {
                synth_name: name.clone(),
                real_name: name.clone(),
                real_mbid: mbid.clone(),
            });
        }
    }
```

- [ ] **Step 6: Update the three call sites + signatures threading.** In `scan_roots`, the calls become `reconcile_album_artists(conn, log)?;` and `prune_orphans(conn, log)?;`. In `reread_track_tags`, likewise pass `log`. Then fix every other caller:

Run: `cd /home/autarch/projects/olivier && grep -rn 'prune_orphans(\|reconcile_album_artists(' rust/src rust/tests | grep -v 'fn prune_orphans\|fn reconcile_album_artists'`

For each, pass a log (`&DecisionLog::to_path(None)` in tests that don't assert log output; the real `log` in `scan_roots`/`reread_track_tags`). Show each edit.

- [ ] **Step 7: Run, verify it passes.**

Run: `cd rust && cargo test --test scan_remove_test 2>&1 | tail -6` → PASS.
Then `cd rust && cargo test 2>&1 | tail -3` → full suite green (existing `reconcile`/`prune` tests updated to pass a disabled log).

- [ ] **Step 8: Commit.**

```bash
cd rust && cargo fmt && cd ..
git -C /home/autarch/projects/olivier add rust/src/catalog/scan.rs rust/tests/scan_remove_test.rs
# plus any caller/test files Step 6 touched
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Log REMOVE / PRUNE / MERGE scan decisions

The deletion sweep and prune_orphans enumerate affected paths/entities
before deleting; reconcile_album_artists records each synth->real merge.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Dart import-log providers + viewer page

**Files:**
- Create: `lib/state/import_log.dart` (path + read/clear seams)
- Create: `lib/settings/import_log_page.dart`
- Test: `test/import_log_page_test.dart`

- [ ] **Step 1: Write the failing test.** Create `test/import_log_page_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/settings/import_log_page.dart';
import 'package:olivier/state/import_log.dart';

void main() {
  testWidgets('renders the log contents and Clear empties it', (tester) async {
    var contents = '=== Scan /m @ 2026-06-19 ===\nADD     track "T" — A\n';
    var cleared = false;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        importLogFnProvider.overrideWithValue(() async => contents),
        clearImportLogFnProvider.overrideWithValue(() async {
          cleared = true;
          contents = '';
        }),
      ],
      child: const MaterialApp(home: ImportLogPage()),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('ADD     track "T" — A'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear log'));
    await tester.pump();
    await tester.pump();

    expect(cleared, isTrue);
  });

  testWidgets('shows an empty state when the log is empty', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        importLogFnProvider.overrideWithValue(() async => ''),
        clearImportLogFnProvider.overrideWithValue(() async {}),
      ],
      child: const MaterialApp(home: ImportLogPage()),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('No import activity'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run, verify it fails.**

Run: `timeout 180 mise exec -- flutter test test/import_log_page_test.dart 2>&1 | tail -12`
Expected: FAIL — `import_log.dart` / `import_log_page.dart` (and the providers) don't exist.

- [ ] **Step 3: Create the providers/seams.** Create `lib/state/import_log.dart`:

```dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/providers.dart';

/// Path of the decision log: a sibling of the SQLite DB. Matches the Rust side
/// (`DecisionLog::for_db` → `<dir>/import-log.log`).
final importLogPathProvider = Provider<String>((ref) {
  final db = ref.watch(dbPathProvider);
  return '${File(db).parent.path}/import-log.log';
});

/// Reads the whole decision log (empty string if it doesn't exist yet).
/// Injectable so the viewer is testable without a real file.
typedef ImportLogFn = Future<String> Function();

final importLogFnProvider = Provider<ImportLogFn>((ref) {
  final path = ref.watch(importLogPathProvider);
  return () async {
    final f = File(path);
    if (!await f.exists()) return '';
    return f.readAsString();
  };
});

/// Truncates the decision log to empty.
typedef ClearImportLogFn = Future<void> Function();

final clearImportLogFnProvider = Provider<ClearImportLogFn>((ref) {
  final path = ref.watch(importLogPathProvider);
  return () async {
    final f = File(path);
    if (await f.exists()) await f.writeAsString('');
  };
});
```

- [ ] **Step 4: Create the page.** Create `lib/settings/import_log_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/import_log.dart';

/// Read-only, copy-pasteable view of the import decision log, newest run at the
/// bottom (the view opens scrolled to the end). Backed by [importLogFnProvider].
class ImportLogPage extends ConsumerStatefulWidget {
  const ImportLogPage({super.key});

  @override
  ConsumerState<ImportLogPage> createState() => _ImportLogPageState();
}

class _ImportLogPageState extends ConsumerState<ImportLogPage> {
  late Future<String> _log;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _log = ref.read(importLogFnProvider)();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = ref.watch(importLogPathProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => setState(_reload),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: () async {
              await ref.read(clearImportLogFnProvider)();
              if (mounted) setState(_reload);
            },
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _log,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final text = snap.data ?? '';
          if (text.trim().isEmpty) {
            return const Center(
              child: Text('No import activity logged yet.',
                  style: TextStyle(color: Colors.grey)),
            );
          }
          // Open scrolled to the bottom (newest run) after layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(path, style: Theme.of(context).textTheme.bodySmall),
              ),
              const Divider(height: 1),
              Expanded(
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      text,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 5: Run, verify it passes.**

Run: `timeout 180 mise exec -- flutter test test/import_log_page_test.dart 2>&1 | tail -8` → PASS (2 tests). Then the FULL `timeout 400 mise exec -- flutter test 2>&1 | tail -3` (no regressions) + `mise exec -- precious lint --all 2>&1 | tail -3` (clean).

- [ ] **Step 6: Commit.**

```bash
git -C /home/autarch/projects/olivier add lib/state/import_log.dart lib/settings/import_log_page.dart test/import_log_page_test.dart
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Add the import-log viewer page + file-read/clear seams

Reads import-log.log directly via dart:io behind injectable seams;
scrollable copy-pasteable view with refresh + Clear.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Settings entry → import-log page

**Files:**
- Modify: `lib/settings/settings_page.dart` (add an "Import log" section)
- Test: `test/settings_import_log_nav_test.dart`

- [ ] **Step 1: Write the failing test.** Create `test/settings_import_log_nav_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/settings/import_log_page.dart';
import 'package:olivier/settings/settings_page.dart';
import 'package:olivier/state/import_log.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';

void main() {
  testWidgets('Settings has an Import log entry that opens the page',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        listRootsFnProvider.overrideWithValue(() async => <String>[]),
        importLogFnProvider.overrideWithValue(() async => ''),
        clearImportLogFnProvider.overrideWithValue(() async {}),
      ],
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pumpAndSettle();

    final entry = find.text('Import log');
    expect(entry, findsOneWidget);

    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(ImportLogPage), findsOneWidget);
  });
}
```

NOTE: the `ProviderScope` overrides must satisfy whatever `SettingsPage` reads at build (it watches `scanControllerProvider`, `enrichControllerProvider`, `languageLeadsProvider`, plus the roots / get-setting seams). Inspect those and override the minimum needed so the page builds without FFI — model the overrides on an existing test that pumps `SettingsPage` or those controllers (search `test/`). The `listRootsFnProvider` override above is a GUESS — use the real seam name. If fully constructing `SettingsPage` in a test proves fiddly, it is acceptable to instead assert only that the `'Import log'` `ListTile` renders (dropping the tap/navigation), or to extract the Diagnostics section into a tiny widget and test that directly. The goal stays: prove the entry exists and routes to `ImportLogPage`.

- [ ] **Step 2: Run, verify it fails.**

Run: `timeout 180 mise exec -- flutter test test/settings_import_log_nav_test.dart 2>&1 | tail -12`
Expected: FAIL — no "Import log" entry in Settings (`findsNothing`).

- [ ] **Step 3: Add the Settings section.** In `lib/settings/settings_page.dart`, add the import:

```dart
import 'package:olivier/settings/import_log_page.dart';
```
Then, in the `ListView`'s `children`, AFTER the "Display" section's `SegmentedButton<LanguageLeads>(…)` (the last child) add:

```dart
          const SizedBox(height: 24),
          Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Import log'),
            subtitle: const Text(
              'What the scanner and enricher decided — de-dupe, removals, failures.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ImportLogPage()),
            ),
          ),
```

- [ ] **Step 4: Run, verify it passes.**

Run: `timeout 180 mise exec -- flutter test test/settings_import_log_nav_test.dart 2>&1 | tail -8` → PASS. Then `timeout 400 mise exec -- flutter test 2>&1 | tail -3` (full suite) + `mise exec -- precious lint --all 2>&1 | tail -3` (clean) + `timeout 400 mise exec -- flutter build linux --debug 2>&1 | tail -3` (build OK).

- [ ] **Step 5: Commit.**

```bash
git -C /home/autarch/projects/olivier add lib/settings/settings_page.dart test/settings_import_log_nav_test.dart
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Add a Diagnostics > Import log entry to Settings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (after all tasks)

```
cd /home/autarch/projects/olivier/rust && cargo test 2>&1 | tail -5
cd /home/autarch/projects/olivier && mise exec -- flutter test 2>&1 | tail -3
cd /home/autarch/projects/olivier && mise exec -- precious lint --all 2>&1 | tail -3
cd /home/autarch/projects/olivier && mise exec -- flutter build linux --debug 2>&1 | tail -3
```

All green → final holistic review, then `superpowers:finishing-a-development-branch`.

## Notes

- **No bridge regen** in Phase 1 — `DecisionLog` is internal Rust; the viewer reads the file in Dart.
- Phase 2 (MusicBrainz/enrich decisions: FETCH/CACHE/APPLY/NOMATCH) is a separate plan, written against this `DecisionLog` API after Phase 1 merges.
- The `Decision` enum already includes the variants Phase 1 uses; Phase 2 adds MB-specific recording (likely free-form `record` lines or new variants).
