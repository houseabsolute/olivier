# Scan Live-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During a scan, refresh the browse columns every ~50 newly-changed files (not just per folder) so the library visibly populates, without flashing a spinner.

**Architecture:** Extract the refresh cadence into a small, pure, unit-testable `ScanRefreshGate` and call it from `ScanController`'s scan loop to invalidate the browse providers mid-scan. Add `skipLoadingOnReload: true` to the three browse columns so a mid-scan invalidation keeps the current list on screen. Sorting + selection are already correct on refetch; no Rust changes.

**Tech Stack:** Flutter + Riverpod 3.x. Tests via `mise exec -- flutter test`. Lint gate: `just lint --all`.

**Spec:** `docs/superpowers/specs/2026-06-25-scan-live-update-design.md`

**Conventions:** `mise exec -- flutter test <path>`. Run `just lint --all` (clippy/rustfmt/dart-format/flutter-analyze) before each commit. NEVER `git add` the `TODO` file (and don't touch the stray untracked `#TODO#`). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `lib/state/scan_refresh_gate.dart` (create) — the pure cadence unit + `kScanRefreshEvery`.
- `lib/state/scan_controller.dart` (modify) — call the gate in the scan loop.
- `lib/catalog/artist_column.dart`, `album_column.dart`, `track_column.dart` (modify) — `skipLoadingOnReload: true`.
- `test/scan_refresh_gate_test.dart`, `test/artist_column_reload_test.dart` (create).

---

## Task 1: Refresh cadence gate + wire into the scan loop

**Files:**
- Create: `lib/state/scan_refresh_gate.dart`
- Modify: `lib/state/scan_controller.dart`
- Test: `test/scan_refresh_gate_test.dart` (create)

- [ ] **Step 1: Write the failing test** — create `test/scan_refresh_gate_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/scan_refresh_gate.dart';

void main() {
  test('fires once per `every` changed files, advancing the mark', () {
    final gate = ScanRefreshGate(50);
    expect(gate.shouldRefresh(10), isFalse);
    expect(gate.shouldRefresh(49), isFalse);
    expect(gate.shouldRefresh(50), isTrue); // crossed 50
    expect(gate.shouldRefresh(75), isFalse); // only 25 since last fire
    expect(gate.shouldRefresh(100), isTrue); // crossed another 50
  });

  test('a no-change scan never fires', () {
    final gate = ScanRefreshGate(50);
    expect(gate.shouldRefresh(0), isFalse);
    expect(gate.shouldRefresh(0), isFalse);
  });

  test('default threshold is kScanRefreshEvery', () {
    final gate = ScanRefreshGate();
    expect(gate.shouldRefresh(kScanRefreshEvery - 1), isFalse);
    expect(gate.shouldRefresh(kScanRefreshEvery), isTrue);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/scan_refresh_gate_test.dart`
Expected: FAIL — `lib/state/scan_refresh_gate.dart` doesn't exist.

- [ ] **Step 3: Create the gate** — `lib/state/scan_refresh_gate.dart`:

```dart
/// How many newly-changed files to scan between live browse-view refreshes.
const kScanRefreshEvery = 50;

/// Gates the periodic browse refresh during a scan: fires once per [every]
/// newly-changed files. Stateful across one root's scan; create a fresh instance
/// per root (the scanner's changed-count restarts at 0 each root).
class ScanRefreshGate {
  ScanRefreshGate([this.every = kScanRefreshEvery]);

  final int every;
  int _last = 0;

  /// True when [changedSoFar] has advanced by at least [every] since this last
  /// returned true (and then advances the high-water mark). A scan with no
  /// new/changed files never fires.
  bool shouldRefresh(int changedSoFar) {
    if (changedSoFar - _last >= every) {
      _last = changedSoFar;
      return true;
    }
    return false;
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/scan_refresh_gate_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Wire it into the scan loop** — in `lib/state/scan_controller.dart`:

Add the import among the `package:olivier/...` imports:
```dart
import 'package:olivier/state/scan_refresh_gate.dart';
```

In `_drain()`, replace this block (the per-root state reset + the scan `try`):
```dart
        state = state.copyWith(
          scanning: true,
          filesSeen: 0,
          filesChanged: 0,
          queued: _queue.length,
          lastError: null,
        );
        try {
          await for (final p in scanLibrary(dbPath: db, roots: [root])) {
            if (_disposed) return;
            state = state.copyWith(
              filesSeen: p.filesSeen.toInt(),
              filesChanged: p.filesChanged.toInt(),
            );
            if (p.done) break;
          }
        } catch (e) {
```
with (a fresh `ScanRefreshGate` per root + the mid-scan refresh):
```dart
        state = state.copyWith(
          scanning: true,
          filesSeen: 0,
          filesChanged: 0,
          queued: _queue.length,
          lastError: null,
        );
        // Fresh gate per root: the scanner's changed-count restarts at 0.
        final refreshGate = ScanRefreshGate();
        try {
          await for (final p in scanLibrary(dbPath: db, roots: [root])) {
            if (_disposed) return;
            state = state.copyWith(
              filesSeen: p.filesSeen.toInt(),
              filesChanged: p.filesChanged.toInt(),
            );
            // Live-refresh the browse views as new music is committed (the Rust
            // scanner commits each file in its own transaction, so the rows are
            // already queryable), every kScanRefreshEvery changed files.
            if (refreshGate.shouldRefresh(p.filesChanged.toInt())) {
              _invalidateBrowse();
            }
            if (p.done) break;
          }
        } catch (e) {
```
(The existing post-loop `_invalidateBrowse()` and post-drain `_reconcileSelection()` stay — they guarantee a final, fully-reconciled refresh. The wiring is glue over the unit-tested gate; the no-flash behavior is covered by Task 2.)

- [ ] **Step 6: Verify nothing broke + lint**

Run: `mise exec -- flutter analyze` — Expected: no new issues.
Run: `mise exec -- flutter test test/scan_refresh_gate_test.dart` — Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/state/scan_refresh_gate.dart lib/state/scan_controller.dart test/scan_refresh_gate_test.dart
git commit -m "$(cat <<'EOF'
Refresh browse views every ~50 changed files during a scan

Add a pure ScanRefreshGate and call it from the scan loop to invalidate the
browse providers mid-scan (the Rust scanner commits per file, so rows are already
queryable), instead of only refreshing per folder. A no-change re-scan never
fires the mid-scan refresh.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: No spinner flash on mid-scan refresh

**Files:**
- Modify: `lib/catalog/artist_column.dart`, `lib/catalog/album_column.dart`, `lib/catalog/track_column.dart`
- Test: `test/artist_column_reload_test.dart` (create)

- [ ] **Step 1: Write the failing test** — create `test/artist_column_reload_test.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

void main() {
  testWidgets('artist column keeps its list visible during a reload (no spinner)',
      (tester) async {
    final artist = Artist(mbid: 'a1', name: 'Alpha', sortName: 'Alpha');
    var phase = 0;
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((k) async => null), // leads -> A
      artistsProvider.overrideWith((ref) {
        phase++;
        // First build resolves; the reload (after invalidate) never completes,
        // so the provider sits in loading-with-previous-value.
        return phase == 1
            ? Future.value(<Artist>[artist])
            : Completer<List<Artist>>().future;
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ArtistColumn())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Reload: provider transitions to loading WITH its previous value.
    container.invalidate(artistsProvider);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'skipLoadingOnReload must keep the list visible during reload');
    expect(find.text('Alpha'), findsWidgets);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/artist_column_reload_test.dart`
Expected: FAIL — without `skipLoadingOnReload`, the reload shows a `CircularProgressIndicator`, so the post-invalidate assertion fails.

- [ ] **Step 3: Add the flag to all three columns**

In `lib/catalog/artist_column.dart`, change:
```dart
    return artistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (artists) => _ArtistList(artists: artists),
```
to add the flag (keep the rest of the `.when(...)` unchanged):
```dart
    return artistsAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (artists) => _ArtistList(artists: artists),
```

In `lib/catalog/album_column.dart`, change:
```dart
    return albumsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
```
to:
```dart
    return albumsAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
```

In `lib/catalog/track_column.dart`, change:
```dart
    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
```
to:
```dart
    return tracksAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/artist_column_reload_test.dart`
Expected: PASS.

- [ ] **Step 5: Full suite + lint**

Run: `mise exec -- flutter test` — Expected: entire Dart suite green.
Run: `just lint --all` — Expected: PASS (if dart-format flags the new test, run `mise exec -- dart format <file>` and re-stage).

- [ ] **Step 6: Commit**

```bash
git add lib/catalog/artist_column.dart lib/catalog/album_column.dart lib/catalog/track_column.dart test/artist_column_reload_test.dart
git commit -m "$(cat <<'EOF'
Keep browse columns visible during reload (skipLoadingOnReload)

So a mid-scan refresh swaps in new rows without flashing a spinner.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Definition of Done

- During a scan, the browse columns refresh every ~50 changed files and at the
  end; newly-added artists appear in sorted position; selection is preserved.
- No spinner flash on mid-scan refresh (verified by the reload widget test).
- A no-change re-scan does no mid-scan refresh (verified by the gate test).
- Full Dart suite green; `just lint --all` clean.
```
