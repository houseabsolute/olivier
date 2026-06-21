# Reading Classifier: Per-Track Non-Latin Gate — Design Spec

**Date:** 2026-06-21
**Status:** Approved in brainstorming — pending spec review

## Goal

Refine the reading-vs-translation classifier so a romanized alt is stored as a *reading* only for tracks whose **original** title is non-Latin, and so the reading-vs-translation decision is made over only those non-Latin tracks — not averaged across the whole edition. This fixes mixed albums (e.g. chilldspot's *ingredients*, where only ~3 of N tracks have Japanese titles): today the English-titled tracks dilute the per-edition English-word fraction above the 0.5 threshold, so the romaji tracks never get flipped to readings.

## Background

The merged classifier (`rust/src/enrich/select.rs::correct_alt_kind`, applied in `rust/src/enrich/run.rs::apply_edition_alts`) classifies a whole sibling edition by pooling **all** its latin titles and comparing the English-word fraction to 0.5. On a mostly-English album that pooled fraction stays high, so a few genuinely-romanized tracks are left mislabeled as translations.

## Decisions (from brainstorming)

- **Identify non-Latin tracks by the ORIGINAL title's script.** The original release is already present in `editions` (it is `release_mbid`, currently filtered out of the loop). Build a `recording_id → original title` map from it; a title is "non-Latin" when `ascii_latin_ratio(title) < 0.8` (reusing the existing helper). The album title uses the original release's `.title`.
- **Aggregate over the non-Latin subset.** Per sibling edition, run `correct_alt_kind` over only the non-Latin-original titles' romanized alts. An empty subset (all-English album) means no correction.
- **Readings only for non-Latin titles, in ALL reading editions.** When an edition resolves to `Translit` — whether MB tagged it that way or we corrected it from `Translate` — store the `translit` alt only for non-Latin-original titles; skip Latin-original (English) titles (their romanized alt equals the English original, so there is no real reading). `Translate` editions are unchanged (store all titles as `translate`).
- **Reuse `correct_alt_kind` unchanged** (it already aggregates over whatever titles it is given and keeps its latin/min-token/0.5 logic); the new work lives in `apply_edition_alts`.

## Architecture

All changes are in `rust/src/enrich/` (Rust-only; no FFI signature change → no bridge regen).

### `select.rs`
- Expose the non-Latin test: add `pub fn is_non_latin(title: &str) -> bool { ascii_latin_ratio(title) < 0.8 }` (ascii_latin_ratio already exists, private). `correct_alt_kind` is unchanged.

### `run.rs::apply_edition_alts`
1. Before the edition loop, locate the original release `editions.iter().find(|ed| ed.id == release_mbid)`; build `original_titles: HashMap<&str, &str>` (recording id → original track title) from its media/tracks, and capture `original_album_title` (that release's `.title`). If the original release is not found, the map is empty (safe fallback: nothing is treated as non-Latin → no readings stored → MB classification stands).
2. Per sibling edition, after `mb_kind = classify_from_text_representation(...)`:
   - Collect `non_latin_alts: Vec<&str>` = the edition's album title if `is_non_latin(original_album_title)`, plus each edition track title whose original (looked up by `recording.id`) is non-Latin.
   - `let kind = if non_latin_alts.is_empty() { mb_kind } else { correct_alt_kind(mb_kind, &non_latin_alts, english_words()) };`
3. Store, per title, applying the gate:
   - **Album title:** if `kind == Translit`, store `upsert_release_alt(..., Translit, &ed.title)` only when `is_non_latin(original_album_title)`; otherwise skip. If `kind == Translate`, store as `translate` (unchanged).
   - **Each track:** if `kind == Translit`, store `upsert_track_alt(..., Translit, &tr.title)` only when its original (by `recording.id`) is non-Latin; skip Latin-original tracks. If `kind == Translate`, store as `translate` (unchanged).
4. The decision-log line reflects what was actually stored (resolved kind + the count of titles stored), so skipped Latin titles are not logged as readings.

## Edge cases (intended behavior)

- **All-English album** (no non-Latin originals): `non_latin_alts` empty → no correction; nothing is stored as a reading; translations behave as today.
- **Original release missing from `editions`** (shouldn't happen): empty map → safe fallback to MB classification, no readings invented.
- **Mixed-script title** (e.g. `夜のNight`): `ascii_latin_ratio` handles it proportionally (< 0.8 ⇒ non-Latin).
- **Existing enrich tests:** the gate tightens the `Translit` path, so any fixture that currently expects an English-original track to receive a reading must be updated to reflect the corrected (gated) behavior. JP-album fixtures whose originals are Japanese keep producing readings for their JP tracks.

## Testing

Rust tests (extend `rust/tests/`):
- **Mixed edition:** an original release with both JP-titled and English-titled tracks, plus a romanized sibling edition MB-tagged `Translate`. Assert the JP tracks get `translit`, the English tracks get **no** `translit` alt, and the decision is driven by the JP subset (passes even though most tracks are English).
- **All-English album:** no `translit` alts stored.
- **MB-tagged `Translit` edition with an English-original track:** the English track is skipped (gate applies to all reading editions).
- **Translate edition:** unchanged (all titles stored as `translate`).
- Keep the existing `reading_classifier_test` corrector unit tests (`correct_alt_kind` is unchanged).

## Rollout / out of scope

- Rust-only; applies on the next **"Re-fetch from MusicBrainz"** (existing mislabeled albums are corrected by re-fetching). No bridge regen.
- Out of scope: changing `correct_alt_kind`'s threshold/heuristic; per-title (non-aggregate) decisions; non-English dictionaries; changing `translate`-edition storage for English tracks.
