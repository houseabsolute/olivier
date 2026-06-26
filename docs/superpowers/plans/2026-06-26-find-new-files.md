# On-Demand New-File Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Check for new music" action that imports only files new to the catalog (skipping known paths entirely — no per-file stat/DB, no deletion sweep), much cheaper than "Rescan all".

**Architecture:** A `scan_roots_new_only` Rust entry (over a shared private impl with a `new_only` flag) that loads known paths once and skips them before stat-ing, and omits the deletion sweep. A `new_only` param on the `scan_library` FFI. The Dart scan queue carries a per-job mode; a new `findNewFiles()` enqueues roots with `newOnly: true`; a Settings button triggers it.

**Tech Stack:** Rust + rusqlite (+ `tempfile` in tests); flutter_rust_bridge; Flutter + Riverpod.

**Spec:** `docs/superpowers/specs/2026-06-26-find-new-files-design.md`

**Conventions:** Rust tests `cd rust && cargo test`; Flutter `mise exec -- flutter test <path>`; codegen `mise exec -- flutter_rust_bridge_codegen generate`. Run `just lint --all` before each commit. NEVER `git add` the `TODO` file (and don't touch the stray `#TODO#`). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `rust/src/catalog/scan.rs` (modify) — split `scan_roots` into a private impl + two thin wrappers; add the `new_only` branches.
- `rust/tests/scan_new_files_test.rs` (create) — new-only behavior test.
- `rust/src/api/catalog.rs` (modify) — `scan_library` gains `new_only`.
- generated bridge (`rust/src/frb_generated.rs`, `lib/src/rust/**`).
- `lib/state/providers.dart` (modify) — `scanLibraryFnProvider` + `listRootsFnProvider` seams.
- `lib/state/scan_controller.dart` (modify) — per-job queue mode + `findNewFiles()` + use the seams.
- `lib/settings/settings_page.dart` (modify) — "Check for new music" button.
- `test/scan_controller_find_new_test.dart` (create) — mode-threading test.

---

## Task 1: Rust — `scan_roots_new_only`

**Files:**
- Modify: `rust/src/catalog/scan.rs`
- Test: `rust/tests/scan_new_files_test.rs` (create)

- [ ] **Step 1: Write the failing test** — create `rust/tests/scan_new_files_test.rs`:

```rust
use rust_lib_olivier::catalog::scan::{scan_roots, scan_roots_new_only};
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
fn new_only_imports_new_files_and_leaves_known_untouched() {
    let tmp = TempDir::new().unwrap();
    let music = tmp.path().join("music");
    fs::create_dir_all(&music).unwrap();
    let one = music.join("one.flac");
    let adel = music.join("adel.flac");
    fs::copy(fixture("sample.flac"), &one).unwrap();
    fs::copy(fixture("sample.flac"), &adel).unwrap();

    let mut conn = open(":memory:").unwrap();
    let log = DecisionLog::to_path(None);
    let roots = vec![music.to_string_lossy().to_string()];

    // Full scan imports both.
    scan_roots(&mut conn, &roots, &log, |_| {}).unwrap();
    let one_path = one.to_string_lossy().to_string();
    let epoch_before: i64 = conn
        .query_row("SELECT scan_epoch FROM file WHERE path = ?1", [&one_path], |r| r.get(0))
        .unwrap();

    // Add a NEW file; delete a KNOWN one on disk.
    let two = music.join("two.flac");
    fs::copy(fixture("sample.flac"), &two).unwrap();
    fs::remove_file(&adel).unwrap();

    scan_roots_new_only(&mut conn, &roots, &log, |_| {}).unwrap();

    // two.flac imported; adel.flac (deleted on disk) NOT pruned; one.flac kept.
    let mut paths: Vec<String> = {
        let mut s = conn.prepare("SELECT path FROM file").unwrap();
        s.query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    paths.sort();
    let mut want = vec![
        adel.to_string_lossy().to_string(),
        one_path.clone(),
        two.to_string_lossy().to_string(),
    ];
    want.sort();
    assert_eq!(paths, want, "new file imported; deleted-on-disk known file NOT pruned");

    // The known file's row was not reprocessed (scan_epoch untouched).
    let epoch_after: i64 = conn
        .query_row("SELECT scan_epoch FROM file WHERE path = ?1", [&one_path], |r| r.get(0))
        .unwrap();
    assert_eq!(epoch_after, epoch_before, "known file untouched by new-only");
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test --test scan_new_files_test`
Expected: FAIL — `scan_roots_new_only` is not defined.

- [ ] **Step 3: Refactor + add the mode** — in `rust/src/catalog/scan.rs`:

Rename the existing `pub fn scan_roots(` declaration to a private impl with a flag, by changing its signature line from:
```rust
pub fn scan_roots(
    conn: &mut Connection,
    roots: &[String],
    log: &DecisionLog,
    mut on_progress: impl FnMut(ScanProgress),
) -> anyhow::Result<()> {
```
to:
```rust
fn scan_roots_impl(
    conn: &mut Connection,
    roots: &[String],
    log: &DecisionLog,
    mut on_progress: impl FnMut(ScanProgress),
    new_only: bool,
) -> anyhow::Result<()> {
```

Right after `log.header(...);`, load the known-paths set (empty unless new-only):
```rust
    let known: std::collections::HashSet<String> = if new_only {
        let mut stmt = conn.prepare("SELECT path FROM file")?;
        stmt.query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<_, _>>()?
    } else {
        std::collections::HashSet::new()
    };
```

In the per-file loop, immediately after `let path_str = path.to_string_lossy().to_string();` and BEFORE `let meta = std::fs::metadata(...)`, skip known paths without stat-ing:
```rust
            if new_only && known.contains(&path_str) {
                files_seen += 1;
                on_progress(ScanProgress {
                    files_seen,
                    files_changed,
                    current: path_str,
                    done: false,
                });
                continue;
            }
```

Wrap ONLY the deletion-sweep block in `if !new_only`. Change:
```rust
    for root in roots {
        let prefix = format!("{}/", root.trim_end_matches('/'));
        let plen = prefix.chars().count() as i64;
        {
            let mut stmt = conn.prepare(
                "SELECT path FROM file WHERE scan_epoch != ?1 AND substr(path, 1, ?2) = ?3",
            )?;
            let gone = stmt
                .query_map(rusqlite::params![epoch, plen, prefix], |r| {
                    r.get::<_, String>(0)
                })?
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
to wrap that whole `for root in roots { … }` in:
```rust
    if !new_only {
        for root in roots {
            // … unchanged deletion-sweep body …
        }
    }
```
Leave `reconcile_album_artists(conn, log)?;` and `prune_orphans(conn, log)?;` running unconditionally (prune cleans the synthetic-artist rows reconcile orphans; with no files deleted it removes nothing else).

Finally, add the two public wrappers (replace the old `scan_roots` entry point). After the closing `}` of `scan_roots_impl`, add:
```rust
/// Full scan: import new/changed files and prune files gone from disk.
pub fn scan_roots(
    conn: &mut Connection,
    roots: &[String],
    log: &DecisionLog,
    on_progress: impl FnMut(ScanProgress),
) -> anyhow::Result<()> {
    scan_roots_impl(conn, roots, log, on_progress, false)
}

