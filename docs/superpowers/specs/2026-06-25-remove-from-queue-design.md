# Remove-from-Library → Queue — Design Spec

**Date:** 2026-06-25
**Status:** Approved in brainstorming — pending spec review

## Goal

When a track, album, or root folder is removed from the library, drop its tracks
from the **live queue** too (not just on the next app restart). The playlists
half of this is already handled by a foreign-key cascade; this completes the
queue half.

## Background

- The queue is **path-based**: `QueueController` (`lib/audio/queue_controller.dart`)
  holds `_orderedPaths` (canonical) and `_playOrder` (player order, possibly
  shuffled), and persists a `QueueSnapshot` of paths. On startup
  `restoreFromSnapshot` filters out paths whose file is gone — but the **live**
  queue is never updated when the catalog changes mid-session.
- Removal funnels through `DELETE FROM file` in Rust (`remove_track`,
  `remove_album` in `rust/src/catalog/deletes.rs`; `remove_root` in `roots.rs`),
  exposed to Dart via the `removeTrackFn` / `removeAlbumFn` seams and
  `ScanController.removeFolder` (`removeRoot`).
- The album/track context-menu **remove** actions both go through
  `runCatalogMutation` (`lib/catalog/catalog_mutation.dart`), which runs the FFI
  in a try/catch (the success/failure decider) and then does post-commit
  bookkeeping (invalidate browse providers, clear the column selection,
  `_reconcileArtist`, snackbar). `ScanController.removeFolder` runs `removeRoot`
  then `_invalidateBrowse()` + `_reconcileSelection()`.
- A queue→catalog resolution seam already exists:
  `tracksForPathsFnProvider` (`lib/state/queue_provider.dart:31`) →
  `catalog.tracksForPaths(dbPath, paths)`, which returns one `QueueTrack` per
  input path with `trackId == null` when the path is no longer in the catalog.
- `QueueController` already exposes `orderedPaths` (unmodifiable getter),
  `currentCanonicalIndex`, and an occurrence-aware single-entry `removeAt`.

## Decision

Reconcile the queue **after** a catalog removal: drop the queue's paths that are
no longer in the catalog. One uniform mechanism for track/album/root (mirrors the
playlists cascade philosophy) — no resolve-before-delete timing, no fragile
root-prefix matching.

## Architecture

### 1. `QueueController.removePaths(Set<String> paths)`

A pure queue operation (sibling to `removeAt`), no catalog dependency:
- Iterate `_playOrder` **descending**; for each entry whose path is in `paths`,
  `_playOrder.removeAt(i)` and `await _player.removeAudioSourceAt(i)` (descending
  keeps indices valid as sources are removed).
- `_orderedPaths.removeWhere((p) => paths.contains(p))`.
- `await _persist();` and `revision.value++`.
- No-op when `paths` is empty.

Occurrence-aware: all copies of a removed path are dropped (the file is gone).
Playback: removing the currently-playing source lets just_audio advance to the
next source (same behavior `removeAt` relies on); emptying the queue drives
`currentIndexStream` to null so now-playing clears (like `clear()`).

### 2. `reconcileQueueWithCatalog(WidgetRef ref)` (`lib/catalog/catalog_mutation.dart`)

```dart
Future<void> reconcileQueueWithCatalog(WidgetRef ref) async {
  final controller = ref.read(queueControllerProvider);
  final paths = controller.orderedPaths;
  if (paths.isEmpty) return;
  final tracks = await ref.read(tracksForPathsFnProvider)(paths);
  final missing = {
    for (final t in tracks)
      if (t.trackId == null) t.path,
  };
  if (missing.isNotEmpty) await controller.removePaths(missing);
}
```

Reads the live queue paths, asks the catalog which are gone (`trackId == null`),
and drops exactly those. One query per removal. A path missing on disk but still
in the catalog keeps a non-null `trackId`, so it is **not** dropped.

### 3. Wiring

- `runCatalogMutation` gains `bool reconcileQueue = false`. After the post-commit
  bookkeeping **and the success snackbar**, when `reconcileQueue` is true it
  `await reconcileQueueWithCatalog(ref)` — running it last means a transient
  reconcile-read error can neither relabel the committed removal as "Failed" nor
  suppress the success message (the queue self-heals on the next removal or
  restart; any error still surfaces via the global guard). The album and track
  **`onRemove`** call sites pass `reconcileQueue: true`; the re-read-tags callers
  leave it false (paths unchanged).
- `ScanController.removeFolder` calls `await reconcileQueueWithCatalog(ref)` after
  `removeRoot` + `_invalidateBrowse()` (it already has a `ref`).

## Edge cases

- **Currently-playing track removed** → just_audio advances to the next surviving
  source; an emptied queue stops and clears now-playing.
- **Missing-on-disk but still in catalog** → kept (not a library removal).
- **Re-read tags** → `reconcileQueue` stays false; no query, nothing dropped.
- **Empty queue** → `reconcileQueueWithCatalog` early-returns (no query).
- **Reconcile read error** → reconcile runs last (after the success snackbar), so
  a transient `tracksForPaths` error can neither relabel the committed removal as
  failed nor hide the success message; the queue isn't reconciled this time and
  self-heals on the next removal or restart.

## Testing

- **`removePaths`** (extend the `QueueController` tests with their fake player):
  remove a subset incl. duplicates → `orderedPaths`/`playOrder` updated +
  persisted; removing the currently-playing entry advances; removing every path
  empties the queue.
- **`reconcileQueueWithCatalog`** (provider test): seed the queue with known
  paths, override `tracksForPathsFnProvider` to return some with `trackId == null`
  → assert exactly those are dropped, and that an all-present queue is untouched.

## Out of scope

- Auto-reconciling the queue after a rescan's orphan sweep (vanished-on-disk
  files) — still handled on restart; easy to add later by calling the same helper
  post-scan.
- Playlists (already handled by the `playlist_item.path → file(path) ON DELETE
  CASCADE` foreign key).
