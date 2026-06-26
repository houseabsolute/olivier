# On-Demand New-File Detection — Design Spec

**Date:** 2026-06-26
**Status:** Approved in brainstorming — pending spec review

## Goal

Add a "Check for new music" action that imports files newly added to the
already-known root folders, **without** reprocessing files the catalog already
knows. It is dramatically cheaper than "Rescan all" on a large, mostly-unchanged
library because it skips the per-file `stat` + per-file DB round-trips + the
deletion sweep that a full rescan performs.

## Background

`scan_roots` (`rust/src/catalog/scan.rs`) does a full pass: walk each root with
the `ignore` walker, and for **every** audio file: `std::fs::metadata` (a `stat`
syscall for mtime/size) + `SELECT mtime, size FROM file WHERE path = ?`; if
unchanged → `UPDATE file SET scan_epoch`; if changed/new → `read_tags` +
`upsert_file`. Afterward a **deletion sweep** prunes files not seen this epoch
(`DELETE FROM file WHERE scan_epoch != ?`), then `reconcile_album_artists` +
`prune_orphans`. The streaming FFI is `scan_library(db_path, roots, sink)`
(`rust/src/api/catalog.rs`) → `scan_roots`, emitting `ScanProgress { files_seen,
files_changed, current, done }`.

`ScanController` (`lib/state/scan_controller.dart`) serializes scans through a
`List<String> _queue` of roots (SQLite is single-writer), draining one root per
`scanLibrary(roots: [root])` call; `rescanAll()` enqueues every root, `addFolder`
enqueues a new one, `removeFolder` drops a root from the queue. Settings has a
"Rescan all" `OutlinedButton` → `rescanAll()` (`settings_page.dart:60-67`).

**Performance note (the walk is required and cheap):** finding new files on
demand requires enumerating the tree (`readdir` per directory) — the only way to
avoid that is filesystem watching, which is out of scope. `readdir` is OS-cached
and, via `walkdir`'s `d_type`, recurses **without** stat-ing files. What
new-only eliminates is the expensive *per-file* work (the `stat`, the DB query,
the `scan_epoch` write, the sweep) for known files. A directory-mtime
optimization was rejected: adding a file to `/a/b` doesn't bump `/a`'s mtime, so
subtrees can't be pruned safely, and new-only's per-file cost is already just an
in-memory set lookup.

## Decision

"Check for new music" is **additive only**: import files whose path is not
already in the catalog; skip known paths entirely (no stat, no modify-detection);
no deletion sweep. Modified-tag files and deleted files remain the job of
"Rescan all" (unchanged).

## Architecture

### 1. Rust — `new_only` mode (`rust/src/catalog/scan.rs`)

Add a `new_only: bool` parameter to `scan_roots`. When `true`:
- Before the walk, load the catalog's known paths once into a
  `std::collections::HashSet<String>` (`SELECT path FROM file`).
- In the per-file loop, after the audio-extension filter: if the path is in the
  set → `files_seen += 1`, emit progress, and `continue` **before** the
  `std::fs::metadata` call (so no `stat`, no DB query, no `scan_epoch` write for
  known files). Otherwise the file is new → run the existing stat + `read_tags` +
  `upsert_file` path (the cache-check branch is skipped for new files since
  there's nothing cached).
- After the walk: run `reconcile_album_artists` (new files may add `synth:` album
  artists to merge), and **skip** the deletion sweep + `prune_orphans` (nothing
  was removed).

`scan_roots`'s existing logic, error handling (per-file `read_tags` failure logs
+ continues), and progress emission are reused; only the known-skip and the
post-walk sweep branch on `new_only`.

### 2. FFI (`rust/src/api/catalog.rs`)

`scan_library` gains a `new_only: bool` parameter, passed through to
`scan_roots`. Regenerate the bridge (`mise exec -- flutter_rust_bridge_codegen
generate`); the generated `scanLibrary` gains a `newOnly` argument.

### 3. Dart — `ScanController` (`lib/state/scan_controller.dart`)

The scan queue carries a per-job mode. Change `final List<String> _queue` to a
list of records `({String root, bool newOnly})`:
- `_enqueue(String dir, {bool newOnly})` pushes `(root: dir, newOnly: newOnly)`.
- `addFolder` / `rescanAll` enqueue with `newOnly: false`.
- New `findNewFiles()` enqueues every `state.roots` entry with `newOnly: true`.
- `_drain` reads `job.root` / `job.newOnly` and calls
  `scanLibrary(dbPath: db, roots: [job.root], newOnly: job.newOnly)`.
- `removeFolder`'s `_queue.removeWhere((r) => r == dir)` and the "skip a root the
  user removed while queued" check adjust to `job.root`.

A "find new" job thus serializes with any in-flight rescan through the same
queue. Browse views populate live during the scan (the existing scan-live-update
feature) and refresh at the end (existing `_invalidateBrowse` per job).

For testability, introduce two FFI seams (the controller currently calls these
directly): `scanLibraryFnProvider` wrapping `scanLibrary(dbPath, roots, newOnly)`
(the streaming scan) and `listRootsFnProvider` wrapping `listRoots(dbPath)` (so a
test can seed `state.roots` via `loadRoots()` without the FFI). The controller
reads them via `ref`. `enrichControllerProvider` is overridden with a no-op in
the test to avoid the post-drain auto-enrich; `_reconcileSelection` early-returns
when no artist is selected, so the browse providers need no override.

### 4. UI (`lib/settings/settings_page.dart`)

Add a "Check for new music" `OutlinedButton.icon` next to "Rescan all"
(disabled when `scan.roots.isEmpty`) → `findNewFiles()`.

## Edge cases

- **Moved/renamed file** → looks new, imported under the new path; the old path
  lingers until a full "Rescan all" prunes it (acceptable — additive by design).
- **Nothing new** → walk finds only known paths; no writes, no-op.
- **Concurrent with a rescan** → queued (single-writer).
- **Unreadable new file** → logged + skipped (existing per-file error handling),
  doesn't abort the pass.

## Testing

- **Rust** (`rust/tests/`, in-memory rusqlite + temp dir of files): seed the
  catalog from a first full scan; then add a new file, modify a known file's
  mtime/tags, and delete a known file on disk; run `scan_roots(new_only: true)`
  and assert: the new file is inserted; the modified known file is **not** re-read
  (its row unchanged, `scan_epoch` untouched); the deleted-on-disk known file is
  **not** pruned (still in the catalog). Contrast: a `new_only: false` pass then
  applies the modification and prunes the deletion.
- **Dart** (`ScanController` test): with `scanLibraryFnProvider` +
  `listRootsFnProvider` overridden (and `enrichControllerProvider` a no-op),
  `loadRoots()` then `findNewFiles()` drives the scan fn with `newOnly: true` for
  each root; `rescanAll()` drives it with `newOnly: false`. (The drain is
  fire-and-forget, so the test awaits the recorded scan call.)

## Out of scope

- Filesystem watching / automatic detection (this is on-demand).
- Detecting moves/renames as moves, or pruning deleted files (that's "Rescan
  all").
- A directory-mtime walk optimization (rejected above).
