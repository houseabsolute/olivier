# Reading-vs-Translation Classifier — Design Spec

**Date:** 2026-06-21
**Status:** Approved in brainstorming — pending spec review

## Goal

Fix the case where a romanized (latin-script) alternate title is mislabeled as a *translation* instead of a *reading* — e.g. chilldspot's 夜の探検 / "Yoru no Tanken" shows as a translation. Add a dictionary-based content check that corrects MusicBrainz's classification in the one failing direction.

## Background (the bug)

Alt-title classification lives in `rust/src/enrich/select.rs::classify_from_text_representation`, which trusts MusicBrainz's per-edition `text-representation`: `language=="eng"` (or a non-Latn script) ⇒ `Translate`; `Latn` ⇒ `Translit`. MB tags chilldspot's romaji pseudo-release as English, so `apply_edition_alts` (`rust/src/enrich/run.rs`) stores "Yoru no Tanken" (and its track titles) as a translation. MB's per-edition signal is unreliable for romanizations, and MB often lacks per-track alias data, so a content-based check is needed.

## Decisions (from brainstorming)

- **Conservative corrector, one direction only.** Keep `classify_from_text_representation` as-is. Only when MB returns `Translate` for a **latin-script** edition whose title text is **mostly not English**, reclassify it to `Translit` (reading). MB-`Translit`, non-latin, and genuinely-English editions are untouched. (Chosen over "content decides for all latin alts" and over a combined confidence score.)
- **Per-edition aggregate.** Pool the words across the edition's latin titles (release title + its track titles) for one robust decision per edition — not per individual title (too noisy for short titles).
- **Data source: CC0.** Bundle the comprehensive English word list `en.txt` from [atebits/Words](https://github.com/atebits/Words) (CC0-1.0 — no attribution/share-alike obligations). Comprehensive is deliberate: the corrector only flips when the English fraction is *low*, so a more complete list minimizes the harmful error (flipping a genuine English translation into a reading).

## Architecture

### Bundled dictionary

- Commit the word list at `rust/data/en_words.txt` (downloaded once from atebits/Words `en.txt`, CC0) plus a short `rust/data/README.md` recording the CC0 source.
- Embed it into the binary via `include_str!("../../data/en_words.txt")` and load once into a `HashSet<String>` of lowercased words (a `std::sync::OnceLock` accessor, e.g. `fn english_words() -> &'static HashSet<String>`). No runtime file dependency.

### Corrector (`rust/src/enrich/select.rs`)

New function, unit-testable in isolation:

```
pub fn correct_alt_kind(mb_kind: AltKind, titles: &[&str], dict: &HashSet<String>) -> AltKind
```

Behavior:
1. If `mb_kind != Translate`, return it unchanged.
2. Tokenize all `titles` together: split on non-alphabetic boundaries, lowercase, drop empty/numeric tokens. (ASCII apostrophes inside words are kept so "don't" tokenizes as one word.)
3. **Latin-script guard:** if the alphabetic characters are not predominantly Latin (i.e. the titles are a non-latin translation like Cyrillic/Greek), return `Translate` unchanged.
4. **Min-token guard:** if fewer than 2 tokens, return `Translate` unchanged (too little signal).
5. Compute `fraction = (tokens found in dict) / (total tokens)`.
6. Return `Translit` if `fraction < 0.5` (mostly non-English ⇒ romanization), else `Translate`. The 0.5 threshold is tuned/locked by tests.

Worked examples: "Yoru no Tanken" → only "no" is English (1/3 ≈ 0.33 < 0.5) ⇒ `Translit`. "Night Exploration" → 2/2 ⇒ stays `Translate`. "Ballad of Tokyo" → "ballad"/"of" found, maybe "tokyo" not (≥ 0.5) ⇒ stays `Translate`.

### Integration (`rust/src/enrich/run.rs::apply_edition_alts`)

After `let Some(kind) = classify_from_text_representation(ed.text_representation.as_ref())`, build the edition's latin titles — `ed.title` plus every `ed.media[].tracks[].title` — and pass them through `correct_alt_kind(kind, &titles, english_words())`. Use the corrected kind for both `upsert_release_alt` and `upsert_track_alt`, and for the decision-log label ("reading"/"translation"). The existing import decision log therefore shows the corrected result.

## Edge cases (intended behavior)

- Short titles (< 2 tokens), non-latin editions, and MB-`Translit` editions are left to MB's classification (corrector no-ops).
- Romaji particles that happen to be English words ("no", "to", "ten") slightly raise the fraction, but multi-syllable romaji content words are absent from the list, keeping romaji well under the threshold.
- A romaji title that coincidentally scores high stays mislabeled — no worse than today (no regression); the corrector never makes a correct label wrong in the untouched directions.

## Testing

Rust unit tests in `rust/tests/` (using the real embedded dictionary so "yoru"/"tanken" are absent and "night"/"exploration" present):
- "Yoru no Tanken" + romaji track titles, `mb_kind=Translate` ⇒ `Translit`.
- An English translation ("Night Exploration", etc.), `mb_kind=Translate` ⇒ stays `Translate`.
- `mb_kind=Translit` ⇒ unchanged regardless of content.
- Non-latin titles (e.g. Cyrillic), `mb_kind=Translate` ⇒ unchanged (latin guard).
- Single-token title ⇒ unchanged (min-token guard).
- A direct check that `english_words()` loads and contains common words but not "yoru"/"tanken".

## Rollout / out of scope

- **Rust-only** (enrichment). No `flutter_rust_bridge` regen (no FFI signature change). Existing mislabeled entries are corrected by the existing right-click **"Re-fetch from MusicBrainz"** (`enrichArtist`/`enrichAlbum`), which re-runs `apply_edition_alts`.
- Out of scope: replacing MB's classification wholesale; per-track (non-aggregate) classification; non-English dictionaries / other source languages; automatically re-enriching the whole library.
