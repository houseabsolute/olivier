# Reading Classifier: Per-Track Non-Latin Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify a romanized alt as a *reading* only for tracks whose original title is non-Latin, deciding per edition over only that non-Latin subset — so mixed albums (mostly-English with a few JP tracks) classify their JP tracks correctly.

**Architecture:** Add pure, unit-testable helpers to `rust/src/enrich/select.rs` (`is_non_latin`, `resolve_edition_kind`, `store_alt_for`) and rework `apply_edition_alts` (`rust/src/enrich/run.rs`) to build a `recording → original title` map from the original release (already in `editions`), run the dictionary decision over only the non-Latin-original titles, and gate `translit` storage to those titles.

**Tech Stack:** Rust (std `HashSet`/`HashMap`). No FFI change → no bridge regen. Builds on the merged reading-classifier (`correct_alt_kind`, `english_words`).

**Commands:** `cd rust && cargo test`; `just lint --all`.

**Conventions:** NEVER `git add` the `TODO` file or any `#TODO#`. Commit messages: plain imperative + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Task order:** 1 (pure helpers + tests) → 2 (wire into `apply_edition_alts`).

---

### Task 1: Pure gate helpers

**Files:**
- Modify: `rust/src/enrich/select.rs`
- Test: `rust/tests/reading_per_track_test.rs`

- [ ] **Step 1: Write the failing tests**

Create `rust/tests/reading_per_track_test.rs`:

```rust
use rust_lib_olivier::enrich::select::{
    english_words, is_non_latin, resolve_edition_kind, store_alt_for, AltKind,
};
use std::collections::HashSet;

fn dict(words: &[&str]) -> HashSet<String> {
    words.iter().map(|w| w.to_string()).collect()
}

#[test]
fn is_non_latin_detects_original_script() {
    assert!(is_non_latin("夜の探検")); // Japanese original
    assert!(is_non_latin("歌舞伎町の女王"));
    assert!(is_non_latin("夜のNight")); // mixed, still mostly non-Latin
    assert!(!is_non_latin("ingredients")); // English original
    assert!(!is_non_latin("Yoru no Tanken")); // a romanization is Latin
    assert!(!is_non_latin("")); // empty
    assert!(!is_non_latin("12:34")); // no letters
}

#[test]
fn resolve_edition_kind_uses_only_the_subset() {
    let d = dict(&["no", "night", "of", "the"]);
    // Non-Latin subset is romaji -> reading, even though MB said translation.
    assert_eq!(
        resolve_edition_kind(AltKind::Translate, &["Yoru no Tanken", "Kiseki"], &d),
        AltKind::Translit
    );
    // Empty subset (all-Latin album) keeps MB's classification.
    assert_eq!(
        resolve_edition_kind(AltKind::Translate, &[], &d),
        AltKind::Translate
    );
    // A translated (English) subset stays a translation.
    assert_eq!(
        resolve_edition_kind(AltKind::Translate, &["Night of the"], &d),
        AltKind::Translate
    );
}

#[test]
fn store_alt_for_gates_readings_to_non_latin() {
    assert!(store_alt_for(AltKind::Translit, true)); // JP original -> store reading
    assert!(!store_alt_for(AltKind::Translit, false)); // English original -> skip reading
    assert!(store_alt_for(AltKind::Translate, true)); // translations stored for all
    assert!(store_alt_for(AltKind::Translate, false));
}

#[test]
fn mixed_album_only_non_latin_tracks_get_readings() {
    // chilldspot scenario: 3 JP tracks + many English tracks; MB tagged the
    // romanized edition a translation. Only the JP subset decides the kind.
    let d = english_words();
    let non_latin_alts = ["Yoru no Tanken", "Hajimari no Uta", "Kiseki"];
    let kind = resolve_edition_kind(AltKind::Translate, &non_latin_alts, d);
    assert_eq!(kind, AltKind::Translit);
    assert!(store_alt_for(kind, true)); // a JP track -> reading
    assert!(!store_alt_for(kind, false)); // an English track -> no reading
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd rust && cargo test --test reading_per_track_test`
Expected: FAIL to compile — `cannot find function is_non_latin` (etc.).

