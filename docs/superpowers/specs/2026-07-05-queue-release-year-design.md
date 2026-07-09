# Album Release Year in the Queue — Design

**Date:** 2026-07-05
**Status:** Approved

## Goal

Show each track's **album release year** in the expanded queue, appended to the album cell (e.g.
`Dark Side of the Moon (1973)`). The year is already in the catalog DB and already surfaced in the
*browser* (`Album.originalYear` / `reissueYear`), but `QueueTrack` — the model the queue panel uses —
doesn't carry it. So this plumbs the year through the `tracks_for_paths` FFI + `QueueTrack` struct,
regenerates the bridge, and renders it.

## Decisions (agreed)

- **Which year:** original release year, falling back to the reissue year — i.e. Dart
  `originalYear ?? reissueYear`, matching the browser's album column
  (`lib/catalog/album_column.dart:96`). Both values are exposed on `QueueTrack` (data-faithful,
  mirrors the browser); the fallback is done in the UI, not in SQL.
- **Placement:** appended to the album column of each expanded-queue row.
- **Scope:** expanded queue rows only (the flat track list) — **not** the collapsed now-playing bar.

## Data source (already in the DB)

- `release_group.first_release_date` (TEXT) — the album's original release date.
- `release.date` (TEXT) — this specific release/pressing's date.

The browser's catalog queries already derive the year with `substr(rg.first_release_date, 1, 4)` and
`substr(r.date, 1, 4)` (`rust/src/catalog/query.rs:182`, `:496`); this design reuses those exact
expressions for `tracks_for_paths`.

## Layer 1 — Rust: carry the year on `QueueTrack`

### `rust/src/catalog/schema.rs` (`QueueTrack`, ~line 99)

Add two fields (mirroring the browser model's `original_year` / `reissue_year`):

```rust
    pub original_year: Option<String>,
    pub reissue_year: Option<String>,
```

### `rust/src/catalog/query.rs` (`tracks_for_paths`, ~line 376)

- Add a join: `LEFT JOIN release_group rg ON rg.mbid = r.release_group_mbid`.
- Add two selected columns after the existing ones: `substr(rg.first_release_date, 1, 4)` and
  `substr(r.date, 1, 4)`.
- Populate `original_year` / `reissue_year` from those columns in the **found** branch; set both to
  `None` in the **not-found** fallback `QueueTrack` (the path-not-in-catalog case).

The join is `LEFT` so a track whose release has no release_group still returns a row (year `NULL`).

## Layer 2 — Regenerate the bridge

Run `mise exec -- flutter_rust_bridge_codegen generate`. This regenerates `rust/src/frb_generated.rs`
and `lib/src/rust/**`; `QueueTrack` in `lib/src/rust/catalog/schema.dart` gains
`final String? originalYear;` and `final String? reissueYear;` (nullable ⇒ optional constructor
params, so existing `QueueTrack(...)` call sites — including tests — keep compiling unchanged). The
generated files are committed.

## Layer 3 — Dart: append the year to the album cell

### `lib/catalog/queue_panel.dart` (the expanded-row album `Text`, ~line 453)

Currently:

```dart
album: Text(
  t.album,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: muted,
),
```

The `itemBuilder` already has `t` in scope, so compute a local `albumLabel` alongside the existing
`final t = view.tracks[i];` / `final selected = …` locals, and pass it to the album `Text`:

```dart
final year = t.originalYear ?? t.reissueYear ?? '';
final albumLabel = year.isEmpty ? t.album : '${t.album} ($year)';
```
```dart
album: Text(
  albumLabel,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: muted,
),
```

The `' ($year)'` format matches the browser suffix exactly.

## Edge cases

- **No year at all** (`originalYear` and `reissueYear` both null/empty) → the bare album, unchanged.
- **Original missing, reissue present** → shows the reissue year (the `??` fallback).
- **Empty-string year** (`substr` of an empty date) → treated as absent via `year.isEmpty`; this
  mirrors the browser, which uses the same `?? ''` + is-empty guard.
- **Track not in catalog** (path-only fallback `QueueTrack`) → both years `None` → bare filename/album
  as today.
- **Long album title** → the appended `(YYYY)` can be ellipsized away on a very narrow column, exactly
  as the browser's album column behaves. Accepted (keeps the queue consistent with the browser).

## Testing

**Rust — `rust/tests/queue_release_year_test.rs`** (new; mirror the seeding style of
`rust/tests/title_override_test.rs` / `catalog_test.rs`, using `open(":memory:")`):

- Seed `artist`, `release_group('RG', …, first_release_date='1973-03-01')`,
  `release('R', release_group_mbid='RG', …, date='2011-09-26')`, a `track(release_mbid='R')`, and a
  `file(path, track_id)`.
- `tracks_for_paths(&conn, &["/p.flac".into()])` → assert `original_year == Some("1973")` and
  `reissue_year == Some("2011")`.
- A second case: a release with **no** release_group and no `date` → both year fields `None` (the
  track still returns).

**Dart — `test/queue_release_year_test.dart`** (new; widget test over `QueuePanel`, expanded, using
the stub `QueueView` pattern from `test/queue_row_info_test.dart` / `queue_hide_played_test.dart`):

- A row whose `QueueTrack.originalYear == '1973'` shows text containing `Album (1973)`.
- A row with `originalYear == null, reissueYear == '2011'` shows `Album (2011)` (fallback).
- A row with both null shows the bare `Album` (no parentheses).

## Files

- Modify: `rust/src/catalog/schema.rs` — two fields on `QueueTrack`.
- Modify: `rust/src/catalog/query.rs` — join + two selects + populate both branches.
- Regenerate: `rust/src/frb_generated.rs`, `lib/src/rust/**` (via codegen).
- Modify: `lib/catalog/queue_panel.dart` — compose the year into the album cell.
- Create: `rust/tests/queue_release_year_test.rs`, `test/queue_release_year_test.dart`.

## Out of scope

The collapsed now-playing bar, a dedicated year column, any change to the browser columns or to how
the year is stored/scanned/enriched.
</content>