/// Additive scan: import only files whose path isn't already in the catalog;
/// known paths are skipped without a stat, and no deletion sweep runs.
pub fn scan_roots_new_only(
    conn: &mut Connection,
    roots: &[String],
    log: &DecisionLog,
    on_progress: impl FnMut(ScanProgress),
) -> anyhow::Result<()> {
    scan_roots_impl(conn, roots, log, on_progress, true)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd rust && cargo test --test scan_new_files_test` → PASS (1 test).
Run: `cd rust && cargo test` → entire Rust suite green (the ~20 existing `scan_roots(...)` call sites still compile — `scan_roots` keeps its signature).

- [ ] **Step 5: Lint + commit**

Run: `just lint --all` → PASS.
```bash
git add rust/src/catalog/scan.rs rust/tests/scan_new_files_test.rs
git commit -m "$(cat <<'EOF'
Add scan_roots_new_only: import only new files, skip known + no sweep

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: FFI — `scan_library(new_only)` + regen

**Files:**
- Modify: `rust/src/api/catalog.rs`, `lib/state/scan_controller.dart` (one-line compile-fix), generated bridge.

- [ ] **Step 1: Add the param** — in `rust/src/api/catalog.rs`, change `scan_library` to:

```rust
pub fn scan_library(
    db_path: String,
    roots: Vec<String>,
    new_only: bool,
    sink: StreamSink<ScanProgress>,
) -> anyhow::Result<()> {
    let mut conn = db::open(&db_path)?;
    let log = DecisionLog::for_db(&db_path);
    let on_progress = |p| {
        let _ = sink.add(p);
    };
    if new_only {
        scan::scan_roots_new_only(&mut conn, &roots, &log, on_progress)
    } else {
        scan::scan_roots(&mut conn, &roots, &log, on_progress)
    }
}
```

- [ ] **Step 2: Regenerate the bridge**

Run: `mise exec -- flutter_rust_bridge_codegen generate`
Expected: `scanLibrary` in `lib/src/rust/api/catalog.dart` now takes `required bool newOnly`.

- [ ] **Step 3: Keep Dart compiling** — the existing call in `lib/state/scan_controller.dart` (`scanLibrary(dbPath: db, roots: [root])`) now misses `newOnly`. Add `newOnly: false` to it for now (Task 3 replaces this call with the seam):
```dart
          await for (final p in scanLibrary(dbPath: db, roots: [root], newOnly: false)) {
```

- [ ] **Step 4: Verify build + analyze + lint**

Run: `cd rust && cargo build` → success.
Run: `mise exec -- flutter analyze` → no new issues.
Run: `just lint --all` → PASS.

- [ ] **Step 5: Commit** (include generated files)

```bash
git add rust/src/api/catalog.rs rust/src/frb_generated.rs lib/src/rust lib/state/scan_controller.dart
git commit -m "$(cat <<'EOF'
Add new_only param to scan_library FFI + regenerate bridge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Dart — scan seams, per-job queue mode, `findNewFiles()`

**Files:**
- Modify: `lib/state/providers.dart`, `lib/state/scan_controller.dart`
- Test: `test/scan_controller_find_new_test.dart` (create)

- [ ] **Step 1: Write the failing test** — create `test/scan_controller_find_new_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/scan.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';

/// No-op enrich so the post-drain auto-enrich doesn't hit the FFI. Inherits
/// EnrichController.build() (a pure initial-state return); if build() ever does
/// I/O, also override it to return the initial EnrichState.
class _NoopEnrich extends EnrichController {
  @override
  Future<void> enrich({bool force = false, bool clearCache = false}) async {}
}

ScanProgress _done() => ScanProgress(
    filesSeen: BigInt.zero, filesChanged: BigInt.zero, current: '', done: true);

void main() {
  Future<List<({List<String> roots, bool newOnly})>> runAction(
    void Function(ScanController c) action,
  ) async {
    final calls = <({List<String> roots, bool newOnly})>[];
    final called = Completer<void>();
    final container = ProviderContainer(overrides: [
      listRootsFnProvider.overrideWithValue(() async => ['/m']),
      scanLibraryFnProvider.overrideWithValue((roots, newOnly) {
        calls.add((roots: roots, newOnly: newOnly));
        if (!called.isCompleted) called.complete();
        return Stream.value(_done());
      }),
      enrichControllerProvider.overrideWith(_NoopEnrich.new),
    ]);
    addTearDown(container.dispose);

    final c = container.read(scanControllerProvider.notifier);
    await c.loadRoots(); // seeds state.roots = ['/m']
    action(c);
    await called.future;
    await Future<void>.delayed(Duration.zero); // let the drain settle
    return calls;
  }

  test('findNewFiles scans each root with newOnly: true', () async {
    final calls = await runAction((c) => c.findNewFiles());
    expect(calls, [(roots: ['/m'], newOnly: true)]);
  });

  test('rescanAll scans each root with newOnly: false', () async {
    final calls = await runAction((c) => c.rescanAll());
    expect(calls, [(roots: ['/m'], newOnly: false)]);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/scan_controller_find_new_test.dart`
Expected: FAIL — `scanLibraryFnProvider` / `listRootsFnProvider` / `findNewFiles` don't exist.

- [ ] **Step 3: Add the seams** — in `lib/state/providers.dart`, add the import (with the other `package:olivier/src/rust/...` imports):
```dart
import 'package:olivier/src/rust/catalog/scan.dart';
```
and the two seam providers (near the other FFI seams):
```dart
// Streaming library scan seam (so ScanController is testable without the FFI).
typedef ScanLibraryFn = Stream<ScanProgress> Function(
    List<String> roots, bool newOnly);

final scanLibraryFnProvider = Provider<ScanLibraryFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (roots, newOnly) =>
      scanLibrary(dbPath: db, roots: roots, newOnly: newOnly);
});

// Root listing seam (so a test can seed roots via loadRoots() without the FFI).
typedef ListRootsFn = Future<List<String>> Function();

final listRootsFnProvider = Provider<ListRootsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return () => listRoots(dbPath: db);
});
```
(`scanLibrary` and `listRoots` are already available via the existing
`package:olivier/src/rust/api/catalog.dart` import in this file.)

- [ ] **Step 4: Rework the controller** — in `lib/state/scan_controller.dart`:

Change the queue field:
```dart
  final List<String> _queue = [];
