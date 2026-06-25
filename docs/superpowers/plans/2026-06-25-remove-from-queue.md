# Remove-from-Library → Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a track/album/root is removed from the library, drop its tracks from the live queue too (not just on the next restart).

**Architecture:** A pure `QueueController.removePaths(Set<String>)` op, plus a `reconcileQueueWithCatalog(controller, tracksForPaths)` helper that drops queue paths no longer in the catalog (`trackId == null`). Wired into `runCatalogMutation` (album/track removes, behind a flag) and `ScanController.removeFolder` (root remove).

**Tech Stack:** Flutter + Riverpod 3.x; reuses the existing `tracksForPathsFnProvider` seam and the `FakeQueuePlayer`/`RecordingSaveQueue` test doubles.

**Spec:** `docs/superpowers/specs/2026-06-25-remove-from-queue-design.md`

**Planning refinements (vs the spec's sketch):**
- `reconcileQueueWithCatalog` takes `(QueueController, Future<List<QueueTrack>> Function(List<String>))` instead of `WidgetRef` — so it serves both the widget caller (`runCatalogMutation`, a `WidgetRef`) and the Notifier caller (`ScanController`, whose `ref` is `Ref`), and is unit-testable without a container.
- It lives in `lib/state/queue_provider.dart` (not `catalog_mutation.dart`), so `ScanController` can call it without importing `flutter/material`.

**Conventions:** `mise exec -- flutter test <path>`. Run `just lint --all` before each commit. NEVER `git add` the `TODO` file (and don't touch the stray untracked `#TODO#`). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `lib/audio/queue_controller.dart` (modify) — add `removePaths`.
- `lib/state/queue_provider.dart` (modify) — add `reconcileQueueWithCatalog`.
- `lib/catalog/catalog_mutation.dart` (modify) — `runCatalogMutation` gains a `reconcileQueue` flag.
- `lib/catalog/album_column.dart`, `lib/catalog/track_column.dart` (modify) — pass `reconcileQueue: true` on remove.
- `lib/state/scan_controller.dart` (modify) — reconcile after `removeRoot`.
- `test/queue_controller_ops_test.dart` (modify) — `removePaths` tests.
- `test/reconcile_queue_test.dart` (create) — `reconcileQueueWithCatalog` tests.

---

## Task 1: `QueueController.removePaths`

**Files:**
- Modify: `lib/audio/queue_controller.dart`
- Test: `test/queue_controller_ops_test.dart`

- [ ] **Step 1: Write the failing tests** — append inside `main()` in `test/queue_controller_ops_test.dart` (it already sets up `player`, `saved`, `controller` in `setUp`):

```dart
  test('removePaths drops all matching entries incl. duplicates, mirrors player',
      () async {
    await controller
        .append(['/a.flac', '/b.flac', '/c.flac', '/b.flac', '/d.flac']);

    await controller.removePaths({'/b.flac', '/d.flac'});

    expect(controller.orderedPaths, ['/a.flac', '/c.flac']);
    expect(controller.playOrder, ['/a.flac', '/c.flac']);
    expect(player.sources, ['/a.flac', '/c.flac']);
    // Descending removal: indices 4 (/d), 3 (/b), 1 (/b).
    expect(player.removedIndexes, [4, 3, 1]);
    expect(saved.last!.paths, ['/a.flac', '/c.flac']);
  });

  test('removePaths that empties the queue clears the player', () async {
    await controller.append(['/a.flac', '/b.flac']);

    await controller.removePaths({'/a.flac', '/b.flac'});

    expect(controller.orderedPaths, isEmpty);
    expect(controller.playOrder, isEmpty);
    expect(player.sources, isEmpty);
  });

  test('removePaths is a no-op for an empty set', () async {
    await controller.append(['/a.flac']);
    final removedBefore = player.removedIndexes.length;

    await controller.removePaths({});

    expect(controller.orderedPaths, ['/a.flac']);
    expect(player.removedIndexes.length, removedBefore);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/queue_controller_ops_test.dart`
Expected: FAIL — `removePaths` is not defined.

- [ ] **Step 3: Implement** — in `lib/audio/queue_controller.dart`, add this method right after `removeAt` (just before the `_playerIndexForCanonical` helper):

```dart
  /// Drop every queue entry whose path is in [paths] — e.g. tracks just removed
  /// from the library. Occurrence-aware (all copies go); mirrors each removal to
  /// the player (descending so source indices stay valid). If the
  /// currently-playing source is removed, just_audio advances to the next;
  /// emptying the queue stops playback. No-op for an empty set.
  Future<void> removePaths(Set<String> paths) async {
    if (paths.isEmpty) return;
    for (var i = _playOrder.length - 1; i >= 0; i--) {
      if (paths.contains(_playOrder[i])) {
        _playOrder.removeAt(i);
        await _player.removeAudioSourceAt(i);
      }
    }
    _orderedPaths.removeWhere((p) => paths.contains(p));
    await _persist();
    revision.value++;
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/queue_controller_ops_test.dart`
Expected: PASS (the 3 new tests + the existing ones).

- [ ] **Step 5: Commit**

```bash
git add lib/audio/queue_controller.dart test/queue_controller_ops_test.dart
git commit -m "$(cat <<'EOF'
Add QueueController.removePaths to drop entries by path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Reconcile helper + wiring

**Files:**
- Modify: `lib/state/queue_provider.dart`, `lib/catalog/catalog_mutation.dart`, `lib/catalog/album_column.dart`, `lib/catalog/track_column.dart`, `lib/state/scan_controller.dart`
- Test: `test/reconcile_queue_test.dart` (create)

- [ ] **Step 1: Write the failing test** — create `test/reconcile_queue_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/src/rust/db.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

class _RecordingSaveQueue {
  final List<QueueSnapshot> snapshots = [];
  Future<void> call(QueueSnapshot s) async => snapshots.add(s);
}

QueueTrack _t(String path, {required bool present}) => QueueTrack(
      path: path,
      trackId: present ? 1 : null,
      title: path,
      album: '',
      addedAt: 0,
    );

void main() {
  late FakeQueuePlayer player;
  late QueueController controller;

  setUp(() {
    player = FakeQueuePlayer();
    controller = QueueController.withPlayer(player,
        dbPath: '/x', saveQueue: _RecordingSaveQueue().call);
  });

  test('drops queue paths that are gone from the catalog', () async {
    await controller.append(['/a.flac', '/b.flac', '/c.flac']);

    await reconcileQueueWithCatalog(
      controller,
      (paths) async => [for (final p in paths) _t(p, present: p != '/b.flac')],
    );

    expect(controller.orderedPaths, ['/a.flac', '/c.flac']);
  });

  test('leaves an all-present queue untouched', () async {
    await controller.append(['/a.flac', '/b.flac']);

    await reconcileQueueWithCatalog(
      controller,
      (paths) async => [for (final p in paths) _t(p, present: true)],
    );

    expect(controller.orderedPaths, ['/a.flac', '/b.flac']);
    expect(player.removedIndexes, isEmpty);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/reconcile_queue_test.dart`
Expected: FAIL — `reconcileQueueWithCatalog` is not defined.

- [ ] **Step 3: Add the helper** — in `lib/state/queue_provider.dart`, add this top-level function (after the `tracksForPathsFnProvider` definition). `QueueController` and `QueueTrack` are already imported by this file.

```dart
/// After a catalog removal, drop from the live queue any path no longer in the
/// catalog (a track/album/root just removed). [tracksForPaths] returns one entry
/// per path with `trackId == null` for paths gone from the catalog. Best-effort:
/// callers run it last so a transient read error can't disrupt the removal.
Future<void> reconcileQueueWithCatalog(
  QueueController controller,
  Future<List<QueueTrack>> Function(List<String> paths) tracksForPaths,
) async {
  final paths = controller.orderedPaths;
  if (paths.isEmpty) return;
  final tracks = await tracksForPaths(paths);
  final missing = <String>{
    for (final t in tracks)
      if (t.trackId == null) t.path,
  };
  if (missing.isNotEmpty) await controller.removePaths(missing);
}
```

(If `QueueController` is not yet imported in `queue_provider.dart`, add
`import 'package:olivier/audio/queue_controller.dart';`. `QueueTrack` is already
imported — it's used by the `TracksForPathsFn` typedef in this file.)

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/reconcile_queue_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire `runCatalogMutation`** — in `lib/catalog/catalog_mutation.dart`:

Add an import (with the other `package:olivier/...` imports):
```dart
import 'package:olivier/state/queue_provider.dart';
```
Add the parameter to the function signature (after `required String failureMessage,`):
```dart
  bool reconcileQueue = false,
```
At the very end of the function body, after the success snackbar
(`messenger..clearSnackBars()..showSnackBar(...)`), add:
```dart
  if (reconcileQueue) {
    await reconcileQueueWithCatalog(
      ref.read(queueControllerProvider),
      ref.read(tracksForPathsFnProvider),
    );
  }
```
(`queueControllerProvider` is already available via the existing
`playback_controller.dart` import; `reconcileQueueWithCatalog` +
`tracksForPathsFnProvider` come from the new `queue_provider.dart` import.)

- [ ] **Step 6: Pass the flag at the two remove call sites**

In `lib/catalog/album_column.dart`, in the `onRemove: (_) => runCatalogMutation(` block, add `reconcileQueue: true,` (e.g. right after the `failureMessage:` line):
```dart
              failureMessage: 'Failed to remove "${album.title}"',
              reconcileQueue: true,
```

In `lib/catalog/track_column.dart`, in its `onRemove: (_) => runCatalogMutation(` block:
```dart
                    failureMessage: 'Failed to remove "${track.title}"',
                    reconcileQueue: true,
```

- [ ] **Step 7: Wire root removal** — in `lib/state/scan_controller.dart`:

Add imports (with the other `package:olivier/...` imports):
```dart
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/state/queue_provider.dart';
```
In `removeFolder`, after the existing `await _reconcileSelection();` line, add:
```dart
    await reconcileQueueWithCatalog(
      ref.read(queueControllerProvider),
      ref.read(tracksForPathsFnProvider),
    );
```

- [ ] **Step 8: Verify + lint**

Run: `mise exec -- flutter test` — Expected: entire Dart suite green (existing
album/track remove tests still pass; nothing regressed).
Run: `mise exec -- flutter analyze` — Expected: no new issues (watch for an unused
import or an ambiguous `TracksForPathsFn` — the helper uses an inline function
type, not the typedef name, so there's no clash).
Run: `just lint --all` — Expected: PASS (run `mise exec -- dart format` on changed
files if flagged, then re-stage).

- [ ] **Step 9: Commit**

```bash
git add lib/state/queue_provider.dart lib/catalog/catalog_mutation.dart lib/catalog/album_column.dart lib/catalog/track_column.dart lib/state/scan_controller.dart test/reconcile_queue_test.dart
git commit -m "$(cat <<'EOF'
Drop removed-from-library tracks from the live queue

Add reconcileQueueWithCatalog (drops queue paths whose tracksForPaths lookup
returns trackId == null) and call it after album/track removes (via a
runCatalogMutation flag) and root removes (ScanController.removeFolder), run last
so it can't disrupt the removal's success reporting.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Definition of Done

- Removing a track / album / root from the library immediately drops its tracks
  from the live queue (currently-playing track advances; emptied queue stops).
- A queue path missing on disk but still in the catalog is NOT dropped.
- Full Dart suite green; `just lint --all` clean.
```
