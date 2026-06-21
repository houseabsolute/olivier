# Manual Reading/Translation Override — Design Spec

**Date:** 2026-06-21
**Status:** Approved in brainstorming — pending spec review

## Goal

Let the user manually correct a track's or album's reading/translation in the app, to fix any misclassification the automatic classifier (even with the per-track non-Latin gate) still gets wrong. Mirrors the existing per-artist "Set reading…" override, extended to track and album titles with both a reading and a translation field.

## Background

Track/album readings + translations come from `track_title_alt` / `release_title_alt` (keyed by recording/release + `kind` in {`translit`,`translate`}), populated by enrichment and surfaced as `titleTranslit` / `titleTranslate`. The app already has a per-artist override (`artist.transliteration_override`, `COALESCE`d over the enriched value, set via `set_artist_reading_override`, edited in `ArtistReadingDialog`); this feature applies the same idea to track/album titles.

## Decisions (from brainstorming)

- **Editable reading + translation fields** in a dialog (mirroring `ArtistReadingDialog`), for **tracks and albums**, surfaced via the right-click "Set reading…" action.
- **Per-field override semantics:** for each of the reading and translation, the stored override is **NULL = automatic** (use the enriched value), **non-empty text = override**, **empty string = suppress** (display nothing). Suppression is what lets the user fix a misclassification: to move "Yoru no Tanken" from *translation* to *reading*, set Reading = "Yoru no Tanken" and clear Translation (suppressing the wrongly-enriched translation).
- **Overrides survive re-fetch:** re-enrichment writes only `*_title_alt`; it never touches the override tables.

## Architecture

### Persistence (schema migration)

Two override tables (no FK, keyed like the alt tables, so they survive re-home and re-enrich):

```sql
CREATE TABLE track_title_override (
  recording_mbid TEXT PRIMARY KEY,
  translit       TEXT,   -- NULL = automatic, '' = suppress, text = override
  translate      TEXT
);
CREATE TABLE release_title_override (
  release_mbid   TEXT PRIMARY KEY,
  translit       TEXT,
  translate      TEXT
);
```

### Display (`rust/src/catalog/query.rs`)

Every query that currently surfaces `titleTranslit` / `titleTranslate` (track list, album column, queue, now-playing — i.e. the functions producing `Track`, `Album`, `QueueTrack`) `LEFT JOIN`s the matching override table and uses `COALESCE(override.translit, <enriched translit>)` / `COALESCE(override.translate, <enriched translate>)`. Because `COALESCE` treats `''` as a value, a suppress (`''`) shows nothing, an override shows the text, and NULL falls through to the enriched value. The display already treats empty/absent as "no reading/translation".

### Rust API (`rust/src/api/catalog.rs` + `query.rs`)

- Getter for the dialog: `track_title_override(db_path, recording_mbid)` / `release_title_override(db_path, release_mbid)` returning the **enriched** translit/translate plus the current override translit/translate (so the dialog can pre-fill effective values and detect "unchanged"). A small struct (e.g. `TitleAlts { translit, translate, translit_override, translate_override }`).
- Setter: `set_track_title_override(db_path, recording_mbid, translit: Option<String>, translate: Option<String>)` / `set_release_title_override(...)` — upsert the row; when both are `None`, delete the row (fully automatic). `Some("")` persists a suppress; `Some(text)` an override; `None` clears that field.
- These new `pub fn`s require a **flutter_rust_bridge regen**.

### Flutter UI

- A `TitleOverrideDialog` mirroring `ArtistReadingDialog`: two fields (Reading, Translation) pre-filled with the effective values (`COALESCE(override, enriched)`), plus the dialog's save mapping per field:
  - trimmed text equals the enriched value → `null` (automatic),
  - trimmed text empty (but the enriched value was non-empty) → `Some("")` (suppress),
  - otherwise → `Some(text)` (override).
- Seam providers (`setTrackTitleOverrideFnProvider`, `setReleaseTitleOverrideFnProvider`, and the getters), mirroring the artist-reading providers.
- A "Set reading…" item on the track **and** album `RowContextMenu` (`onSetReading` already exists on `RowContextMenu` for artists — reuse the slot), opening the dialog; on save, persist + invalidate `artistsProvider`/`albumsProvider`/`tracksProvider` + `queueControllerProvider.refreshMetadata()` (exactly the artist-dialog refresh).

## Edge cases

- Both fields cleared back to their enriched values (or to empty when nothing was enriched) → row deleted → fully automatic.
- Suppress with no enriched value → treated as automatic (don't persist a pointless `''`).
- Override is keyed by recording/release mbid, so it stays attached if the track is re-homed/re-scanned, exactly like the enriched alts.

## Testing

- **Rust:** set/get round-trip; `COALESCE` precedence (override beats enriched in each display query); suppression (`''` hides the enriched value); deleting the row when fully automatic; a re-enrich leaves the override tables untouched.
- **Flutter:** the dialog's save mapping (unchanged→null, cleared-non-empty→suppress, edited→override) and that "Set reading…" on a track/album opens the dialog and calls the seam with the mapped values.

## Out of scope

- Per-edition or bulk overrides (one override per track/release only); overriding the artist reading (already exists); changing the automatic classifier (that's the gate spec); any free-form metadata editing beyond reading/translation.
