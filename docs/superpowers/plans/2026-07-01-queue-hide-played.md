# Auto-hide Played Tracks in the Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide already-played tracks in the expanded queue so the current track stays pinned at the top, with a toggle (off by default) to reveal them.

**Architecture:** A session-only `showPlayedProvider` (`Notifier<bool>`, like `queueExpandedProvider`) and a pure `queueVisibleStart()` slice the expanded list to `[currentIndex..end]` by default. The `ReorderableListView.builder` itemBuilder maps its filtered index `j` to the canonical index `i = start + j`, so every existing per-row use of `i` stays correct; only `itemCount`, the drag `index`, and `onReorderItem` take the offset. A toggle button (shown only when expanded) flips the provider.

**Tech Stack:** Flutter, Riverpod (`Notifier`), `ReorderableListView.builder`.

**Spec:** `docs/superpowers/specs/2026-07-01-queue-hide-played-design.md`

---

## Repository facts (verified — rely on these)

- Everything is in `lib/catalog/queue_panel.dart`:
  - `queueExpandedProvider` (a `Notifier<bool>` with `toggle()`) is defined at lines 16–24 — the exact pattern to mirror.
  - The header controls `Row` has: Shuffle (Consumer, ~257), **Shuffle entire library** (IconButton, lines 273–277), Empty (279–285), expand/collapse caret (287–294). `expanded` (= `ref.watch(queueExpandedProvider)`) is in scope in this header (used at line 289).
  - `_expandedList(BuildContext context, QueueView view)` (starts ~line 309) builds the `ReorderableListView.builder` (~line 325): `itemCount: view.tracks.length`, `onReorderItem: (oldIndex, newIndex) { controller.reorder(oldIndex, newIndex); }`, and `itemBuilder: (context, i) { ... }` which uses `i` for `view.tracks[i]`, `selected = i == view.currentIndex`, `key: ValueKey('${t.path}#$i')`, `ReorderableDragStartListener(index: i)`, the number `'${i + 1}'`, and `controller.removeAt(i)`.
- `_expandedList` is a method on `_QueuePanelState extends ConsumerState`, so `ref` is available; it already does `ref.watch(languageLeadsProvider)`.
- Existing queue widget tests (`test/queue_order_number_test.dart`, `test/queue_scrollbar_test.dart`) stub `queueProvider` via a `_StubQueueNotifier` + `_app` harness and expand via `find.byTooltip('Expand queue')`. Reuse that shape.
- Run tests: `mise exec -- flutter test`; analyze: `mise exec -- flutter analyze`.

## File Structure

- `lib/catalog/queue_panel.dart` (MODIFY) — add `ShowPlayed`/`showPlayedProvider` + `queueVisibleStart` (Task 1); add the toggle button + filter `_expandedList` (Task 2).
- `test/queue_hide_played_test.dart` (CREATE) — `queueVisibleStart` unit tests (Task 1) + filtering/toggle widget tests (Task 2).

---

## Task 1: `showPlayedProvider` + pure `queueVisibleStart`

**Files:**
- Modify: `lib/catalog/queue_panel.dart`
- Test: `test/queue_hide_played_test.dart`

- [ ] **Step 1: Write the failing unit test**

Create `test/queue_hide_played_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/queue_panel.dart';

void main() {
  group('queueVisibleStart', () {
    test('showPlayed true → 0 regardless of currentIndex', () {
      expect(
        queueVisibleStart(showPlayed: true, currentIndex: 5, trackCount: 10),
        0,
      );
    });
    test('currentIndex null → 0', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: null, trackCount: 10),
        0,
      );
    });
    test('hiding, currentIndex 0 → 0', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 0, trackCount: 10),
        0,
      );
    });
    test('hiding, currentIndex 3 → 3', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 3, trackCount: 10),
        3,
      );
    });
    test('hiding, last track → currentIndex', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 9, trackCount: 10),
        9,
      );
    });
    test('stale currentIndex beyond count → clamped to count', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 12, trackCount: 10),
        10,
      );
    });
    test('negative currentIndex → 0', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: -1, trackCount: 10),
        0,
      );
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/queue_hide_played_test.dart`
Expected: FAIL to compile — `queueVisibleStart` is undefined.

- [ ] **Step 3: Add the provider + pure function**

