# Auto-hide Played Tracks in the Queue — Design

**Date:** 2026-07-01
**Status:** Approved

## Goal

In the expanded queue, hide the tracks *before* the currently-playing one so the current track
stays pinned at the top and the list shows only what's still to come. A toggle reveals the played
tracks; it's **off by default** (played tracks hidden).

## Behavior

- **Default (hiding on):** the expanded list shows tracks from the current track to the end; the
  already-played tracks (canonical indices `[0, currentIndex)`) are hidden, so the current track is
  the top row. As playback advances, `currentIndex` grows and the hidden prefix grows with it, so the
  list auto-trims from the top and the current track stays pinned at the top.
- **Toggle on:** the whole queue is shown (existing behavior).
- **Order numbers keep their real queue position** — a visible row at canonical index `i` shows
  `i + 1`, whether or not played tracks are shown (decided: real positions, not renumber-from-1).
- **The collapsed view is unchanged** (it's a now-playing + up-next summary, not the list).
- **Toggle is session-only**, resetting to hidden on each launch (decided), mirroring
  `queueExpandedProvider`.

## Architecture

Three small units in `lib/catalog/queue_panel.dart` (where the queue panel and its providers
already live).

### Unit 1 — `showPlayedProvider` (session state)

Mirror the existing `queueExpandedProvider` exactly:

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
```

### Unit 2 — `queueVisibleStart` (pure, unit-tested)

```dart
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

### Unit 3 — filter the expanded list + the toggle button

**Toggle button** — added to the header controls `Row` (near Shuffle/Empty), shown **only when the
queue is expanded** (it only affects the expanded list, and the collapsed header is width-constrained
with overflow guards, so a 5th always-on button risks crowding it):

```dart
if (expanded)
  Consumer(
    builder: (context, ref, _) {
      final showPlayed = ref.watch(showPlayedProvider);
      return IconButton(
        tooltip: showPlayed ? 'Hide played tracks' : 'Show played tracks',
        isSelected: showPlayed,
        icon: const Icon(Icons.history),
        onPressed: () => ref.read(showPlayedProvider.notifier).toggle(),
      );
    },
  ),
```

(`expanded` is already read in `build()` as `ref.watch(queueExpandedProvider)`.)

**`_expandedList`** computes the start once, then the itemBuilder maps its (filtered) builder index
`j` to the canonical index `i = start + j`. Because every existing per-row use of `i`
(`view.tracks[i]`, `selected = i == currentIndex`, the `ValueKey('${t.path}#$i')`, the number
`'${i + 1}'`, `removeAt(i)`) is *canonical*, they stay correct unchanged; only `itemCount`, the drag
listener's `index`, and `onReorderItem` need the offset:

```dart
Widget _expandedList(BuildContext context, QueueView view) {
  final leads = ref.watch(languageLeadsProvider);
  final controller = ref.read(queueControllerProvider);
  final scheme = Theme.of(context).colorScheme;
  final showPlayed = ref.watch(showPlayedProvider);
  final start = queueVisibleStart(
    showPlayed: showPlayed,
    currentIndex: view.currentIndex,
    trackCount: view.tracks.length,
  );
  // ... unchanged LayoutBuilder / Column / Scrollbar ...
        child: ReorderableListView.builder(
          scrollController: _queueScrollController,
          itemExtent: bilingualRowExtent(context, _queueRowBase),
          buildDefaultDragHandles: false,
          itemCount: view.tracks.length - start,
          onReorderItem: (oldIndex, newIndex) {
            controller.reorder(start + oldIndex, start + newIndex);
          },
          itemBuilder: (context, j) {
            final i = start + j;               // canonical index
            final t = view.tracks[i];
            final selected = i == view.currentIndex;
            // ... body unchanged: key #$i, number '${i + 1}', removeAt(i) ...
            // EXCEPT the drag listener uses the builder index j:
            //   lead: ReorderableDragStartListener(index: j, ...)
          },
        ),
}
```

`ref.watch(showPlayedProvider)` here makes the panel rebuild (and the list re-filter) when the
toggle flips or the current track advances.

## Edge cases

- Nothing playing (`currentIndex == null`) → `start = 0`, whole queue shown.
- Current at index 0 → `start = 0`, nothing hidden.
- Current is the last track → one row shown.
- Stale `currentIndex >= trackCount` → clamped to `trackCount` → empty list (no crash); self-heals
  when `_resolve()` repopulates (same class of transient the existing `nowPlaying` bounds-guard
  handles).

## Testing

- **`test/queue_hide_played_test.dart`**:
  - **Unit (`queueVisibleStart`)**: `showPlayed:true` → 0 (any currentIndex); `currentIndex:null` → 0;
    `showPlayed:false, currentIndex:0` → 0; `..currentIndex:3, trackCount:10` → 3; last track
    (`currentIndex:9,count:10`) → 9; stale (`currentIndex:12,count:10`) → 10; negative → 0.
  - **Widget** (stub `QueueView` with `currentIndex: 2`, tracks named so they're findable, panel
    expanded): hiding on (default) → the played tracks (index 0,1 titles) are absent, tracks 2..N are
    present, and the current track's number shows its real position (`'3'`); tap the toggle
    (`find.byTooltip('Show played tracks')`) → all tracks present and the button reports
    `isSelected == true`; the visible row count equals `tracks.length - currentIndex`.

## Files

- Modify: `lib/catalog/queue_panel.dart` (add `ShowPlayed`/`showPlayedProvider`, `queueVisibleStart`,
  the toggle button in the header, and the `_expandedList` filtering/offset).
- Create: `test/queue_hide_played_test.dart`.
