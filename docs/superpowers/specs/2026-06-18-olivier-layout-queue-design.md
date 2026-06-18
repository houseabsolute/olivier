# Olivier — Layout Redesign + Play Queue Design

**Date:** 2026-06-18
**Status:** Approved design → ready for implementation plan
**Backlog items covered:** 6 (layout redesign), 9 (clicking a track must not auto-play), 10 (queue abstraction)
**Out of scope (separate specs):** album art (5 & 8), import-decision log (2). This design *relies on* a reusable right-click context menu, but the only menu entry specified here is **"Add to queue"**; the other entries (re-read tags #3, per-entity re-fetch #4, info popup #7) are designed and built separately and simply add items to the same menu.

---

## Goal

Two changes that reinforce each other:

1. **Layout** — replace the three equal columns with a wide **Artist** column beside a right pane that stacks **Albums** over **Tracks**, giving long artist/album names room (item 6).
2. **Queue** — make playback flow through one explicit, user-managed **queue** that is the single source of truth. Clicking in the browse columns only *selects*; nothing in the browse area plays on click (item 9). The queue is built by **appending**, played via the queue or the transport bar, and emptied explicitly (item 10).

---

## 1. Layout ("Layout C")

`lib/catalog/browser_page.dart` currently builds three equal, resizable `MultiSplitView` columns (artist | album | track, `browser_page.dart:25-31`). It becomes:

```
┌───────────────────────────────────────────────┐
│              │  Albums                          │
│   Artists    │----------------------------------│   ← MultiSplitView, 2 areas:
│   (wide)     │  Tracks                          │     left = Artists,
│              │                                  │     right = Column[Albums / Tracks]
├───────────────────────────────────────────────┤
│  Queue  (N) · up next: …      [⇄][🗑][▾]        │   ← collapsible queue panel
├───────────────────────────────────────────────┤
│  ⏮ ⏯ ⏭   now playing…           ▭▭▭▭▭▭         │   ← now-playing bar (unchanged)
└───────────────────────────────────────────────┘
```

- The horizontal split has **2 areas**: a left **Artist** column (wider default; raise its `min` from 160) and a right area that is a `Column` of `AlbumColumn` (`Expanded`) over a `Divider` over `TrackColumn` (`Expanded`).
- All splits remain user-resizable (keep `MultiSplitView`). Default sizes: artist ≈ 33% width; albums/tracks 50/50.
- Below the split sits the **queue panel** (§3); the existing **now-playing bar** stays at the bottom unchanged.
- The state cascade is unchanged: select artist → load albums → select album → load tracks.

This section is **pure Flutter**, local to `browser_page.dart` plus the column widgets; no Rust/FFI change.

---

## 2. Interaction model (items 9, 10)

### Selection (item 9)
- **Single-click** an artist, album, or track → *selects* it (highlight, the `primaryContainer` pattern artist/album rows already use). It never plays.
- Track selection needs a new `selectedTrackProvider` (`NotifierProvider<…, int?>`, mirroring `SelectedAlbum` in `lib/state/providers.dart`).
- **Remove** the album row's play `IconButton` (`album_column.dart:67-82`) and change the track row's `onTap` (`track_column.dart:48`) from `playTrack(...)` to selection only. After this, **nothing in the browse columns triggers playback** — item 9 is satisfied structurally, not by convention.

### Enqueue — everything appends
Every "add" affordance **appends to the end of the queue and does not interrupt playback** (it does not auto-start, even into an empty queue):
- **Double-click** an artist / album / track.
- **Drag** an artist / album / track onto the queue panel.
- **Right-click → "Add to queue"**.

What each entity contributes, in display order:
- **Track** → that track.
- **Album** → its tracks (disc/position order).
- **Artist** → all of that artist's albums' tracks, in the album browse order (original-year then title) and within each album by disc/position.

### The one replace: "Shuffle entire library"
A single, distinct action — **"Shuffle entire library"** (a button in the queue panel header) — is the *only* thing that replaces the queue:
1. Replaces the queue with **every track in the library**.
2. Turns **shuffle on** and **starts playing**.
3. Because it discards the current queue, it shows a **confirm dialog with the track count** *when the queue is non-empty*; if the queue is empty it runs immediately.

"Shuffle everything" is implemented by replacing the queue with all library tracks and enabling the same shuffle toggle (§3) — not by physically scrambling a list — so it is cheap on a large library and the user can toggle shuffle off afterward for catalog order.

### Starting playback
There is no browse-column play action. Playback starts by:
- Clicking a **queue row** → jump to and play that entry.
- The **now-playing bar** transport (play/pause/next/prev), which drives the queue.
- **"Shuffle entire library"** (auto-plays, per above).

---

## 3. Queue panel

A collapsible panel between the browse split and the now-playing bar.

- **Collapsed (default):** a single header row — `Queue · {N} tracks · up next: {title}` plus controls: **Shuffle** toggle, **Empty** (clear all), **Shuffle entire library**, and an **expand** caret. Shows a count badge; it does **not** auto-expand when you enqueue.
- **Expanded:** a `ReorderableListView` of the queued tracks rendered with `BilingualText` titles (reuse the bilingual display). Each row:
  - shows the track (bilingual) + artist/album context,
  - has a **drag handle** to reorder,
  - has an **×** to remove that one entry,
  - **click** the row → jump to and play that entry,
  - the **currently-playing** entry is highlighted.
- **Empty** clears the whole queue (and stops playback / clears now-playing). Also offered as a right-click action on the panel.
- **Shuffle** toggle randomizes *playback order* while the visible list stays put (just_audio shuffle mode); toggling off resumes in-order. The DB already carries the hooks: `queue_item.shuffled_position` and `playback_state.shuffle` (`db.rs`).

A track may appear in the queue more than once (queue is positional, keyed by `(position, path)`).

---

## 4. Drag & drop

- Browse rows become `Draggable`/`LongPressDraggable` carrying an entity reference (artist mbid / album release-mbid / track id+path).
- The queue panel (header when collapsed, list when expanded) is a `DragTarget` that, on drop, resolves the entity to its track paths (§5) and appends them.
- Reordering inside the expanded queue uses `ReorderableListView`'s own drag (independent of the enqueue drag).

---

## 5. Backend / data flow

**Dart — `lib/audio/queue_controller.dart`** (promote from album-only):
- Today: `setQueue` (album-only, private rebuild), `setShuffle`, `_persist`, `restoreFromSnapshot`.
- Add: `append(List<String> paths)`, `removeAt(int)`, `reorder(int from, int to)`, `clear()`, and `replaceShuffled(List<String> paths)` (for "Shuffle entire library"). Each keeps the existing `_persist` (writes `queue_item`/`playback_state`) so durability and launch-restore are unchanged.
- Expose `queueViewProvider` — the ordered `List<QueueTrack>` + current index — for the panel to render. It resolves paths to bilingual metadata via the existing `tracks_for_paths`.
- The old `playAlbum`-replaces path drops out of the UI (no album play button); `setQueue`/replace remains available internally only where needed (restore, shuffle-all).

**Rust — new FFI queries** (`rust/src/catalog/query.rs` + `rust/src/api/catalog.rs`):
- `track_paths_for_artist(db_path, artist_mbid) -> Vec<String>` — all the artist's tracks' file paths in display order.
- `track_paths_for_library(db_path) -> Vec<String>` — every track's path (for "Shuffle entire library").
- **Album paths already exist** (`file_paths_for_album` / the album-paths FFI) — reuse for album enqueue.
- `tracks_for_paths` already returns `QueueTrack` with bilingual title alts — reuse for the queue view. No change to existing DTOs.
- New query fns require one `flutter_rust_bridge_codegen generate` pass; commit the generated bridge.

**Persistence** is unchanged: `queue_item(position, path, shuffled_position)` + `playback_state(current_index, position_ms, shuffle)` via `save_queue`/`load_queue` (`rust/src/db.rs`, `rust/src/api/queue.rs`). The new ops just call the existing persistence after each mutation.

---

## 6. Edge cases & errors

- **Empty queue:** transport play is a no-op; "up next" shows nothing; Empty is disabled.
- **Append into empty/idle queue:** does **not** auto-start (per the agreed model); the user presses play or clicks a row.
- **Missing file** (path no longer on disk): `tracks_for_paths` already returns a filename-only placeholder for unknown paths; the queue row shows it and skips on play (existing player behavior).
- **Large library:** "Shuffle entire library" loads all paths in one query; confirm dialog states the count. Play-order shuffle avoids materializing a randomized copy.
- **Re-scan while queued:** the queue stores paths; a path removed by a re-scan becomes a placeholder (above). No queue corruption.
- **Duplicate enqueue:** allowed; the same track can occupy multiple positions.

---

## 7. Testing

- **Rust:** unit-test `track_paths_for_artist` (ordering across multiple albums) and `track_paths_for_library` against a seeded catalog; reuse the existing catalog-test fixtures/harness.
- **Dart (widget):** column selection (single-click selects, no playback; double-click appends), with `QueueController` append/reorder/remove/clear verified through a `queueViewProvider`; the queue panel renders bilingual rows, reorders, removes, and jumps. Follow the existing provider-override test pattern (e.g. `test/catalog_text_scale_test.dart`).
- **Dart:** "Shuffle entire library" replaces + enables shuffle + confirms when non-empty (mock the library-paths FFI).
- **Layout:** a widget test that the 2-pane + stacked album/track + queue panel renders without overflow (and at enlarged text scale, consistent with the existing `bilingualRowExtent` work).

---

## 8. Build sequencing (each slice independently shippable)

1. **Layout redesign** — `browser_page.dart` 2-pane + stacked album/track + empty collapsible queue-panel shell; remove the album ▶ button. Pure Flutter.
2. **Selection + append** — `selectedTrackProvider`; single-click selects; double-click appends; `QueueController.append` + `queueViewProvider`; double-click an album/track uses existing album/track-path resolution.
3. **Queue panel ops** — expanded `ReorderableListView`: reorder, remove (×), Empty, click-to-jump, current-track highlight.
4. **Enqueue by entity + menus** — new FFI `track_paths_for_artist` / `track_paths_for_library`; the shared right-click "Add to queue"; drag-to-queue; "Shuffle entire library" (replace + shuffle + confirm).
5. **Shuffle toggle** — header toggle wired to just_audio shuffle mode + `playback_state.shuffle`/`queue_item.shuffled_position`.

---

## 9. Deferred / not in this spec

- "Play next" (insert-after-current) — intentionally dropped; everything appends. Easy to add later.
- The other right-click menu entries (re-read tags, per-entity re-fetch, info popup) — separate backlog items that share this design's context menu.
- Album-art thumbnails in the queue rows — depends on the separate album-art pipeline (items 5 & 8); the queue view works without them.
- Keyboard play (Enter on selection) — out unless requested; playback is via the queue/transport.