In `lib/catalog/queue_panel.dart`, immediately AFTER the `queueExpandedProvider` definition (line 24) and before the next declaration, insert:

```dart

/// Whether the expanded queue shows already-played tracks (those before the
/// current one). Off by default so the current track stays pinned at the top.
/// Session-only (resets on relaunch), like [queueExpandedProvider].
class ShowPlayed extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final showPlayedProvider = NotifierProvider<ShowPlayed, bool>(ShowPlayed.new);

/// Canonical index of the first row the expanded queue should show. Hiding
/// played tracks (the default) starts at the current track so it's pinned at the
/// top; showing played tracks — or nothing playing — starts at 0. Clamped to
/// [0, trackCount] so a stale/out-of-range currentIndex can't over-run the list.
int queueVisibleStart({
  required bool showPlayed,
  required int? currentIndex,
  required int trackCount,
}) {
  if (showPlayed || currentIndex == null) return 0;
  return currentIndex.clamp(0, trackCount);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/queue_hide_played_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/catalog/queue_panel.dart test/queue_hide_played_test.dart
git commit -m "Add showPlayedProvider + pure queueVisibleStart"
```

---

## Task 2: Filter the expanded list + add the toggle button

**Files:**
- Modify: `lib/catalog/queue_panel.dart`
- Test: `test/queue_hide_played_test.dart`

- [ ] **Step 1: Write the failing widget test**

Append to `test/queue_hide_played_test.dart` (add these imports at the top of the file alongside the existing one, then add the widget group inside `main()`):

Imports to add at the top:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';
```

Harness + widget group (add the harness above `void main()` and the group inside it):

```dart
final _tracks = [
  for (var i = 0; i < 5; i++)
    QueueTrack(path: '/$i.flac', title: 'T$i', album: 'X', addedAt: 0),
];

class _StubQueueNotifier extends QueueNotifier {
  _StubQueueNotifier(this._value);
  final QueueView _value;
  @override
  Future<QueueView> build() async => _value;
}

Future<QueueController> _seededController() async {
  final qc = QueueController.withPlayer(
    FakeQueuePlayer(),
    dbPath: ':memory:',
    saveQueue: (_) async {},
  );
  await qc.append([for (final t in _tracks) t.path]);
  return qc;
}

