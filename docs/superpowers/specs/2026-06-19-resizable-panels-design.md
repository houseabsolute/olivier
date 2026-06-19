# Resizable & Persistent Panels — Design

**Date:** 2026-06-19
**Status:** Approved design → ready for implementation plan
**Backlog item:** "Add drag handles to resize each column and vertical chunk in the UI (artists, albums, tracks, queue). These sizes should persist across restarts." (TODO last line)
**Out of scope:** resizing the now-playing bar (fixed `bottomNavigationBar`); per-monitor / multi-window layouts.

## Goal

Let the user drag-resize the browse panels and the queue, and remember the sizes across launches. Today the artist↔right-pane divider is draggable but resets on every launch; the album↔track split is a fixed 50/50; and the queue is capped at 40% of screen height.

## The three resizable boundaries

1. **Artist ↔ right pane** (horizontal). Already a `MultiSplitView` divider in `lib/catalog/browser_page.dart`. The change is purely **persistence** — seed the areas' flex from a saved value and save on drag-end.
2. **Album ↔ track** (vertical). Convert `_RightPane`'s fixed `Column(Expanded/Divider/Expanded)` into a **vertical `MultiSplitView`** with a draggable divider, persisted.
3. **Queue height** (vertical). Keep the queue's collapse/expand toggle. When expanded, the queue panel gets a **draggable top edge** that sets its height (persisted), replacing the fixed `maxHeight: 40%` cap. The browse area above is an `Expanded`, so it yields space as the queue grows. *(Self-contained in `QueuePanel` — a drag handle on its own top border — so the body stays `Column[Expanded(browse), QueuePanel]` and the expand/collapse state isn't lifted out of the panel.)*

## Persistence

A thin layer over the existing settings seams (`getSettingFnProvider` / `setSettingFnProvider` in `lib/state/providers.dart`; both already FFI-backed and overridable in tests). Three string-valued keys in the settings table:

| Key | Value | Meaning |
|-----|-------|---------|
| `layout.artists` | `"<f0>,<f1>"` | flex of [artist, right-pane] |
| `layout.right_pane` | `"<f0>,<f1>"` | flex of [album, track] |
| `layout.queue_height` | `"<px>"` | expanded queue list height in logical pixels |

Flex pairs (resolution-independent) for the columns; a pixel height for the queue (its content is a list, not a proportional split).

**Load:** a `layoutSettingsProvider` (a `FutureProvider`) reads the three keys once via `getSettingFn`, parses them, and falls back to the current defaults (`artists = 1,2`; `right_pane = 1,1`; `queue_height ≈ 240`) for any missing/garbage value. `BrowserPage` seeds the two `MultiSplitViewController`s' `Area(flex: …)` and the queue-height state from the resolved settings. While the future is pending, show the default layout (it resolves in one DB read — no spinner needed; a 1-frame settle from defaults is acceptable).

**Save:** debounced (~300 ms) writes via `setSettingFn`:
- columns — on `MultiSplitView`'s `onDividerDragEnd`, read `controller.areas[i].flex` and write the CSV.
- queue — on the top handle's `onVerticalDragEnd`, write the clamped height.

`AreaHelper.setFlex` is `@internal`, so restore seeds flex through the `Area` constructor (rebuild the controller's areas from the loaded values) rather than mutating areas in place.

## Min / max sizes

Keep the existing mins (artist `min: 220`, right `min: 320`). Add `min: 80` to the album and track areas. Clamp the queue height to `[<header height>, 0.6 * screen height]` so it can't swallow the whole window or shrink below its header.

## Components

- `lib/state/layout_settings.dart` (new): the `LayoutSettings` value (two flex pairs + queue height), a `layoutSettingsProvider` (`FutureProvider<LayoutSettings>`) that loads + parses, and a small `saveLayoutFn` seam (debounced writer) over `setSettingFn`. Pure parsing/formatting helpers (`"1.0,2.0" ↔ (1.0, 2.0)`) are unit-testable without the FFI.
- `lib/catalog/browser_page.dart` (modify): build the artist↔right controller from the loaded flex and save on drag-end; convert the private `_RightPane` widget (in this same file) from its fixed `Column` into a **vertical `MultiSplitView`** (album/track), seeded + saved.
- `lib/catalog/queue_panel.dart` (modify): replace the `maxHeight: 40%` `ConstrainedBox` with a stateful height (seeded from `layout.queue_height`); add a drag handle on the panel's top edge (`GestureDetector` + `onVerticalDragUpdate/End`) that adjusts + clamps + persists the height.

## Error handling

Malformed or absent settings → defaults (never throw). A failed save is swallowed (best-effort, like the rest of settings) — a lost resize is harmless. The queue height is always clamped to the valid range on load and on drag, so a stale value from a larger monitor can't leave the queue off-screen.

## Testing (host-VM, no FFI)

Override `getSettingFnProvider` / `setSettingFnProvider`:
- **Load applied:** with `getSettingFn` returning a stored `layout.artists = "1,3"`, pumping `BrowserPage` yields the artist/right split at that proportion (assert via the controller's area flex, or the rendered widths).
- **Defaults on missing/garbage:** `getSettingFn` returns `null` / `"oops"` → the default layout renders, no exception.
- **Structure:** the album↔track vertical `MultiSplitView` and the queue's drag handle render.
- **Save fires:** invoking the column drag-end callback / the queue handle drag-end calls `setSettingFn` with the expected key + a well-formed value (real divider-drag gestures are awkward to simulate, so the save path is exercised by calling the resize callback directly).
- **Parsing unit tests:** the `"f0,f1"` and pixel parse/format + clamp helpers, including bad input → default.

## Notes / deferred

- Sizes are global (not per-window / per-monitor); a future multi-window build could key them per display.
- The debounce avoids a settings write per drag frame; the final position is what persists.
- Host-VM rule (as elsewhere): persistence is behind the existing injectable settings seams; no real FFI in Dart tests.