```
to:
```dart
  final List<({String root, bool newOnly})> _queue = [];
```

`loadRoots`: replace
```dart
    final db = ref.read(dbPathProvider);
    final persisted = await listRoots(dbPath: db);
```
with
```dart
    final persisted = await ref.read(listRootsFnProvider)();
```

`_enqueue`: change
```dart
  void _enqueue(String dir) {
    _queue.add(dir);
    state = state.copyWith(queued: _queue.length);
    unawaited(_drain());
  }
```
to
```dart
  void _enqueue(String dir, {required bool newOnly}) {
    _queue.add((root: dir, newOnly: newOnly));
    state = state.copyWith(queued: _queue.length);
    unawaited(_drain());
  }
```

Update the `_enqueue` callers: in `addFolder`, `_enqueue(dir)` → `_enqueue(dir, newOnly: false)`. In `rescanAll`, `_enqueue(r)` → `_enqueue(r, newOnly: false)`. Add a new method next to `rescanAll`:
```dart
  /// Scan every known root for files NOT already in the catalog, skipping
  /// known files entirely (no per-file stat/DB, no deletion sweep).
  void findNewFiles() {
    for (final r in state.roots) {
      _enqueue(r, newOnly: true);
    }
  }
```

`removeFolder`: change `_queue.removeWhere((r) => r == dir);` to
`_queue.removeWhere((j) => j.root == dir);`.

`_drain`: remove the now-unused `final db = ref.read(dbPathProvider);` line; change `final root = _queue.removeAt(0);` to:
```dart
        final job = _queue.removeAt(0);
        final root = job.root;
