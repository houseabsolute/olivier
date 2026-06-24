# Multi-Artist MBID Sanitization — Design Spec

**Date:** 2026-06-24
**Status:** Approved in brainstorming — pending spec review

## Goal

Stop Olivier from sending malformed MusicBrainz requests (which return HTTP 400 and trigger temporary IP blocks) caused by multi-valued MB-ID tags on split/collaboration releases, and group such releases under a synthetic combined album-artist credit instead of a garbage key.

## Background

A split album like **"k. / Low"** (some tracks by Low, some by k.) is tagged with *two* `MUSICBRAINZ_ALBUMARTISTID` values, which the file stores as one **NUL-joined** string (`uuid1\0uuid2`). `read_tags` (`rust/src/tags.rs`) reads every MB-ID field raw (`vc.get(...)` / freeform atom `data().next()`), so `album_artist_mbid` becomes `"uuid1\0uuid2"`. The scanner passes it to `ids::album_artist_key(Some("uuid1\0uuid2"), name)` → since it's `Some(non-empty)` the raw blob is used as the artist key, and enrichment then fetches `…/artist/uuid1\0uuid2?inc=aliases&fmt=json` → MB's edge proxy returns a generic **400**. A burst of these invalid requests gets the IP **temporarily blocked** (abuse protection — not the normal 1 req/s rate limit, which we honor).

The display is *not* broken — the album already shows as "k. / Low" via the `ALBUMARTIST` name tag (normally the joined credit string); only the malformed *ID* is the problem.

`ids::album_artist_key`/`release_key`/`release_group_key` already fall back to a synthetic `synth:…` key when the MBID is `None`. So dropping a bad MBID to `None` in `read_tags` is enough — the scanner produces the synthetic credit automatically; no scan-key change is needed.

## Decisions (from brainstorming)

- A **multi-value or otherwise-malformed MB-ID is dropped** (`None`) rather than guessed-at. For the album-artist this makes the release group under a synthetic combined credit (`synth:aa:k. / low`) — matching how it's actually credited. (Rejected: "pick the first ID" — files the album under just one of the artists and silently drops the other. Deferred: a full many-to-many model where the split shows under *both* "k." and "Low" — a larger schema + browse-UI feature, not this bug fix.)
- **Never send a non-UUID to MusicBrainz** — defense-in-depth so existing bad rows (and any future regression) can't cause 400s / IP blocks.

## Architecture

### `rust/src/catalog/ids.rs`
- `pub fn is_mbid(s: &str) -> bool` — true iff `s` is UUID-shaped (36 chars, hex with `-` at positions 8/13/18/23). Shared by the tag cleaner and the enrich guard.

### `rust/src/tags.rs` (`read_tags`)
- `clean_mbid(raw: Option<String>) -> Option<String>`: trim; if the value contains `\0` (multi-value) → `None`; otherwise keep it only if `is_mbid` — else `None`.
- `clean_credit(raw: Option<String>) -> Option<String>`: if the value contains `\0`, join the non-empty parts with `" / "` (so a NUL-joined *name* like `k.\0Low` displays + keys as `k. / Low`); otherwise unchanged.
- Apply at the **end of `read_tags`**, once, covering every format: `clean_mbid` to all six `*_mbid` fields (`recording_mbid`, `release_mbid`, `release_group_mbid`, `artist_mbid`, `album_artist_mbid`, `release_track_mbid`); `clean_credit` to `album_artist` and `artist`.

### `rust/src/enrich/run.rs` (`enrich_lists`)
- In the artist and release loops, after the existing `is_real_mbid` (synth/empty) check, **skip + log** a non-UUID MBID without querying MB: `if !is_mbid(mbid) { log.line("ERROR", "<entity> <mbid>: malformed MBID (multi-value?), skipping — not queried"); error_count += 1; continue; }`. Do **not** push to the circuit-breaker's `error_times` (this is a local data issue, not an MB error, so it must not abort the pass). It still counts toward `error_count` so a single-entity re-fetch of a malformed entity surfaces as `Err` (per the error-surfacing feature).

### Healing existing data
The enrich guard stops the 400s/blocking immediately for the garbage rows already in the DB (they're skipped, never queried), and the album already displays as "k. / Low". Re-reading tags (the album right-click) or a re-scan re-parses the affected releases to the clean synthetic key and the old garbage artist row is pruned by the existing orphan sweep. No data migration is required.

## Edge cases

- **Single valid UUID** — kept unchanged (the normal case; no behavior change).
- **NUL-joined name** — `clean_credit` joins to "k. / Low"; an already-joined name is unchanged.
- **Synthetic combined album-artist** gets no MB *artist* enrichment (there's no single MBID), but the release dates and per-track recording alts still enrich via their own IDs. Acceptable.
- **Right-click "Re-fetch" on a synth/garbage album-artist** — the guard skips it; for the single-entity path this surfaces as a "re-fetch failed — see Activity & errors" (it has no queryable MB id), rather than a silent no-op.
- A non-album-artist field (recording/release/etc.) is single-valued in practice; `clean_mbid` is still applied defensively (a malformed value → `None` → that link is simply absent).

## Testing

- **`is_mbid`**: accepts a real UUID; rejects a NUL-joined pair, a too-short string, non-hex, and empty.
- **`clean_mbid`**: `"<uuid>"` → `Some(<uuid>)`; `"<uuid1>\0<uuid2>"` → `None`; `"garbage"` → `None`; `" <uuid> "` → `Some(<uuid>)` (trimmed).
- **`clean_credit`**: `"k.\0Low"` → `"k. / Low"`; `"k. / Low"` → unchanged.
- **Enrich guard** (extend `enrich_resilience_test.rs`): seed a release whose `album_artist_mbid` is a NUL-joined pair; run `enrich` with a `FakeHttp` that records calls → that artist is logged + skipped, **no** request is made for the malformed id (`FakeHttp.calls` contains no `…/artist/…\0…` URL), and the pass returns `Ok` (the breaker is not advanced by the skip).

## Out of scope

- Many-to-many album-artists (release under both "k." and "Low").
- Fixing the album-artist *name* when a tagger wrote a multi-value `ALBUMARTIST` that lofty collapsed to its first value (pre-existing; `get_string` returns the first value).
- Auto-migrating existing garbage keys (re-read tags / re-scan handles it).
