# Responsive Browse Layout — Design

**Date:** 2026-07-25
**Status:** Draft

## Goal

Make the browse UI adapt to the viewport width. At 600dp and above, nothing changes: the artist |
(album / track) `ResizableSplit` cascade as today. Below 600dp — a phone, or a narrow desktop
window — the three panes become one full-screen level at a time, drilled into: artists → that
artist's albums → that album's tracks.

This is a responsive layout, not a phone build. The same code runs everywhere and the desktop gets
the narrow layout when its window is narrow.

## Decisions (agreed)

- **Breakpoint: 600dp**, Material's compact/expanded line. The cascade needs ~548dp just to satisfy
  its own minimums (`minFirst` 220 + `minSecond` 320 + an 8px divider), so 600 is near where it
  genuinely stops fitting. Both existing browser_page tests run at 1000×800 and 800×600, so both
  stay on the wide path and keep asserting what they assert today.
- **Queue:** the now-playing bar stays pinned at every level; the queue opens as its own full screen.
- **Search:** tapping a hit lands on the deepest matching screen — a track opens its album's track
  list, an album opens its tracks, an artist opens their albums.

## The core idea: derive the level, don't navigate to it

The obvious implementation is a `Navigator` with a route per level, but that means keeping a route
stack in sync with `selectedArtistProvider` / `selectedAlbumProvider` / `selectedTrackProvider`,
which are already the source of truth and are mutated from outside the browse UI (search, context
menus, the queue).

Instead the level is a pure function of the selection:

| Selection | Level shown |
| --- | --- |
| `selectedArtist == null` | Artists |
| `selectedAlbum == null` | Albums (of the selected artist) |
| otherwise | Tracks (of the selected album) |

Consequences that come for free:

- **Search already works.** `selectHit` (`lib/state/search.dart:39`) sets artist, then album, then
  track. Setting all three puts the derived level at Tracks — exactly the agreed behaviour — with no
  narrow-layout-specific code in the search path.
- **Back is just clearing one level**, and the existing cascade in the notifiers does the rest:
  `SelectedArtist.select` already clears the album, `SelectedAlbum.select` already clears the track.
- **No divergence.** There is no second copy of "where am I" that can disagree with the selection.

## Layer 1 — `SelectedArtist.clear()`

`SelectedAlbum` and `SelectedTrack` both have `clear()`; `SelectedArtist` (`lib/state/providers.dart:31`)
does not, because nothing has needed to deselect an artist until now. Add it, clearing the album too
so the existing cascade holds:

```dart
void clear() {
  state = null;
  ref.read(selectedAlbumProvider.notifier).clear();
}
```

## Layer 2 — `browseLevelProvider`

A derived provider in `lib/state/browse_level.dart`:

```dart
enum BrowseLevel { artists, albums, tracks }
```

`browseLevelProvider` watches the three selection providers and returns the level per the table
above. A `BrowseLevelController` (or plain functions on the notifier) provides `up()`:

- Tracks → `selectedAlbumProvider.clear()`
- Albums → `selectedArtistProvider.clear()`
- Artists → nothing (the caller decides whether that means "exit")

Pure and unit-testable without a widget tree, which is where most of the tests for this go.

## Layer 3 — the shell split in `browser_page.dart`

`build` wraps the body in a `LayoutBuilder` and branches once on
`constraints.maxWidth < kNarrowBrowseWidth` (600). Extract today's body into `_wideBody` unchanged —
the cascade, ratio persistence, and queue panel behaviour must not move — and add `_narrowBody`.

`_narrowBody` is:

- **Body:** the queue when `queueExpandedProvider` is true, otherwise the widget for the current
  `BrowseLevel` — `ArtistColumn`, `AlbumColumn` or `TrackColumn`, used **as-is**. All three are
  width-agnostic `ConsumerWidget`s that already render their own empty states, context menus and
  scroll-into-view behaviour; the narrow layout simply gives them the whole viewport.
- **`SearchResultsPanel`** stays overlaid in the same `Stack`, unchanged.
- **Now-playing bar** stays as `bottomNavigationBar`.
- **No collapsed `QueuePanel` header** — that row is what the queue button in the app bar replaces.

### App bar

The wide app bar puts `TopControls` (search field + volume) in the title. At 411dp that competes with
a back button and a level title. Narrow app bar instead:

- **Leading:** a back button when the level is not Artists, calling `up()`.
- **Title:** the current context — "Artists", the artist's name at Albums, the album's title at
  Tracks. Bilingual titles use the same `BilingualText` treatment as the rows.
- **Actions:** search (toggles the title area to the `SearchField`), queue (toggles
  `queueExpandedProvider`), and an overflow menu holding Playlists and Settings.

### Android back button

`PopScope(canPop: level == BrowseLevel.artists, onPopInvokedWithResult: ...)` so the hardware/gesture
back walks up the cascade instead of exiting the app, and exits only from the Artists level. This
matters on a phone and is inert on desktop.

## Layer 4 — narrow-width fixes inside the columns

Two known overflow risks, both to be handled the way `queue_panel.dart` already handles its own
(`_queueMetaMinWidth = 560`, `lib/catalog/queue_panel.dart:152`) — a `LayoutBuilder` that drops
optional columns rather than a new layout:

- **`TrackColumn`** renders a trailing `TrackMeta` block (length / added / played) plus a `#` column
  (`lib/catalog/track_column.dart:16-17`, `:207-211`). Below a threshold, drop the meta block from
  both `_TrackListHeader` and the rows.
- **`NowPlayingBar`** is a single `Row` of title/artist, transport, and a seek slider with two time
  labels (`lib/widgets/now_playing_bar.dart:46-126`). Below a threshold, drop the elapsed/duration
  labels — the slider and transport are what matter.

These thresholds are about the widget's own width, not the shell's, so they stay local `LayoutBuilder`s
and also improve the wide layout when a pane is dragged narrow.

## What this does not change

The cascade, `ResizableSplit`, ratio persistence (`layout.artists`, `layout.right_pane`), the queue
panel's own behaviour, all three columns' content and context menus, search, and every provider
except the added `SelectedArtist.clear()`. The wide path must be byte-for-byte the same experience.

## Testing

**Unit — `test/browse_level_test.dart` (new):** the derivation table (no artist → artists; artist but
no album → albums; both → tracks; track set → tracks); `up()` from each level clears exactly one
level; `up()` at Artists is a no-op; setting all three at once (the `selectHit` shape) yields Tracks.

**Widget — `test/browse_narrow_layout_test.dart` (new):** at a 400×800 surface — no `ResizableSplit`
in the tree; the artist list is shown; selecting an artist swaps to the album list and shows a back
button; back returns to artists; the queue action shows the queue full-screen; `SearchResultsPanel`
still renders over it.

**Widget — existing:** `test/browser_page_layout_test.dart` (1000×800) and
`browser_page_resize_test.dart` (800×600) must pass **unchanged**, including
`find.byType(ResizableSplit) findsNWidgets(2)`. If either needs editing, the breakpoint or the
extraction is wrong.

**Regression — a boundary test:** 599 vs 601 dp picks narrow vs wide, so the breakpoint is pinned
against accidental change.

## Out of scope

The medium tier (600–900: artists beside a stacked album/track pane) — worth revisiting once the two
ends are right. Also: any phone-specific navigation gestures, a redesigned now-playing screen, and
the queue panel's internal layout beyond what it already does.
