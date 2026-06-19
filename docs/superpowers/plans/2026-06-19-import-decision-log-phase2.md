# Import Decision Log — Phase 2 (MusicBrainz/enrich) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Write the enricher's MusicBrainz decisions (FETCH / CACHE / APPLY / NOMATCH) to the same `import-log.log` the scanner already writes (Phase 1), viewable in the existing Settings → Import log page.

**Architecture:** Thread the Phase-1 `DecisionLog` through `enrich/run.rs` (entry points + the shared `enrich_lists` loop + `apply_edition_alts`) and the FFIs. FETCH-vs-CACHE comes from two new read-only `is_cached_*` methods on `MbClient` (run.rs checks them before fetching — so the client's existing fetch signatures, which the tests call directly, are untouched). MB lines use a new free-form `DecisionLog::line(category, detail)`. NO Dart/bridge changes — the Phase-1 viewer already shows the same file.

**Tech Stack:** Rust (rusqlite, tokio, jiff). No Flutter changes.

**Spec:** `docs/superpowers/specs/2026-06-19-import-decision-log-design.md` (the MB rows of the "What's logged" table). Phase 1 (scanner) is already merged.

**Conventions (every task):** Branch `import-log-phase2`. NEVER stage `TODO`/`#TODO#`. `cd rust && cargo fmt` before committing (the linter checks rustfmt). `git -C /home/autarch/projects/olivier` for git. ACTUALLY RUN every command; report real output. Stale IDE diagnostics during multi-file edits are common here — trust `cargo build`/`cargo test`. End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Task 1: Thread the log through enrich + log FETCH/CACHE + the Enrich header

**Files:**
- Modify: `rust/src/decision_log.rs` (add `line`)
- Modify: `rust/src/enrich/client.rs` (add `is_cached_artist`/`is_cached_release`)
- Modify: `rust/src/enrich/run.rs` (thread `&DecisionLog`; header; FETCH/CACHE)
- Modify: `rust/src/api/enrich.rs` (FFIs construct the log)
- Modify: `rust/tests/enrich_test.rs` (pass a log at every `enrich`/`enrich_artist`/`enrich_album` call; new log test)

- [ ] **Step 1: Write the failing test.** Add this `#[tokio::test]` to `rust/tests/enrich_test.rs` (it mirrors the existing tier-1 reading test's seeding + `FakeHttp` + `artist_url()` + the `ARTIST_MBID`/`RELEASE_MBID` constants already in that file — reuse them):

```rust
#[tokio::test]
async fn enrich_logs_a_header_and_fetch_decision() {
    use rust_lib_olivier::decision_log::DecisionLog;
    use tempfile::TempDir;

    let conn = open(":memory:").unwrap();
    conn.execute(
        &format!("INSERT INTO artist(mbid,name,sort_name) VALUES ('{ARTIST_MBID}','椎名林檎','Sheena, Ringo')"),
        [],
    )
    .unwrap();
    conn.execute(
        &format!("INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('{RELEASE_MBID}','{ARTIST_MBID}','無罪モラトリアム')"),
        [],
    )
    .unwrap();
    conn.execute(
        &format!("INSERT INTO track(release_mbid,disc,position,title) VALUES ('{RELEASE_MBID}',1,1,'歌舞伎町の女王')"),
        [],
    )
    .unwrap();
    // enriched=1 so only the ARTIST is processed (no release fetch to mock).
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at,enriched) VALUES ('/m/a.flac',0,0,1,0,1)",
        [],
    )
    .unwrap();

    let artist_body = format!(
        "{{\"id\":\"{ARTIST_MBID}\",\"name\":\"椎名林檎\",\"sort-name\":\"Sheena, Ringo\",\
          \"aliases\":[{{\"name\":\"Ringo Sheena\",\"sort-name\":\"Sheena, Ringo\",\
          \"locale\":\"en\",\"primary\":true,\"type\":\"Artist name\"}}]}}"
    );
    let http = FakeHttp::new().with(&artist_url(), 200, &artist_body);
    let client = rust_lib_olivier::enrich::client::MbClient::new(http);

    let tmp = TempDir::new().unwrap();
    let log_path = tmp.path().join("import-log.log");
    let log = DecisionLog::to_path(Some(log_path.clone()));

    enrich(&conn, &client, false, &log, |_| true).await.unwrap();

    let body = std::fs::read_to_string(&log_path).unwrap();
    assert!(body.contains("=== Enrich library @ "), "got: {body}");
    assert!(body.contains("FETCH"), "first run should FETCH from the network: {body}");
    assert!(body.contains(ARTIST_MBID), "the fetched artist mbid should appear: {body}");
}
```

NOTE: reuse this file's existing `open`, `FakeHttp`, `artist_url`, `ARTIST_MBID`, `RELEASE_MBID` (they're already imported/defined for the other tests). If a name differs, match the existing usage. Tests are `#[tokio::test]`.

- [ ] **Step 2: Run, verify it fails.**

Run: `cd rust && cargo test --test enrich_test enrich_logs_a_header 2>&1 | tail -15`
Expected: FAIL to compile — `enrich` takes 4 args (no `&DecisionLog`); the log param is added in this task.

- [ ] **Step 3: Add `DecisionLog::line`.** In `rust/src/decision_log.rs`, add to the `impl DecisionLog` block (after `record`):

```rust
    /// Record a free-form line (timestamp + padded category + detail). Used by
    /// the enrich pipeline, whose decisions don't map onto the scan `Decision`.
    pub fn line(&self, category: &str, detail: &str) {
        self.write_line(&format!("{}  {:<7} {}", now_local(), category, detail));
    }
```

- [ ] **Step 4: Add cache-presence checks to the client.** In `rust/src/enrich/client.rs`, add to the `impl<H: MbHttp, P: Pacer> MbClient<H, P>` block (e.g. after `browse_release_group`):

```rust
    /// Whether this artist's response is already in `mb_cache` (so the next
    /// enrich serves it without a network fetch). For FETCH/CACHE logging.
    pub fn is_cached_artist(&self, conn: &Connection, mbid: &str) -> bool {
        self.cache_get(conn, "artist", mbid, ARTIST_INC)
            .map(|o| o.is_some())
            .unwrap_or(false)
    }

    /// Whether this release's response is already in `mb_cache`.
    pub fn is_cached_release(&self, conn: &Connection, mbid: &str) -> bool {
        self.cache_get(conn, "release", mbid, RELEASE_INC)
            .map(|o| o.is_some())
            .unwrap_or(false)
    }
```

- [ ] **Step 5: Thread `&DecisionLog` + header + FETCH/CACHE through run.rs.** In `rust/src/enrich/run.rs`:

Add the import:
```rust
use crate::decision_log::DecisionLog;
```

Add `log: &DecisionLog,` as the parameter BEFORE `on_progress` in all four functions, and write a header in each entry point before delegating:

`enrich`:
```rust
pub async fn enrich<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    force: bool,
    log: &DecisionLog,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    let artists = artists_to_enrich(conn, force)?;
    let releases = releases_to_enrich(conn, force)?;
    log.header("Enrich library");
    enrich_lists(conn, client, artists, releases, log, on_progress).await
}
```
`enrich_artist`:
```rust
pub async fn enrich_artist<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    artist_mbid: &str,
    log: &DecisionLog,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    clear_artist_cache(conn, artist_mbid)?;
    let releases = artist_releases(conn, artist_mbid)?;
    log.header(&format!("Enrich artist {artist_mbid}"));
    enrich_lists(conn, client, vec![artist_mbid.to_string()], releases, log, on_progress).await
}
```
`enrich_album`:
```rust
pub async fn enrich_album<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    release_mbid: &str,
    log: &DecisionLog,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    clear_album_cache(conn, release_mbid)?;
    let releases = one_release(conn, release_mbid)?;
    log.header(&format!("Enrich album {release_mbid}"));
    enrich_lists(conn, client, Vec::new(), releases, log, on_progress).await
}
```
`enrich_lists` — add the param and the FETCH/CACHE lines. Change its signature:
```rust
async fn enrich_lists<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    artists: Vec<String>,
    releases: Vec<(String, Option<String>, String)>,
    log: &DecisionLog,
    mut on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
```
In the artist loop, immediately before `let mb = client.fetch_artist(...)`:
```rust
        log.line(
            if client.is_cached_artist(conn, artist_mbid) { "CACHE" } else { "FETCH" },
            &format!("artist {artist_mbid}"),
        );
```
In the release loop, immediately before `let release = client.fetch_release(...)`:
```rust
        log.line(
            if client.is_cached_release(conn, rel_mbid) { "CACHE" } else { "FETCH" },
            &format!("release {rel_mbid}"),
        );
```

- [ ] **Step 6: Update the FFI entry points.** In `rust/src/api/enrich.rs`, add `use crate::decision_log::DecisionLog;` and, in each of `enrich_library`/`enrich_artist`/`enrich_album`, build the log and pass it. e.g. `enrich_library`:
```rust
    let rt = enrich_runtime()?;
    let log = DecisionLog::for_db(&db_path);
    rt.block_on(run::enrich(&conn, &client, force, &log, |p| sink.add(p).is_ok()))
```
and the per-entity ones:
```rust
    let log = DecisionLog::for_db(&db_path);
    rt.block_on(run::enrich_artist(&conn, &client, &artist_mbid, &log, |p| {
        sink.add(p).is_ok()
    }))
```
(`enrich_album` mirrors `enrich_artist`.)

- [ ] **Step 7: Update every test caller.** In `rust/tests/enrich_test.rs`, every `enrich(&conn, &client, false, <closure>)` / `run::enrich_artist(&conn, &client, …, <closure>)` / `enrich_album(…, <closure>)` call (except the new test from Step 1, which already passes its own `&log`) needs `&DecisionLog::to_path(None)` inserted before the closure. Add `use rust_lib_olivier::decision_log::DecisionLog;` at the top. Find them all:

Run: `cd /home/autarch/projects/olivier && grep -nE '[^_]enrich\(&conn|enrich_artist\(&conn|enrich_album\(&conn|run::enrich' rust/tests/enrich_test.rs`

Update each (≈11 sites). Example: `enrich(&conn, &client, false, |_| true)` → `enrich(&conn, &client, false, &DecisionLog::to_path(None), |_| true)`. For the multi-line closure calls, insert `&DecisionLog::to_path(None),` as the 4th argument. Show each edit.

- [ ] **Step 8: Run, verify it passes.**

Run: `cd rust && cargo test --test enrich_test enrich_logs_a_header 2>&1 | tail -6` → PASS. Then `cd rust && cargo test 2>&1 | tail -5` → full suite green (all existing enrich tests now pass a disabled log).

- [ ] **Step 9: Commit.**

```bash
cd rust && cargo fmt && cd ..
git -C /home/autarch/projects/olivier add rust/src/decision_log.rs rust/src/enrich/client.rs rust/src/enrich/run.rs rust/src/api/enrich.rs rust/tests/enrich_test.rs
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Log enrich FETCH/CACHE decisions + run headers

Thread the DecisionLog through the enrich entry points; log an Enrich
header and a FETCH (network) or CACHE (hit) line per artist/release,
using two new read-only is_cached_* client checks.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Log APPLY (and NOMATCH) decisions

**Files:**
- Modify: `rust/src/enrich/run.rs` (log applied transliteration / dates / title-alts; NOMATCH)
- Modify: `rust/tests/enrich_test.rs` (extend the Step-1 test with an APPLY assertion)

- [ ] **Step 1: Strengthen the test.** In `rust/tests/enrich_test.rs`, in `enrich_logs_a_header_and_fetch_decision`, add after the existing assertions:

```rust
    // The chosen en alias is applied as the artist's reading — log it.
    assert!(
        body.contains("APPLY") && body.contains("reading = \"Ringo Sheena\""),
        "expected an APPLY line for the artist reading: {body}"
    );
```

- [ ] **Step 2: Run, verify it fails.**

Run: `cd rust && cargo test --test enrich_test enrich_logs_a_header 2>&1 | tail -8`
Expected: FAIL — the log has FETCH but no `APPLY … reading` line yet.

- [ ] **Step 3: Log the artist APPLY / NOMATCH.** In `rust/src/enrich/run.rs`, in `enrich_lists`'s artist loop, replace:
```rust
        if let Some(chosen) = select_transliteration(&mb) {
            store::apply_artist_transliteration(conn, artist_mbid, &chosen, &mb.name)?;
        }
```
with:
```rust
        if let Some(chosen) = select_transliteration(&mb) {
            store::apply_artist_transliteration(conn, artist_mbid, &chosen, &mb.name)?;
            if chosen.from_entity_sort_name {
                log.line("APPLY", &format!("artist \"{}\": sort name = \"{}\"", mb.name, chosen.sort_name));
            } else {
                log.line("APPLY", &format!("artist \"{}\": reading = \"{}\"", mb.name, chosen.name));
            }
        } else {
            log.line("NOMATCH", &format!("artist \"{}\": no reading from MusicBrainz", mb.name));
        }
```

- [ ] **Step 4: Log the release dates APPLY.** In `enrich_lists`'s release loop, where `store::apply_dates(...)` is called inside the `if let Some(rg) = release.release_group.as_ref()` block, add date logging right after the `apply_dates(...)?;` call:
```rust
            if let Some(d) = rg.first_release_date.as_deref() {
                log.line("APPLY", &format!("release \"{title}\": original date {d}"));
            }
            if let Some(d) = release.date.as_deref() {
                log.line("APPLY", &format!("release \"{title}\": reissue date {d}"));
            }
```

- [ ] **Step 5: Log the title-alts APPLY.** Change `apply_edition_alts` to take the log + the release title and record each applied alt. Update its signature:
```rust
fn apply_edition_alts(
    conn: &Connection,
    release_mbid: &str,
    original_text_rep: Option<&MbTextRepresentation>,
    editions: &[MbRelease],
    log: &DecisionLog,
    title: &str,
) -> anyhow::Result<()> {
```
and replace the per-edition apply block:
```rust
    for ed in ordered {
        let Some(kind) = classify_from_text_representation(ed.text_representation.as_ref()) else {
            continue;
        };
        store::upsert_release_alt(conn, release_mbid, kind, &ed.title)?;
        let mut n_tracks = 0usize;
        for medium in &ed.media {
            for tr in &medium.tracks {
                if let Some(rec) = &tr.recording {
                    store::upsert_track_alt(conn, &rec.id, kind, &tr.title)?;
                    n_tracks += 1;
                }
            }
        }
        let kind_label = match kind {
            crate::enrich::select::AltKind::Translit => "reading",
            crate::enrich::select::AltKind::Translate => "translation",
        };
        log.line(
            "APPLY",
            &format!("release \"{title}\": {kind_label} title \"{}\" (+{n_tracks} track titles)", ed.title),
        );
    }
```
And update its caller in `enrich_lists` to pass `log, title`:
```rust
        apply_edition_alts(&tx, rel_mbid, release.text_representation.as_ref(), &editions, log, title)?;
```

- [ ] **Step 6: Run, verify it passes.**

Run: `cd rust && cargo test --test enrich_test enrich_logs_a_header 2>&1 | tail -6` → PASS. Then `cd rust && cargo test 2>&1 | tail -5` → full suite green, and `mise exec -- precious lint --all 2>&1 | tail -3` → clean.

- [ ] **Step 7: Commit.**

```bash
cd rust && cargo fmt && cd ..
git -C /home/autarch/projects/olivier add rust/src/enrich/run.rs rust/tests/enrich_test.rs
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Log enrich APPLY/NOMATCH decisions

Record each applied artist reading/sort-name, release original/reissue
date, and sibling-edition title-alt (with track count) to the import log;
NOMATCH when an artist yields no usable reading.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (after both tasks)

```
cd /home/autarch/projects/olivier/rust && cargo test 2>&1 | tail -5
cd /home/autarch/projects/olivier && mise exec -- flutter test 2>&1 | tail -3
cd /home/autarch/projects/olivier && mise exec -- precious lint --all 2>&1 | tail -3
```
All green → final holistic review, then `superpowers:finishing-a-development-branch`.

## Notes

- No Dart/bridge changes — the Phase-1 viewer reads the same `import-log.log`.
- FETCH/CACHE is logged at the artist/release level (mbid). Per-browse-page fetches (sibling editions) are not individually logged — the release's own FETCH/CACHE line + its APPLY alt lines cover that release's work.
- A MusicBrainz 404 for an entity still aborts the enrich (the existing `?` behavior) — making enrich resilient like the scanner's FAIL-skip is a possible future enhancement, out of scope here.
