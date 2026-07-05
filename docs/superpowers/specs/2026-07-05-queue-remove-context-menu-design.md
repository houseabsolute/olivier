# "Remove from queue" in the Row Context Menu — Design

**Date:** 2026-07-05
**Status:** Approved

## Goal

Let the user remove a track from the **queue** (not the library) via the right-click context menu on
an expanded-queue row. The capability already exists as a per-row **×** button
(`queue_panel.dart` → `controller.removeAt(i)`); this adds the same action to the context menu for
discoverability, mirroring how browse rows offer "Remove from library."

## Background

`RowContextMenu` (`lib/widgets/context_menu.dart`) is a shared widget used by the browse columns and
the queue panel. Each menu item renders only when its matching callback is non-null, so each caller
shows the actions appropriate to its entity. Its existing `onRemove` callback is already used for
**"Remove from library"** (browse rows), so a distinct callback is needed for the queue action.

The expanded-queue row already wraps each entry in `RowContextMenu` (currently passing only `entity`
and `onInfo`), and already has a working **×** button calling `controller.removeAt(i)` with the
canonical index `i = start + j` (correct under the hide-played `start` offset).

## Design

### Unit 1 — `RowContextMenu.onRemoveFromQueue` (shared widget)

Add one optional callback and its menu item, following the existing pattern exactly:

- New field: `final ValueChanged<QueueEntityRef>? onRemoveFromQueue;` (constructor param, un-required).
- New menu item, rendered only when the callback is non-null:
  ```dart
  if (onRemoveFromQueue != null)
    const PopupMenuItem<String>(
        value: 'removeFromQueue', child: Text('Remove from queue')),
  ```
  Placed **immediately before** the existing `onRemove` ("Remove from library") item so the two
  removal actions group together. (On a queue row `onRemove` is null, so only "Remove from queue"
  shows; on a browse row `onRemoveFromQueue` is null, so only "Remove from library" shows — they
  never both appear today, but the ordering is defined for correctness.)
- New `switch` case: `case 'removeFromQueue': onRemoveFromQueue?.call(entity);`.
- Update the class doc comment to list `onRemoveFromQueue` alongside the other callbacks.

### Unit 2 — wire it in the queue panel

In the expanded-queue row's `RowContextMenu` (`lib/catalog/queue_panel.dart`, currently `entity` +
`onInfo`), add:

```dart
onRemoveFromQueue: (_) => controller.removeAt(i),
```

The entity argument is ignored (the captured canonical index `i` is what `removeAt` needs), exactly
as the sibling `onInfo: (_) => showInfoDialog(...)` ignores it and uses the captured `t`. This is the
**same call** the × button makes, so behavior — including the hide-played `start` offset and
occurrence-aware duplicate handling inside `removeAt` — is identical.

## Behavior

- Queue row right-click menu becomes: **Info → Remove from queue**.
- Browse/library rows are unchanged (they don't pass `onRemoveFromQueue`).
- No confirmation dialog — queue removal is cheap and non-destructive, matching the × button.
- Removing the currently-playing track behaves exactly as the × button does today (handled by
  `removeAt` / just_audio); this change adds no new playback behavior.

## Testing

**`test/context_menu_test.dart`** (existing file — add to it, mirroring the existing
`shows Remove from library and invokes onRemove` test, which uses the `startGesture` +
`kSecondaryButton` right-click pattern):

- When `onRemoveFromQueue` is provided, right-clicking the child opens the menu, a
  **"Remove from queue"** item is present, and tapping it invokes the callback with the row's
  `entity`.
- The "only the provided optional actions" assertion pattern (already used in the first test) covers
  the render-only-when-non-null contract; add `expect(find.text('Remove from queue'), findsNothing)`
  to a case where the callback is absent to lock it in.
- Leave the existing `onRemove` ("Remove from library") coverage intact / unaffected.

## Files

- Modify: `lib/widgets/context_menu.dart` — add `onRemoveFromQueue` field, menu item, switch case,
  doc comment.
- Modify: `lib/catalog/queue_panel.dart` — pass `onRemoveFromQueue: (_) => controller.removeAt(i)`.
- Modify: `test/context_menu_test.dart` — the assertions above.

## Out of scope

Other queue-row context actions (add-to-playlist, info-on-album, etc.) and any change to the × button
or to library removal.
</content>
