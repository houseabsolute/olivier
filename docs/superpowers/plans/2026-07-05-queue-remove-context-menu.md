# "Remove from queue" Context-Menu Item — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Remove from queue" item to the right-click row context menu for expanded-queue rows, invoking the same queue-only removal the existing × button uses.

**Architecture:** Add one optional `onRemoveFromQueue` callback to the shared `RowContextMenu` (rendered only when non-null, matching its existing per-callback pattern), then wire it in the queue panel to `controller.removeAt(i)` — the exact call the × button already makes with the same canonical index.

**Tech Stack:** Dart / Flutter, Riverpod. Widget tests via `flutter test` (`startGesture` + `kSecondaryButton` for right-click, `FakeQueuePlayer` for the queue controller).

---

## Background the implementer needs

- `lib/widgets/context_menu.dart` — `RowContextMenu` is a `StatelessWidget` shared by the browse
  columns and the queue panel. Each `PopupMenuItem` in its `showMenu` list is guarded by
  `if (onX != null)`, so a caller only sees the actions it wired. A `switch (selected)` dispatches to
  the matching callback. The existing `onRemove` callback renders **"Remove from library"** — do not
  reuse it; the queue action needs its own callback so the two never collide.
- `lib/catalog/queue_panel.dart` (~line 412) — each expanded-queue row is already wrapped in
  `RowContextMenu` passing `entity` + `onInfo`, and already has a working × `IconButton` calling
  `controller.removeAt(i)` where `i = start + j` is the canonical queue index (correct under the
  hide-played `start` offset). `controller` is `ref.read(queueControllerProvider)`.
- `QueueController.removeAt(int index)` removes a queue entry (occurrence-aware, mirrors to the
  player) without touching the library. `orderedPaths` exposes the current canonical order.
- Tests: `test/context_menu_test.dart` already unit-tests `RowContextMenu` (including the
  "Remove from library"/`onRemove` case) with the right-click gesture pattern. `test/queue_row_info_test.dart`
  already drives the real `QueuePanel` + `QueueController` + `FakeQueuePlayer` and expands the queue.
