# Artist Latin-Name Reading Fallback — Design Spec

**Date:** 2026-06-25
**Status:** Approved in brainstorming — pending spec review

## Goal

When MusicBrainz gives an artist a non-Latin original name but no Latin reading,
display the artist's Latin tag name as the lead line (with the original-script
name as the secondary), instead of collapsing to original-script only. Concretely:
柚楽弥衣 / 湯木慧 artists like "Yayoi Yula" / "Akira Yuki" should read **Yayoi Yula**
(primary) · **柚楽弥衣** (secondary), matching how artists such as "Kenichi Asai"
already display.

## Background

An artist row stores three relevant fields (`rust/src/db.rs` artist table):
- `name` — the tag-derived album-artist name (often the *Latin romanization*,
  e.g. "Yayoi Yula", written by the user's tagger into `ALBUMARTIST`).
- `name_original` — the MusicBrainz original-script name (e.g. 柚楽弥衣), written by
  enrichment.
- `transliteration` — the MusicBrainz reading (romaji), written by enrichment.

The artist row displays as `BilingualText(original: name_original ?? name,
translit: transliteration, …)` (`lib/catalog/artist_column.dart:128`), and
`resolveBilingual` (`lib/widgets/bilingual_text.dart`) under the default layout A
leads with the reading and puts the original second.

`select_transliteration` (`rust/src/enrich/select.rs`) picks the reading in tiers:
tier 1/2 take an English-locale "Artist name" alias; **tier 3** (no such alias)
falls back to MB's entity sort-name and sets `from_entity_sort_name = true`.
`apply_artist_transliteration` (`rust/src/enrich/store.rs:45`) then **deliberately
stores `transliteration = NULL` in the tier-3 case** — correctly, because MB's
sort-name is a "Surname, Given" *sort key*, not a display reading.

The bug: in that tier-3 case the bilingual row has `original = name_original`
(non-Latin) and `translit = NULL`, so it collapses to the Japanese only — even
though the Latin romanization is sitting right there in `name`. **176 artists**
in the user's library are affected, and all 176 have a Latin `name`.

**Albums and tracks are NOT affected** (verified): they have a single `title`
field (the tag original, never overwritten by enrichment) plus translit/translate
*alts*. There is no separate "original from MB" field to override the tag title,
so when a Latin form exists (the tag title itself, or a translit/translate alt)
the display already leads with it under layout A. The only album/track titles
shown original-only are those with no Latin form anywhere — acceptable (out of
scope; we do not algorithmically romanize).

## Decision

Fix it at the **enrichment layer**: in the tier-3 branch, use the artist's Latin
tag `name` as the reading. This makes the `transliteration` field correct, so
every consumer (artist column, queue, search, info popups) renders correctly with
**no display-code changes**. Existing artists are corrected by a **Re-fetch from
MusicBrainz** (force), which re-applies the artist logic to all artists.

## Architecture

### `rust/src/enrich/store.rs` — `apply_artist_transliteration`

Replace the tier-3 `None` with the Latin-tag-name fallback. Add
`use crate::enrich::select::is_non_latin;`.

```rust
let transliteration: Option<String> = if chosen.from_entity_sort_name {
    // Tier 3: MB gave only a "Surname, Given" sort key, never a reading. But the
    // tag-derived `name` is often a Latin romanization of the non-Latin original
    // — use it as the reading so the bilingual row leads with the Latin name.
    // Guard: only when `name` is Latin-script and differs from the original, so
    // we never duplicate the original or store a non-Latin string as a reading.
    let name: String = conn.query_row(
        "SELECT name FROM artist WHERE mbid = ?1",
        rusqlite::params![artist_mbid],
        |r| r.get(0),
    )?;
    (!name.is_empty() && !is_non_latin(&name) && name != original_name).then_some(name)
} else {
    Some(chosen.name.clone())
};
conn.execute(
    "UPDATE artist SET transliteration = ?1, sort_name = ?2, name_original = ?3 WHERE mbid = ?4",
    rusqlite::params![transliteration, chosen.sort_name, original_name, artist_mbid],
)?;
```

`is_non_latin` (`select.rs`) is the existing predicate — true when a string is
predominantly non-Latin script. So a Latin tag name ("Yayoi Yula") → kept; a
Japanese tag name → `None` (no spurious reading); a tag name equal to the MB
original → `None` (no duplicate line).

No other production code changes — the `UPDATE` already writes `transliteration`,
and all display/query consumers read it unchanged.

### Applying to existing data

The 176 affected artists are already enriched (they have `name_original`), so a
normal pass skips them. The user runs **Settings → Re-fetch from MusicBrainz**
(force), which selects every artist and re-runs `apply_artist_transliteration`
(reading from `mb_cache`, so little/no network), populating the fallback reading.
Newly scanned/enriched artists get it automatically. No migration.

## Edge cases

- **Latin tag name, non-Latin original** (the 176) → reading = tag name → leads
  with Latin. ✓
- **Non-Latin tag name** (rare) → `is_non_latin` true → reading stays `NULL` →
  original-script only (correct; no Latin exists). ✓
- **Tag name == MB original** → skipped → no duplicate line. ✓
- **Tier 1/2 (MB alias present)** → unchanged (`Some(chosen.name)`). ✓
- **Manual `transliteration_override`** → unaffected; the query already prefers
  `COALESCE(transliteration_override, transliteration)`, and the user's override
  wins regardless. ✓

## Testing

- **Rust** — exercise `apply_artist_transliteration` (or the tier-3 path via the
  enrich test harness) on an in-memory DB:
  - artist seeded with a Latin `name` ("Yayoi Yula") + a tier-3 `ChosenAlias`
    (`from_entity_sort_name = true`) + non-Latin `original_name` ("柚楽弥衣") →
    `transliteration` = "Yayoi Yula".
  - artist with a non-Latin `name` → `transliteration` stays `NULL`.
  - tier-1/2 path (`from_entity_sort_name = false`) → `transliteration` =
    `chosen.name` (unchanged behavior).

## Out of scope

- Album/track titles (already lead with a Latin alt when one exists; no hidden
  Latin form is dropped).
- Algorithmic romanization of titles/names that have no Latin form anywhere.
- The now-playing bar's `mediaItem.artist` string (separate path; not a bilingual
  row — verify during implementation, flag if it needs the same field).
