# Scan Live-Update — Design Spec

**Date:** 2026-06-25
**Status:** Approved in brainstorming — pending spec review

## Goal

While a scan is running, refresh the browse columns periodically (every ~50
newly-added/changed tracks) so the library visibly populates as it scans, with
newly-added artists landing in their correct sorted position — instead of the
views staying frozen until the whole scan finishes.

## Background

- **The DB is already live mid-scan.** `scan_roots` (`rust/src/catalog/scan.rs`)
  upserts each changed file in its **own transaction** and commits per file, so
  newly-scanned rows are visible to read queries immediately. Progress is
  streamed per file as `ScanProgress { files_seen, files_changed, current, done }`
  via a `StreamSink`. No Rust changes are needed.
- **The controller only refreshes per folder.** `ScanController`
  (`lib/state/scan_controller.dart`) consumes the stream in
  `await for (final p in scanLibrary(…)) { state = state.copyWith(filesSeen,
  filesChanged); if (p.done) break; }`, and calls `_invalidateBrowse()`
  (`ref.invalidate(artistsProvider/albumsProvider/tracksProvider)`) **after** the
  loop, once per folder. Scanning one large root therefore shows nothing until it
  completes. `state.filesChanged` is reset to 0 at the start of each root.
- **The browse columns flash on reload.** `artist_column.dart`,
  `album_column.dart`, `track_column.dart` each render
  `asyncValue.when(loading: CircularProgressIndicator(), …)` with **no**
  `skipLoadingOnReload`, so invalidating a provider drops the current list and
  shows a spinner until the refetch returns.
- **Sorting + selection are already correct on refetch.** `artistsProvider`
  queries `listArtists` (`ORDER BY sort_name`), so a refetch places new artists
  in order. Selection lives in separate providers (`selectedArtistProvider` holds
  the mbid), so it survives a refetch; album/track columns key off the selection
  and refresh with it.

## Decisions (from brainstorming)

- Refresh cadence: every **50 *changed* files** (new/modified), not files seen —
  so a re-scan with no changes does no mid-scan churn. Plus the existing
  per-folder and post-drain refresh.
- Avoid the spinner flash by keeping the current list visible during reload
  (`skipLoadingOnReload: true`).

## Architecture

### 1. Periodic refresh during the scan (`lib/state/scan_controller.dart`)

In the `await for` loop, track the changed-file count at the last refresh; when
`p.filesChanged` has advanced by ≥ 50 since then, call `_invalidateBrowse()` and
record the new high-water mark. Reset the high-water mark to 0 at the start of
each root (alongside the existing `filesChanged: 0` reset). Respect `_disposed`.

Sketch (exact code in the plan):
```dart
var lastRefreshChanged = 0;
await for (final p in scanLibrary(dbPath: db, roots: [root])) {
  if (_disposed) return;
  state = state.copyWith(filesSeen: p.filesSeen.toInt(), filesChanged: p.filesChanged.toInt());
  if (p.filesChanged - lastRefreshChanged >= kScanRefreshEvery) {
    lastRefreshChanged = p.filesChanged.toInt();
    _invalidateBrowse();
  }
  if (p.done) break;
}
```
`kScanRefreshEvery = 50`. The existing post-loop `_invalidateBrowse()` and the
post-drain `_reconcileSelection()` remain, so the final state is always fully
refreshed and the selection reconciled once at the end.

### 2. No spinner flash (the three browse columns)

Add `skipLoadingOnReload: true` to the `.when(...)` in `artist_column.dart`,
`album_column.dart`, and `track_column.dart`. During a mid-scan invalidation the
provider enters `AsyncLoading` *with* its previous value retained; with this flag
`.when` keeps rendering the previous data instead of the `loading:` branch, then
swaps in the new rows when the refetch completes. Initial (no-data) loads still
show the spinner once.

### 3. Sorting + selection

No code change — covered by the existing `ORDER BY sort_name` query and the
separate selection providers (see Background).

## Edge cases

- **Re-scan with no changes** → `filesChanged` never advances → zero mid-scan
  refreshes (only the cheap per-folder one). ✓
- **A root with < 50 changes** → no mid-scan refresh; the per-folder
  `_invalidateBrowse()` shows the result. ✓
- **Scroll position** → `ListView` preserves its scroll offset across rebuilds;
  rows inserted in sort order above the viewport may shift content. Acceptable
  for a live-populating list (no scroll-anchoring in this scope).
- **Disposal mid-scan** → the loop already returns on `_disposed`; the mid-scan
  refresh is inside that guard.

## Testing

- **`ScanController` unit test** (extend the existing controller tests) with a
  fake scan stream (via the scan-stream seam — confirm one exists or add it in
  the plan):
  - a stream whose `filesChanged` climbs past 50, 100, … asserts the browse
    providers are invalidated *mid-stream* at each threshold (not only at
    `done`) — observed by counting `artistsProvider` refetches via a
    `ProviderContainer` listener or an injected invalidate spy.
  - a no-change stream (`filesChanged` stays 0) asserts **no** mid-scan refresh
    occurs before the final per-folder one.
- **Widget test** (light) confirming a browse column keeps showing its current
  rows (no `CircularProgressIndicator`) when its provider is invalidated while it
  already has data — i.e. `skipLoadingOnReload` is in effect.

## Out of scope

- Scroll-anchoring / "stay on the selected artist" as the list grows.
- Any change to the per-file scan progress bar (already live).
- Rust changes (the DB is already live mid-scan via per-file transactions).