- Lint/format gate: `just lint --all`. Test runner: `flutter test` (available via the repo's mise
  toolchain; if `flutter` isn't on PATH, prefix with `mise exec -- `).

---

## Task 1: Add `onRemoveFromQueue` to `RowContextMenu`

**Files:**
- Modify: `lib/widgets/context_menu.dart`
- Modify: `test/context_menu_test.dart`

- [ ] **Step 1: Write the failing test**

Add this test to `test/context_menu_test.dart` (after the existing `shows Remove from library` test,
before the final closing `}` of `main`). It mirrors that test's right-click pattern:

```dart
  testWidgets('shows Remove from queue and invokes onRemoveFromQueue',
      (tester) async {
    QueueEntityRef? removed;
    const entity = QueueEntityRef.track(7);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RowContextMenu(
          entity: entity,
          onRemoveFromQueue: (e) => removed = e,
          child: const SizedBox(width: 200, height: 40, child: Text('row')),
        ),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Remove from queue'), findsOneWidget);
    // The library action is NOT shown just because the queue action is.
    expect(find.text('Remove from library'), findsNothing);
    await tester.tap(find.text('Remove from queue'));
    await tester.pumpAndSettle();
    expect(removed, entity);
  });
```

Also add one assertion to the EXISTING first test (`shows Add to queue + only the provided optional
actions`) to lock the render-only-when-non-null contract for the new item. Immediately after its
existing `expect(find.text('Re-fetch from MusicBrainz'), findsNothing);` line, add:

```dart
    expect(find.text('Remove from queue'), findsNothing); // no onRemoveFromQueue given
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/context_menu_test.dart`
Expected: FAIL — compile error, `The named parameter 'onRemoveFromQueue' isn't defined`.

- [ ] **Step 3: Implement the callback, menu item, and dispatch**

In `lib/widgets/context_menu.dart`:

(a) Update the class doc comment (lines 4–7) to include the new callback. Change the second line:

```dart
/// optional [onAddToQueue]/[onInfo]/[onReadTags]/[onRefetch]/[onSetReading]/[onRemove] entries appear
```
to:
```dart
/// optional [onAddToQueue]/[onInfo]/[onReadTags]/[onRefetch]/[onSetReading]/[onRemoveFromQueue]/[onRemove] entries appear
```

(b) Add the constructor parameter. Change:

```dart
    this.onSetReading,
    this.onRemove,
    required this.child,
```
to:
```dart
    this.onSetReading,
    this.onRemoveFromQueue,
    this.onRemove,
    required this.child,
```

(c) Add the field. Change:

```dart
  final ValueChanged<QueueEntityRef>? onSetReading;
  final ValueChanged<QueueEntityRef>? onRemove;
```
to:
```dart
  final ValueChanged<QueueEntityRef>? onSetReading;
  final ValueChanged<QueueEntityRef>? onRemoveFromQueue;
  final ValueChanged<QueueEntityRef>? onRemove;
```

(d) Add the menu item immediately before the `onRemove` ("Remove from library") item. Change:

```dart
        if (onRemove != null)
          const PopupMenuItem<String>(
              value: 'remove', child: Text('Remove from library')),
      ],
```
to:
```dart
        if (onRemoveFromQueue != null)
          const PopupMenuItem<String>(
              value: 'removeFromQueue', child: Text('Remove from queue')),
        if (onRemove != null)
          const PopupMenuItem<String>(
              value: 'remove', child: Text('Remove from library')),
      ],
```

(e) Add the dispatch case immediately before the `case 'remove':` case. Change:

```dart
      case 'remove':
        onRemove?.call(entity);
    }
```
to:
```dart
      case 'removeFromQueue':
        onRemoveFromQueue?.call(entity);
      case 'remove':
        onRemove?.call(entity);
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/context_menu_test.dart`
Expected: PASS (all tests, including the new one and the amended first test).

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/context_menu.dart test/context_menu_test.dart
git commit -m "feat: add onRemoveFromQueue action to RowContextMenu"
```

---

## Task 2: Wire "Remove from queue" into the queue panel

**Files:**
- Modify: `lib/catalog/queue_panel.dart`
- Modify: `test/queue_row_info_test.dart`

- [ ] **Step 1: Write the failing integration test**

Add `import 'package:flutter/gestures.dart';` to `test/queue_row_info_test.dart` (for
`kSecondaryButton`), then add this test inside `main`, after the existing
`expanded queue rows are wrapped in RowContextMenu` test:

```dart
  testWidgets(
      'right-click → Remove from queue removes that track from the queue',
      (tester) async {
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await qc.append(['/m/a.flac', '/m/b.flac']);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((_) async => null),
        queueControllerProvider.overrideWithValue(qc),
        queueProvider.overrideWith(
          () => _FakeQueue(QueueView(
            tracks: [_track('/m/a.flac', 'A'), _track('/m/b.flac', 'B')],
            currentIndex: 0,
            shuffled: false,
          )),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Expand queue'));
    await tester.pump();
    await tester.pump();

    // Right-click the SECOND row (canonical index 1 = '/m/b.flac'), so the
    // assertion also proves the correct index is passed to removeAt.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RowContextMenu).at(1)),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove from queue'));
    await tester.pumpAndSettle();

    expect(qc.orderedPaths, ['/m/a.flac']);
  });
```

Note: the panel's list comes from the static `_FakeQueue` view, so the displayed rows won't shrink,
but `removeAt` mutates the real `qc` (removing from `_orderedPaths` synchronously before its awaits),
so asserting on `qc.orderedPaths` verifies the wiring and the index.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/queue_row_info_test.dart`
Expected: FAIL — the menu has no "Remove from queue" item yet, so
`tester.tap(find.text('Remove from queue'))` fails ("Found 0 widgets").

- [ ] **Step 3: Wire the callback into the queue row**

In `lib/catalog/queue_panel.dart`, in the expanded-queue row's `RowContextMenu` (the one with
`key: ValueKey('${t.path}#$i')`), add `onRemoveFromQueue` after the `onInfo` block. Change:

```dart
                      onInfo: (_) => showInfoDialog(
                        context,
                        title: 'Track',
                        fields: queueTrackInfoFields(t),
                      ),
                      child: Material(
```
to:
```dart
                      onInfo: (_) => showInfoDialog(
                        context,
                        title: 'Track',
                        fields: queueTrackInfoFields(t),
                      ),
                      onRemoveFromQueue: (_) => controller.removeAt(i),
                      child: Material(
```

(The entity argument is ignored; the captured canonical index `i` is what `removeAt` needs — same as
the × button on the same row.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/queue_row_info_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add lib/catalog/queue_panel.dart test/queue_row_info_test.dart
git commit -m "feat: offer Remove from queue in the queue row context menu"
```

---

## Task 3: Full-suite + lint gate

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `flutter test`
Expected: All tests pass (the new cases plus the existing suite).

- [ ] **Step 2: Run the lint/format gate**

Run: `just lint --all`
Expected: Clean (exit 0).

- [ ] **Step 3: If `dart format` rewrites a file or the linter flags something, fix it, `git add` the
  file, and add a `style:` commit (or amend the relevant task commit), then re-run until clean.**

---

## Manual verification (human, after merge)

In a running app: right-click a track in the expanded queue → the menu shows **Info** and
**Remove from queue** → choosing it drops that track from the queue (and only the queue; the library
is untouched), matching the × button. Confirm right-clicking a browse/library row still shows
**Remove from library** and NOT "Remove from queue".
</content>
