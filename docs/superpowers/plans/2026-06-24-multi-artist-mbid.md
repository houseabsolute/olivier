# Multi-Artist MBID Sanitization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Olivier from sending malformed (multi-value / NUL-joined) MBIDs to MusicBrainz — which 400 and trigger IP blocks — by dropping bad MBIDs at tag-read time (split releases group under a synthetic combined credit) and guarding enrich from ever querying a non-UUID.

**Architecture:** Add `is_mbid` (UUID shape) to `catalog/ids.rs`; in `tags.rs::read_tags`, clean every `*_mbid` (drop multi-value/invalid → `None`, which the scanner turns into a `synth:…` credit) and join NUL-bearing credit names; in `enrich/run.rs`, skip + log a non-UUID MBID without querying MB.

**Tech Stack:** Rust (rusqlite). No FFI signature change → no bridge regen.

**Commands:** `cd rust && cargo test`; `just lint --all`.

**Conventions:** NEVER `git add` the `TODO` file. Commit messages: plain imperative + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Task order:** 1 (`is_mbid` + tag sanitization) → 2 (enrich guard).

---

### Task 1: `is_mbid` + tag MBID/credit sanitization

**Files:**
- Modify: `rust/src/catalog/ids.rs` (`is_mbid` + test)
- Modify: `rust/src/tags.rs` (`clean_mbid`, `clean_credit`, apply in `read_tags`, tests)

- [ ] **Step 1: Write the failing tests**

In `rust/src/catalog/ids.rs`, add (to its existing `#[cfg(test)] mod tests`, or create one):

```rust
#[test]
fn is_mbid_accepts_uuid_rejects_garbage() {
    assert!(is_mbid("9e414497-23b7-4ab7-9ec6-8ea9864c9e87"));
    assert!(!is_mbid("9e414497-23b7-4ab7-9ec6-8ea9864c9e87\042faad37-8aaa-42e4-a300-5a7dae79ed24"));
    assert!(!is_mbid("not-a-uuid"));
    assert!(!is_mbid(""));
    assert!(!is_mbid("9e414497-23b7-4ab7-9ec6-8ea9864c9e8")); // 35 chars
    assert!(!is_mbid("9e414497x23b7-4ab7-9ec6-8ea9864c9e87")); // wrong separator
}
```

In `rust/src/tags.rs`, add (to its `#[cfg(test)] mod tests`, or create one — reference the private `clean_mbid`/`clean_credit` via `super::`):

```rust
#[test]
fn clean_mbid_keeps_single_uuid_drops_multi_and_garbage() {
    assert_eq!(
        clean_mbid(Some("9e414497-23b7-4ab7-9ec6-8ea9864c9e87".into())).as_deref(),
        Some("9e414497-23b7-4ab7-9ec6-8ea9864c9e87")
    );
    assert_eq!(
        clean_mbid(Some(" 9e414497-23b7-4ab7-9ec6-8ea9864c9e87 ".into())).as_deref(),
        Some("9e414497-23b7-4ab7-9ec6-8ea9864c9e87")
    );
    // NUL-joined split-release pair -> dropped.
    assert_eq!(
        clean_mbid(Some(
            "04816b1b-e203-4917-b4a1-8c31ced2eb82\042faad37-8aaa-42e4-a300-5a7dae79ed24".into()
        )),
        None
    );
    assert_eq!(clean_mbid(Some("garbage".into())), None);
    assert_eq!(clean_mbid(None), None);
}

#[test]
fn clean_credit_joins_nul_values() {
    assert_eq!(clean_credit(Some("k.\0Low".into())).as_deref(), Some("k. / Low"));
    assert_eq!(clean_credit(Some("k. / Low".into())).as_deref(), Some("k. / Low"));
    assert_eq!(clean_credit(None), None);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd rust && cargo test --lib ids::tests::is_mbid_accepts && cargo test --lib tags::tests::clean_`
Expected: FAIL to compile — `is_mbid`, `clean_mbid`, `clean_credit` don't exist. (Run `cargo test --lib` to compile all; the new tests are the failures.)

- [ ] **Step 3: Add `is_mbid`**

In `rust/src/catalog/ids.rs`, add (alongside `normalize`/`album_artist_key`):