Widget _app(QueueController qc) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      queueControllerProvider.overrideWithValue(qc),
      queueProvider.overrideWith(
        () => _StubQueueNotifier(
          QueueView(tracks: _tracks, currentIndex: 2, shuffled: false),
        ),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  );
}
```

Group inside `main()`:

```dart
  group('hide played tracks', () {
    testWidgets('hides tracks before the current one by default; toggle reveals',
        (tester) async {
      final qc = await _seededController();
      await tester.pumpWidget(_app(qc));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand queue'));
      await tester.pumpAndSettle();

      // Default: played tracks (canonical 0,1) hidden; current (2) + rest shown.
      expect(find.text('T0'), findsNothing);
      expect(find.text('T1'), findsNothing);
      expect(find.text('T2'), findsOneWidget);
      expect(find.text('T3'), findsOneWidget);
      expect(find.text('T4'), findsOneWidget);
      // Current track keeps its REAL queue number (3), not renumbered to 1.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('1'), findsNothing);

      // Toggle on → every track shown, and T0 now numbered 1.
      await tester.tap(find.byTooltip('Show played tracks'));
      await tester.pumpAndSettle();
      expect(find.text('T0'), findsOneWidget);
      expect(find.text('T1'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/queue_hide_played_test.dart`
Expected: FAIL — `T0`/`T1` are still shown (no filtering yet) and there is no `Show played tracks` tooltip.

- [ ] **Step 3: Add the toggle button to the header**

In `lib/catalog/queue_panel.dart`, AFTER the "Shuffle entire library" `IconButton` (which ends at line 277 with `),`) and BEFORE the `// Empty` comment (line 278), insert:

```dart
                // Show / hide already-played tracks (expanded view only).
                if (expanded)
                  Consumer(
                    builder: (context, ref, _) {
                      final showPlayed = ref.watch(showPlayedProvider);
                      return IconButton(
                        tooltip: showPlayed
                            ? 'Hide played tracks'
                            : 'Show played tracks',
                        isSelected: showPlayed,
                        icon: const Icon(Icons.history),
                        onPressed: () =>
                            ref.read(showPlayedProvider.notifier).toggle(),
                      );
                    },
                  ),
```

- [ ] **Step 4: Filter `_expandedList`**

Make four edits in `_expandedList`:

(a) After `final scheme = Theme.of(context).colorScheme;` (near the top of `_expandedList`, ~line 312), add:

```dart
    final showPlayed = ref.watch(showPlayedProvider);
    final start = queueVisibleStart(
      showPlayed: showPlayed,
      currentIndex: view.currentIndex,
      trackCount: view.tracks.length,
    );
```

(b) Change the item count:

```dart
                  itemCount: view.tracks.length,
```

to:

```dart
                  itemCount: view.tracks.length - start,
```

(c) Change the reorder callback:

```dart
                  onReorderItem: (oldIndex, newIndex) {
                    controller.reorder(oldIndex, newIndex);
                  },
```

to:

```dart
                  onReorderItem: (oldIndex, newIndex) {
                    controller.reorder(start + oldIndex, start + newIndex);
                  },
```

(d) Change the itemBuilder's index handling. Replace:

```dart
                  itemBuilder: (context, i) {
                    final t = view.tracks[i];
```

with (rename the builder index to `j`, derive the canonical index `i`):

```dart
                  itemBuilder: (context, j) {
                    final i = start + j; // canonical index in the full queue
                    final t = view.tracks[i];
```

and change ONLY the drag listener from the builder index — replace:

```dart
                            lead: ReorderableDragStartListener(
                              index: i,
```

with:

```dart
                            lead: ReorderableDragStartListener(
                              index: j,
```

Everything else in the itemBuilder (`selected = i == view.currentIndex`, `key: ValueKey('${t.path}#$i')`, `number: '${i + 1}'`, `onPressed: () => controller.removeAt(i)`) already uses the canonical `i` and stays as-is.

- [ ] **Step 5: Run to verify it passes**

Run: `mise exec -- flutter test test/queue_hide_played_test.dart`
Expected: PASS (7 unit + 1 widget).

- [ ] **Step 6: Analyze + full suite + lint**

Run: `mise exec -- flutter analyze`
Expected: "No issues found!"

Run: `mise exec -- flutter test`
Expected: all tests pass.

Run: `just lint --all`
Expected: passes. (Run `mise exec -- dart format lib/catalog/queue_panel.dart test/queue_hide_played_test.dart` first if dart-format flags anything.)

- [ ] **Step 7: Commit**

```bash
git add lib/catalog/queue_panel.dart test/queue_hide_played_test.dart
git commit -m "Hide played tracks in the expanded queue with a toggle"
```

- [ ] **Step 8: Manual verification (human — can't run headless)**

`just run`, shuffle the library (or build any multi-track queue), play a track a few in, expand the queue: the current track sits at the top with played tracks hidden; the `history` toggle in the header reveals/hides them; numbers show real queue positions; removing/reordering a visible row affects the right track.

---

## Self-Review

**1. Spec coverage:**
- Hide `[0, currentIndex)` by default, current pinned at top → Task 2 (start = `queueVisibleStart`, itemCount/itemBuilder offset). ✓
- Toggle reveals all, off by default, session-only → Task 1 (`showPlayedProvider`) + Task 2 (button). ✓
- Real-position numbering → Task 2 keeps `'${i + 1}'` with canonical `i`. ✓
- Toggle only when expanded → Task 2 Step 3 (`if (expanded)`). ✓
- Reorder/remove map to canonical index → Task 2 Step 4 (onReorderItem offset; `removeAt(i)` uses canonical `i`). ✓
- Collapsed view unchanged → only `_expandedList` + an `if (expanded)` button change. ✓
- Edge cases (null/0/last/stale/negative currentIndex) → Task 1 `queueVisibleStart` + its 7 unit tests. ✓

**2. Placeholder scan:** No TBD/bare-prose steps; every code step shows full code and exact commands.

**3. Type consistency:** `queueVisibleStart({showPlayed, currentIndex, trackCount}) → int` and `showPlayedProvider`/`ShowPlayed.toggle()` are defined in Task 1 and used identically in Task 2 (the `start` computation, the toggle button). The itemBuilder rename is consistent: builder index `j`, canonical `i = start + j`, drag uses `j`, everything else uses `i`.