```
and change the scan call line to use the seam + the job's mode:
```dart
          await for (final p
              in ref.read(scanLibraryFnProvider)([root], job.newOnly)) {
```

- [ ] **Step 5: Run to verify it passes**

Run: `mise exec -- flutter test test/scan_controller_find_new_test.dart` → PASS (2 tests).

- [ ] **Step 6: Full suite + lint**

Run: `mise exec -- flutter test` → entire Dart suite green.
Run: `just lint --all` → PASS (dart-format the new/changed files if flagged, re-stage).

- [ ] **Step 7: Commit**

```bash
git add lib/state/providers.dart lib/state/scan_controller.dart test/scan_controller_find_new_test.dart
git commit -m "$(cat <<'EOF'
Add findNewFiles + per-job scan mode + scan/listRoots seams

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Settings — "Check for new music" button

**Files:**
- Modify: `lib/settings/settings_page.dart`

- [ ] **Step 1: Add the button** — in `lib/settings/settings_page.dart`, in the `Row` that holds "Add folder" / "Rescan all" (around line 60-67), add after the "Rescan all" `OutlinedButton.icon`:

```dart
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.library_add_outlined),
                label: const Text('Check for new music'),
                onPressed: scan.roots.isEmpty
                    ? null
                    : () =>
                        ref.read(scanControllerProvider.notifier).findNewFiles(),
              ),
```

- [ ] **Step 2: Verify**

Run: `mise exec -- flutter analyze` → no new issues.
Run: `mise exec -- flutter test` → green (existing settings tests still pass).
Run: `just lint --all` → PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/settings/settings_page.dart
git commit -m "$(cat <<'EOF'
Add "Check for new music" button to Settings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Definition of Done

- "Check for new music" in Settings imports only files new to the catalog,
  skipping known paths (no per-file stat/DB, no deletion sweep); modified/deleted
  files remain "Rescan all"'s job.
- Serializes with rescans via the same queue; browse views populate live.
- Rust + Dart suites green; `just lint --all` clean.
```