```rust
/// True iff `s` is a syntactically valid MusicBrainz UUID (8-4-4-4-12 hex).
/// Used to reject multi-value / garbage IDs before they reach a request URL.
pub fn is_mbid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, &c)| match i {
            8 | 13 | 18 | 23 => c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
}
```

- [ ] **Step 4: Add the cleaners + apply them in `read_tags`**

In `rust/src/tags.rs`, add the import (with the other `use` lines): `use crate::catalog::ids::is_mbid;`. Add the two helpers (module level, above `read_tags`):

```rust
/// A MusicBrainz ID read from a tag may be multi-valued (several IDs joined by a
/// NUL on a split/collab release) or otherwise malformed; either is unusable as
/// a single MBID and would 400 MusicBrainz, so drop it (the scanner then falls
/// back to a synthetic credit key). A clean single UUID is kept (trimmed).
fn clean_mbid(raw: Option<String>) -> Option<String> {
    let v = raw?;
    if v.contains('\0') {
        return None;
    }
    let t = v.trim();
    is_mbid(t).then(|| t.to_string())
}

/// A credit *name* may also be NUL-joined for multi-artist releases; render it as
/// a single combined credit (e.g. "k. / Low") for display + synthetic keying.
fn clean_credit(raw: Option<String>) -> Option<String> {
    let v = raw?;
    if !v.contains('\0') {
        return Some(v);
    }
    let joined = v
        .split('\0')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" / ");
    (!joined.is_empty()).then_some(joined)
}
```

Then, in `read_tags`, immediately before the final `Ok(out)` (after the format `match`), insert:

```rust
    // Sanitize tag-derived MB IDs + credit names: a multi-valued (NUL-joined)
    // split/collab tag must not yield a malformed MBID (which would 400 MB and
    // risk an IP block) or a NUL-bearing display name. A dropped album-artist
    // MBID becomes a synthetic combined credit via ids::album_artist_key.
    out.recording_mbid = clean_mbid(out.recording_mbid.take());
    out.release_mbid = clean_mbid(out.release_mbid.take());
    out.release_group_mbid = clean_mbid(out.release_group_mbid.take());
    out.artist_mbid = clean_mbid(out.artist_mbid.take());
    out.album_artist_mbid = clean_mbid(out.album_artist_mbid.take());
    out.release_track_mbid = clean_mbid(out.release_track_mbid.take());
    out.artist = clean_credit(out.artist.take());
    out.album_artist = clean_credit(out.album_artist.take());

    Ok(out)
```

- [ ] **Step 5: Run to verify pass; full suite; lint; commit**

Run: `cd rust && cargo test --lib` (the new ids + tags tests pass), `cd rust && cargo test` (FULL suite green — existing tag/scan tests unaffected, since clean values pass through unchanged), `just lint --all` (PASS). Then:

```bash
git add rust/src/catalog/ids.rs rust/src/tags.rs
git commit -m "$(cat <<'EOF'
Sanitize multi-value / malformed MBIDs at tag-read time

is_mbid (UUID shape); clean_mbid drops a NUL-joined or non-UUID id (so a
split release's album-artist becomes a synthetic combined credit) and
clean_credit joins a NUL-bearing name to "k. / Low". Applied to all *_mbid +
artist/album_artist names in read_tags.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Enrich guard — never query a non-UUID MBID

**Files:**
- Modify: `rust/src/enrich/run.rs`
- Test: `rust/tests/enrich_resilience_test.rs` (extend)

- [ ] **Step 1: Write the failing test**

Append to `rust/tests/enrich_resilience_test.rs` (it already has `FakeHttp` (records `calls`), `open`, `DecisionLog`, `MbClient`, `enrich`):

```rust
#[tokio::test]
async fn malformed_mbid_is_skipped_not_queried() {
    let conn = open(":memory:").unwrap();
    // A split-release album-artist stored as two NUL-joined MBIDs (as a tagger
    // encodes "k. / Low") that escaped sanitization / predates the fix.
    let garbage =
        "04816b1b-e203-4917-b4a1-8c31ced2eb82\042faad37-8aaa-42e4-a300-5a7dae79ed24";
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES (?1,'k. / Low','k. / Low')",
        [garbage],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R',?1,'Split')",
        [garbage],
    )
    .unwrap();

    let http = FakeHttp::new(); // records calls; no canned responses
    let client = MbClient::new(http);
    let logdir = std::env::temp_dir().join(format!("olivier_malformed_{}", std::process::id()));
    std::fs::create_dir_all(&logdir).unwrap();
    let log = DecisionLog::to_path(Some(logdir.join("import-log.log")));

    let res = enrich(&conn, &client, true, &log, |_p| true).await;

    assert!(res.is_ok(), "a malformed mbid must be skipped, not abort: {res:?}");
    assert!(
        client.http().calls.borrow().is_empty(),
        "malformed mbid must NOT be queried: {:?}",
        client.http().calls.borrow()
    );
    let logged = std::fs::read_to_string(logdir.join("import-log.log")).unwrap();
    assert!(logged.contains("malformed MBID"), "logged: {logged}");
    std::fs::remove_dir_all(&logdir).ok();
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd rust && cargo test --test enrich_resilience_test malformed_mbid_is_skipped_not_queried`
Expected: FAIL — today the garbage mbid IS queried (`calls` contains a `…/artist/…\0…` URL) and the log has no "malformed MBID" line.

- [ ] **Step 3: Add the guard**

In `rust/src/enrich/run.rs`, add the import (with the other `use crate::...` lines): `use crate::catalog::ids::is_mbid;`.

In the **artist loop**, just after the existing synth/empty check:

```rust
        if !is_real_mbid(artist_mbid) {
            continue;
        }