- [ ] **Step 3: Implement the helpers**

In `rust/src/enrich/select.rs`, add after `correct_alt_kind` (the `HashSet` import already exists from the reading-classifier feature):

```rust
/// True when [title] is written predominantly in a non-Latin script — i.e. its
/// romanized alt would be a genuine reading. Empty or letterless titles are not
/// non-Latin. (A romanization like "Yoru no Tanken" is Latin, so this is false.)
pub fn is_non_latin(title: &str) -> bool {
    title.chars().any(|c| c.is_alphabetic()) && ascii_latin_ratio(title) < 0.8
}

/// Resolve an edition's reading-vs-translation kind from the romanized alts of
/// ONLY its non-Latin-original titles. An empty subset (an all-Latin album)
/// keeps MB's classification.
pub fn resolve_edition_kind(
    mb_kind: AltKind,
    non_latin_alts: &[&str],
    dict: &HashSet<String>,
) -> AltKind {
    if non_latin_alts.is_empty() {
        mb_kind
    } else {
        correct_alt_kind(mb_kind, non_latin_alts, dict)
    }
}

/// Whether to store a title's alt, given the edition's resolved kind and whether
/// that title's ORIGINAL is non-Latin. Readings are stored only for non-Latin
/// originals; translations are stored for all.
pub fn store_alt_for(kind: AltKind, original_is_non_latin: bool) -> bool {
    match kind {
        AltKind::Translit => original_is_non_latin,
        AltKind::Translate => true,
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rust && cargo test --test reading_per_track_test`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint + commit**

Run: `just lint --all` (expect PASS), then:

