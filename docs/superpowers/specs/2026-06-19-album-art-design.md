# Album Art — Design

**Date:** 2026-06-19
**Status:** Approved design → ready for implementation plan
**Backlog items:** "I can't see album art anywhere" + album Info "album art" (TODO lines 9, 17)
**Out of scope:** album art for every queue row (only the now-playing track gets art); cover-cache invalidation tied to per-entity re-fetch (deferred); full-resolution covers (we use CAA `front-500`).

## Goal

Show album cover art in the browse UI. Today art only reaches the OS via MPRIS (`MediaItem.artUri`); the in-app browse columns render albums as text only. Art is **embedded in the audio files** (already extractable) with a **Cover Art Archive (CAA)** network fallback for files lacking embedded art.

Three surfaces:
1. **Album rows** (`lib/catalog/album_column.dart`) — a small leading thumbnail per album.
2. **Album Info popup** (`lib/widgets/info_dialog.dart`) — a larger cover above the fields.
3. **Queue panel** (`lib/catalog/queue_panel.dart`) — the **currently-playing track's** album art (one image, not per-row).

Resolution order everywhere: **embedded → CAA (by release MBID) → placeholder.**

## What already exists (reused, not rebuilt)

- `rust/src/tags.rs::extract_cover_to(path, cache_dir) -> Option<String>` — extracts the first embedded picture to a hashed cache file (`olivier-cover-{pathhash}.{ext}`), cache-hits on `Path::exists`, handles no-picture / zero-byte → `None`. Exposed as FFI `extract_cover`.
- `rust/src/enrich/http.rs` — `MbHttp` trait (`async fn get(url) -> MbResponse { status: u16, body: String }`) and `ReqwestHttp` (User-Agent `Olivier/<ver> ( <email> )`, default redirect-following). **Body is `String`** — JSON only; CAA returns binary, so a bytes method is added (below).
- `lib/audio/playback_controller.dart::_enrichWithCoverArt` — async, race-guarded, in-memory `_coverCache`; calls `extractCover(filePath, cacheDir)` (embedded only) and sets `MediaItem.artUri`. Cache dir from `getApplicationCacheDirectory()`.
- DB: `release.release_group_mbid` exists; `file.has_cover` boolean per file; tracks key on `release_mbid`.

## Architecture (chosen: one Rust resolver, two thin FFI entry points)

### Cover resolver — new module `rust/src/cover.rs`

Core function:

```
resolve_cover(
    http: &impl MbHttp,
    rep_file: Option<&str>,      // representative audio file for embedded art
    release_mbid: &str,
    rg_mbid: Option<&str>,       // release-group, for the CAA fallback
    cache_dir: &str,
) -> anyhow::Result<Option<String>>   // path to a cached image, or None
```

Waterfall:
1. **Embedded** — if `rep_file` is `Some`, call `extract_cover_to(rep_file, cache_dir)`. Hit → return its path.
2. **CAA disk cache** — if `olivier-caa-{release_mbid}.{ext}` exists (any sniffed ext), return it.
3. **Negative cache** — if `olivier-caa-{release_mbid}.miss` exists, return `None` (no network).
4. **CAA network** — `GET https://coverartarchive.org/release/{release_mbid}/front-500`. On HTTP 200 with non-empty bytes → sniff ext from magic bytes (JPEG `FF D8`, PNG `89 50 4E 47`; default `jpg`), write `olivier-caa-{release_mbid}.{ext}`, return its path. On non-200, and if `rg_mbid` is `Some`, retry `…/release-group/{rg_mbid}/front-500`.
5. **Miss** — write the empty `olivier-caa-{release_mbid}.miss` sentinel, return `None`.

The resolver never panics on network/IO error; any error degrades to `None` (logged, not propagated to the UI). CAA uses no MB pacer (separate CDN); a single attempt per endpoint.

### HTTP: extend `MbHttp` with a bytes method

Add `async fn get_bytes(&self, url: &str) -> anyhow::Result<(u16, Vec<u8>)>` to the `MbHttp` trait. `ReqwestHttp` implements it via `resp.bytes()` with the same User-Agent header and redirect-following. A fake implementing `MbHttp` (serving registered byte bodies keyed by URL) makes the resolver testable without the network. Existing `get` (String) is untouched. *(Note: the enrich `FakeHttp` lives in `rust/tests/enrich_test.rs`; the plan either lifts a shared fake into a test module both suites use, or `cover_test.rs` defines its own minimal `MbHttp` fake — whichever is less disruptive. Adding `get_bytes` to the trait forces every existing `MbHttp` impl, including that fake, to gain the method.)*

### FFI entry points — `rust/src/api/cover.rs`

Both sync (frb worker thread) using `block_on` + `ReqwestHttp::new(env!("CARGO_PKG_VERSION"), &email)` where `email = settings::get_setting_or_default(conn, "mb_contact_email")` (mirrors `api/enrich.rs`):

- `cover_for_release(db_path: String, release_mbid: String, cache_dir: String) -> Option<String>`
  Opens the DB, looks up a representative file (`SELECT MIN(f.path) FROM track t JOIN file f ON f.track_id = t.id WHERE t.release_mbid = ?1`) and `release_group_mbid` (`SELECT release_group_mbid FROM release WHERE mbid = ?1`), then `resolve_cover`. *(album rows + Info popup)*
- `cover_for_path(db_path: String, file_path: String, cache_dir: String) -> Option<String>`
  Resolves `release_mbid`/`rg_mbid` for the file (`file → track → release`), uses `file_path` itself as `rep_file`, then `resolve_cover`. *(now-playing track in the queue; also the playback/MPRIS path)*