```

insert:

```rust
        if !is_mbid(artist_mbid) {
            log.line(
                "ERROR",
                &format!(
                    "artist {artist_mbid}: malformed MBID (multi-value?), skipping — not queried"
                ),
            );
            error_count += 1;
            continue;
        }
```

In the **release loop**, at the very top of `for (rel_mbid, _rg_mbid, title) in &releases {` (before the FETCH/CACHE `log.line`):

```rust
    for (rel_mbid, _rg_mbid, title) in &releases {
        if !is_mbid(rel_mbid) {
            log.line(
                "ERROR",
                &format!(
                    "release {rel_mbid} (\"{title}\"): malformed MBID (multi-value?), skipping — not queried"
                ),
            );
            error_count += 1;
            continue;
        }
        // ... existing FETCH/CACHE log.line + the rest of the loop body ...
```

Note: these skips increment `error_count` (so a single-entity re-fetch of a malformed entity surfaces as `Err`) but deliberately do NOT push to the circuit-breaker's `error_times` (a malformed local id is not an MB error and must not abort the pass). Synthetic keys never reach here (`releases_to_enrich`/`artists_to_enrich` already exclude `synth:%`, and the artist loop's `is_real_mbid` check precedes this).

- [ ] **Step 4: Run to verify pass; full suite; lint; commit**

Run: `cd rust && cargo test --test enrich_resilience_test` (now 5 pass — the four existing + the new one), `cd rust && cargo test` (FULL suite green), `just lint --all` (PASS). Then:

```bash
git add rust/src/enrich/run.rs rust/tests/enrich_resilience_test.rs
git commit -m "$(cat <<'EOF'
Guard enrich from querying malformed (non-UUID) MBIDs

A non-UUID album-artist/release MBID already in the catalog (e.g. a NUL-joined
split-release id from before tag sanitization) is logged + skipped without a
MusicBrainz request, so it can't 400 / trigger an IP block. Counts toward the
single-entity re-fetch surface but not the circuit-breaker.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `cd rust && cargo test` — green (incl. the new `ids`/`tags` unit tests + `malformed_mbid_is_skipped_not_queried`).
- [ ] `just lint --all` — PASS.
- [ ] Manual (`just run`): with a split album in the library (e.g. "k. / Low"), enrichment no longer logs `HTTP 400` for that artist (it logs a "malformed MBID … skipping" line instead, or — after Re-read tags / re-scan — the album sits under a synthetic "k. / Low" with no bad request at all). No IP-block-inducing requests.

## Touched files

| File | Change |
|------|--------|
| `rust/src/catalog/ids.rs` | `is_mbid` |
| `rust/src/tags.rs` | `clean_mbid` / `clean_credit` + applied in `read_tags` |
| `rust/src/enrich/run.rs` | skip + log non-UUID MBIDs (no MB query) |
| `rust/src/catalog/ids.rs`, `rust/src/tags.rs`, `rust/tests/enrich_resilience_test.rs` | tests |