```bash
git add rust/src/enrich/select.rs rust/tests/reading_per_track_test.rs
git commit -m "$(cat <<'EOF'
Add per-track non-Latin gate helpers

is_non_latin (original-script test), resolve_edition_kind (decide over only
the non-Latin subset), and store_alt_for (gate readings to non-Latin
originals), with unit tests including the mixed-album case.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Apply the gate in `apply_edition_alts`

**Files:**
- Modify: `rust/src/enrich/run.rs`
- Possibly update: `rust/tests/enrich_test.rs` (only if a fixture expectation changes)

- [ ] **Step 1: Import the helpers**

In `rust/src/enrich/run.rs`, change the `crate::enrich::select` import to add `is_non_latin`, `resolve_edition_kind`, `store_alt_for` (keep `classify_from_text_representation`, `correct_alt_kind`, `english_words`, `select_transliteration`). Also add `use std::collections::HashMap;` if not already imported.

- [ ] **Step 2: Build the original-title map + gate the loop**

In `apply_edition_alts`, after `ordered.sort_by(...)` and before `for ed in ordered {`, insert the original-title map (the original release is `release_mbid`, present in `editions`):

```rust
    // The original release supplies each track's ORIGINAL-script title, which
    // decides whether a romanized alt is a genuine reading (non-Latin original)
    // or just the English original repeated. If the original release isn't in
    // the browse, the map is empty -> nothing is treated as non-Latin -> no
    // readings are invented (safe fallback to MB's classification).
    let original = editions.iter().find(|ed| ed.id == release_mbid);
    let original_album_title: &str = original.map_or("", |o| o.title.as_str());
    let mut original_titles: HashMap<&str, &str> = HashMap::new();
    if let Some(o) = original {
        for medium in &o.media {
            for tr in &medium.tracks {
                if let Some(rec) = &tr.recording {
                    original_titles.insert(rec.id.as_str(), tr.title.as_str());
                }
            }
        }
    }
    let track_non_latin = |tr: &MbTrack| -> bool {
        tr.recording
            .as_ref()
            .and_then(|r| original_titles.get(r.id.as_str()))
            .is_some_and(|orig| is_non_latin(orig))
    };
```

Then replace the loop body (currently lines ~408-441, from `let Some(kind) = classify_from_text_representation...` through the `log.line(...)` call) with:

```rust
        let Some(mb_kind) = classify_from_text_representation(ed.text_representation.as_ref())
        else {
            continue;
        };
        // Decide reading-vs-translation over ONLY the non-Latin-original titles.
        let album_non_latin = is_non_latin(original_album_title);
        let mut non_latin_alts: Vec<&str> = Vec::new();
        if album_non_latin {
            non_latin_alts.push(ed.title.as_str());
        }
        for medium in &ed.media {
            for tr in &medium.tracks {
                if track_non_latin(tr) {
                    non_latin_alts.push(tr.title.as_str());
                }
            }
        }
        let kind = resolve_edition_kind(mb_kind, &non_latin_alts, english_words());

        // Store, gating readings to non-Latin originals.
        if store_alt_for(kind, album_non_latin) {
            store::upsert_release_alt(conn, release_mbid, kind, &ed.title)?;
        }
        let mut n_tracks = 0usize;
        for medium in &ed.media {
            for tr in &medium.tracks {
                if let Some(rec) = &tr.recording {
                    if store_alt_for(kind, track_non_latin(tr)) {
                        store::upsert_track_alt(conn, &rec.id, kind, &tr.title)?;
                        n_tracks += 1;
                    }
                }
            }
        }
        let kind_label = match kind {
            AltKind::Translit => "reading",
            AltKind::Translate => "translation",
        };
        log.line(
            "APPLY",
            &format!(
                "release \"{title}\": {kind_label} title \"{}\" (+{n_tracks} track titles)",
                ed.title
            ),
        );
```

(If `AltKind` isn't already in scope in `run.rs`, reference it via `crate::enrich::select::AltKind` in the `match`, matching the existing style, or add it to the import.)

- [ ] **Step 3: Build + run the full Rust suite**

Run: `cd rust && cargo build` then `cd rust && cargo test`
Expected: compiles; all pass. The existing `enrich_test.rs` fixture is a pure-Japanese album (歌舞伎町の女王 / 無罪モラトリアム originals), so every track + the album title are non-Latin originals — readings are still stored and its assertions hold unchanged.

- [ ] **Step 4: If an existing enrich assertion changed**

Only if Step 3 shows a failure in `enrich_test.rs`: it means that fixture has an English-original title in a reading edition that previously received a (spurious) reading. Update that assertion to expect no `translit` row for the English-original title (the corrected, gated behavior). Do not weaken any Japanese-track assertion. (Expected: no change needed.)

- [ ] **Step 5: Lint + commit**

Run: `just lint --all` (expect PASS), then:

```bash
git add rust/src/enrich/run.rs
git commit -m "$(cat <<'EOF'
Gate readings to non-Latin-original titles per edition

apply_edition_alts builds a recording->original-title map from the original
release, decides reading-vs-translation over only the non-Latin-original
titles, and stores translit alts only for those titles. Mixed albums
(mostly English + a few JP tracks) now classify their JP tracks correctly.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `cd rust && cargo test` — all green (incl. `reading_per_track_test` and the existing enrich suite).
- [ ] `just lint --all` — green.
- [ ] Manual (optional): re-fetch chilldspot's *ingredients* → the JP tracks (e.g. 夜の探検) show their romaji as a *reading*; English-titled tracks are unaffected.

## Touched files

| File | Change |
|------|--------|
| `rust/src/enrich/select.rs` | `is_non_latin`, `resolve_edition_kind`, `store_alt_for` |
| `rust/src/enrich/run.rs` | per-track non-Latin gate in `apply_edition_alts` |
| `rust/tests/reading_per_track_test.rs` | gate helper unit tests (new) |
| `rust/tests/enrich_test.rs` | only if a fixture expectation changes (likely none) |
