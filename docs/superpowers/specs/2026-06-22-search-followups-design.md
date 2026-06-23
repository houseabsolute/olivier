# Search Follow-ups — Design Spec

**Date:** 2026-06-22
**Status:** Approved in brainstorming — pending spec review

## Goal

Two small polish fixes to the just-merged global search overlay (`docs/superpowers/specs/2026-06-22-search-design.md`), surfaced by its holistic review.

## Fixes

### 1. Overlay keyboard scroll-into-view

**Problem:** Arrowing the highlight (`↑/↓`) past the visible area of the results dropdown leaves the highlighted row scrolled out of sight — the `ListView` in `SearchResultsPanel`'s `_ResultsList` never scrolls to follow the highlight (`highlightedSearchIndexProvider`).

**Fix:** Convert `_ResultsList` from `ConsumerWidget` to `ConsumerStatefulWidget`. Give the currently-highlighted row a `GlobalKey`; on a highlight change (`ref.listen(highlightedSearchIndexProvider)`), schedule a post-frame `Scrollable.ensureVisible(highlightedRowContext, alignment: 0.5, duration: ...)`. `ensureVisible` handles the panel's variable-height children (group headers, footers, one/two-line bilingual rows) without offset math. Attach a `ScrollController` to the `ListView` (or rely on the enclosing `Scrollable` that `ensureVisible` walks to). No change to the keyboard handling itself (still in `SearchField`); this only makes the highlight visible.

### 2. Dismiss the panel when opening Settings

**Problem:** The overlay shows whenever the query is non-empty. Tap-away and `Esc` clear it, but opening Settings (the app-bar button pushes a full-screen route) leaves a stale panel + query underneath; popping back shows the old results.

**Fix:** In `BrowserPage`, clear the search query (`ref.read(searchQueryProvider.notifier).clear()`) when the Settings button is pressed, before pushing `SettingsPage`. Targeted and safe.

**Rejected alternative — general dismiss-on-blur:** clearing the query whenever the field loses focus races with clicking a result row: the tap blurs the field, which would tear the panel down before the row's `onTap` (→ `selectHit`) registers, breaking click-to-navigate. `Esc` + tap-away + this Settings fix cover the real dismissals.

## Out of scope

- **#3 (null album-artist track navigation):** not implemented — it cannot occur. The scanner always writes `release.album_artist_mbid` via `album_artist_key` (`rust/src/catalog/ids.rs`), which returns the real MBID or a synthesized `synth:aa:<name>` key (never null/empty), and the matching artist is in the browse list, so a track hit always resolves the cascade. The column is nullable in schema only defensively.
- General dismiss-on-blur (see above); dropdown changes beyond scroll-into-view; any change to the Rust search query or providers.

## Testing

- **#1:** a widget test pumps `SearchResultsPanel` with enough stubbed hits to overflow `maxHeight: 420`, sets `highlightedSearchIndexProvider` to a deep index, pumps, and asserts the highlighted row is visible (e.g. `find` for its text returns a hittable widget / its render box is within the panel viewport).
- **#2:** a widget test taps the Settings button with a non-empty `searchQueryProvider` and asserts the query is cleared (`searchQueryProvider == ''`). (Use an injected/stub Settings route if needed so the test doesn't depend on the full `SettingsPage` provider stack.)