Both swallow "row not found" into `None` (e.g. a queued file no longer in the catalog).

## Flutter

### Seams (injectable for host-VM tests)
- `coverForReleaseFnProvider` — `typedef CoverForReleaseFn = Future<String?> Function(String releaseMbid)`, default wraps the FFI with the resolved cache dir.
- `coverForPathFnProvider` — `typedef CoverForPathFn = Future<String?> Function(String filePath)`.
- `coverCacheDirProvider` — resolves `getApplicationCacheDirectory().path` once (same dir as playback, so the embedded cache is shared).

### Cached providers
- `albumCoverProvider = FutureProvider.family<String?, String>((ref, releaseMbid) => ref.read(coverForReleaseFnProvider)(releaseMbid))` — `ref.keepAlive()` so a resolved cover is not re-fetched on scroll-back.
- `nowPlayingCoverProvider` — derives the now-playing `QueueTrack` from `queueProvider` (`tracks[currentIndex]`) and resolves via `coverForPathFnProvider`; `null` when nothing is playing.

### Widget
`AlbumCover({required String releaseMbid, required double size})` (and a path-based variant or a shared `_CoverImage`): watches the relevant provider and renders `Image.file(File(path), cacheWidth: …, gaplessPlayback: true)` when a path is present, otherwise a muted placeholder (a rounded `Icons.album` box sized to `size`). Loading and `null` both show the placeholder. A square aspect ratio is enforced (covers are square; CAA `front-500` and embedded art may not be exactly square → `BoxFit.cover` within a clipped square).

### Surfaces wiring
- **Album rows:** a leading `AlbumCover(releaseMbid: a.releaseMbid, size: ~40)` before the `BilingualText` in `album_column.dart`. Row height already comes from `bilingualRowExtent(context, 48)`, which accommodates a ~40px thumbnail.
- **Album Info popup:** extend `showInfoDialog(context, {title, fields, Widget? header})` to render an optional `header` widget above the fields. The album `onInfo` caller passes a ~220px `AlbumCover`. Track Info passes no header (unchanged).
- **Queue now-playing:** the queue panel renders a now-playing `AlbumCover` (via `nowPlayingCoverProvider`) in its header area.
- **MPRIS consolidation:** migrate `_enrichWithCoverArt` from `extractCover(filePath)` to the new `cover_for_path` seam, so OS/MPRIS now-playing gains the CAA fallback for free. Keep the existing race-guard, `_coverCache`, and "never break playback" semantics; the existing playback tests guard this change.

## Error handling

Every failure mode (no representative file, extraction error, network error, non-200, malformed bytes) collapses to `None` → placeholder. Covers never break browse or playback. The `.miss` sentinel bounds CAA traffic so art-less releases are not re-requested on every scroll.

## Testing

**Rust** (`rust/tests/cover_test.rs`), `FakeHttp` extended with `get_bytes`:
1. Embedded present → returns the extracted path; **no** network call.
2. No embedded + CAA `release/.../front-500` → 200 bytes → returns a cached `olivier-caa-*` path; a **second** call is a disk hit (no second fetch).
3. CAA release → 404, `release-group/.../front-500` → 200 → returns the RG cover.
4. Both endpoints miss → `.miss` sentinel written, returns `None`; a second call makes **no** network request.

Fixtures: a sample audio file with an embedded picture (for case 1) and one without (cases 2–4). The resolver takes `&impl MbHttp`, so all cases run offline.

**Dart** (host-VM, no FFI/network): override `coverForReleaseFnProvider` to yield a temp image path or `null`; assert `AlbumCover` renders an `Image` vs the placeholder, and that an album row and the Info popup include the cover widget. Override `coverForPathFnProvider` for the now-playing case.

**Bridge:** regenerate after adding the two FFIs (`flutter_rust_bridge_codegen generate`); commit the regenerated `lib/src/rust/**` + `rust/src/frb_generated.rs`.

## Build order (for the plan)

1. `MbHttp::get_bytes` (+ `ReqwestHttp` impl + `FakeHttp` impl) — unblocks the resolver and its tests.
2. `cover.rs` resolver (`resolve_cover`) with the full waterfall + the four Rust tests.
3. FFI `cover_for_release` / `cover_for_path` (+ bridge regen).
4. Flutter seams + `coverCacheDirProvider` + `albumCoverProvider` + `AlbumCover` widget (+ widget tests).
5. Wire album rows.
6. Extend `showInfoDialog` with `header` + wire album Info cover.
7. Queue now-playing cover (`nowPlayingCoverProvider`) + migrate `_enrichWithCoverArt` to `cover_for_path`.

## Notes / deferred

- **Cache invalidation:** a future pass can clear `olivier-caa-{release_mbid}.*` (incl. `.miss`) when the user re-fetches an album from MusicBrainz (the per-entity re-fetch built earlier).
- **Full-resolution covers:** `front-500` is reused for rows and the ~220px popup. If crisp large covers are wanted later, fetch `front` (full) on demand for the popup.
- **Concurrency:** `itemExtent` lists build only visible rows, so cover resolution is naturally bounded to a screenful; the embedded path is local and CAA fetches only fire for art-less albums. No explicit semaphore in v1.
- Host-VM test rule (as elsewhere): Dart tests run under plain `mise exec -- flutter test`; FFI behind injectable seams; Rust round-trips covered by `rust/tests`.
