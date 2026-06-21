# Reading-vs-Translation Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct MusicBrainz's misclassification of romanized (latin-script) titles as translations — flip `Translate`→`Translit` when an edition's pooled latin titles are mostly not English — using a bundled CC0 English word list.

**Architecture:** A conservative, content-based corrector added to the enrichment classifier. `classify_from_text_representation` is unchanged; a new `correct_alt_kind` (in `rust/src/enrich/select.rs`) downgrades only MB-`Translate` latin-script editions whose pooled titles fall below an English-word-fraction threshold. The English word set is the CC0 atebits/Words `en.txt`, embedded via `include_str!`.

**Tech Stack:** Rust (std only — `HashSet`, `OnceLock`, `include_str!`). No new crates. No Dart/FFI change → no `flutter_rust_bridge` regen.

**Commands:** Rust tests: `cd rust && cargo test --test reading_classifier_test` (and full `cargo test`). Lint gate: `mise exec -- precious lint --all` (or `just lint --all`).

**Conventions / gotchas:**
- The 2.8 MB word list MUST be excluded from `precious` (like the committed PNGs), or `typos` scans it and fails — Task 1 handles this.
- NEVER `git add` the `TODO` file (the user's live scratchpad, shows as `M TODO`) or any `#TODO#`. Stage only the listed files.
- Commit messages: plain imperative, ending with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Task order:** 1 (bundle the dict + loader) → 2 (the corrector + tests) → 3 (wire into enrichment). Each leaves a compiling, green tree.

---

### Task 1: Bundle the CC0 English word list + loader

**Files:**
- Create: `rust/data/en_words.txt` (downloaded, CC0), `rust/data/README.md`
- Modify: `precious.toml` (exclude the word list), `rust/src/enrich/select.rs` (loader)
- Test: `rust/tests/reading_classifier_test.rs`

- [ ] **Step 1: Download the CC0 word list**

Run:
```bash
mkdir -p rust/data
curl -fsSL https://raw.githubusercontent.com/atebits/Words/master/Words/en.txt -o rust/data/en_words.txt
wc -l rust/data/en_words.txt
```
Expected: downloads ~2.8 MB; `wc -l` reports on the order of ~350k lines (one lowercase word per line). If the `master` URL 404s, retry with `.../Words/main/Words/en.txt`.

- [ ] **Step 2: Add the CC0 credits note**

Create `rust/data/README.md`:

```markdown
# Bundled data

`en_words.txt` is the English word list from https://github.com/atebits/Words
(`Words/en.txt`), released under the Creative Commons CC0 1.0 Universal Public
Domain Dedication. It is embedded into the binary (`include_str!`) and used by
the reading-vs-translation classifier in `src/enrich/select.rs`. No attribution
is required; recorded here for provenance.
```

- [ ] **Step 3: Exclude the word list from precious**

In `precious.toml`, add the word list to the `exclude` array, right after the `"**/*.png"` entry:

```toml
    "**/*.png",                  # committed binary app-icon rasters
    "rust/data/en_words.txt",    # bundled CC0 English word list (atebits/Words)
]
```

- [ ] **Step 4: Write the failing loader test**

Create `rust/tests/reading_classifier_test.rs`:

```rust
use rust_lib_olivier::enrich::select::english_words;

#[test]
fn dictionary_loads_with_expected_membership() {
    let dict = english_words();
    assert!(dict.contains("night"), "common English word should be present");
    assert!(dict.contains("exploration"));
    assert!(!dict.contains("yoru"), "romaji should not be an English word");
    assert!(!dict.contains("tanken"));
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `cd rust && cargo test --test reading_classifier_test`
Expected: FAIL to compile — `cannot find function english_words in ... select` (not implemented yet).

- [ ] **Step 6: Add the loader**

In `rust/src/enrich/select.rs`, add at the top (after the existing `use` line) the std imports, and add the loader function (anywhere after the `AltKind` definition):

```rust
use std::collections::HashSet;
use std::sync::OnceLock;
```

```rust
/// Lowercased English words for the reading-vs-translation content check,
/// bundled from atebits/Words `en.txt` (CC0) and embedded into the binary.
/// Loaded once on first use.
pub fn english_words() -> &'static HashSet<String> {
    static WORDS: OnceLock<HashSet<String>> = OnceLock::new();
    WORDS.get_or_init(|| {
        include_str!("../../data/en_words.txt")
            .lines()
            .map(|w| w.trim().to_ascii_lowercase())
            .filter(|w| !w.is_empty())
            .collect()
    })
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd rust && cargo test --test reading_classifier_test`
Expected: PASS (1 test). Then `cd rust && cargo build` — compiles (the 2.8 MB `include_str!` is fine).

- [ ] **Step 8: Lint**

Run: `just lint --all`
Expected: PASS — confirms `rust/data/en_words.txt` is excluded (without the Step 3 exclude, `typos` would flag thousands of "misspellings" in the word list).

- [ ] **Step 9: Commit**

```bash
git add rust/data/en_words.txt rust/data/README.md precious.toml rust/src/enrich/select.rs rust/tests/reading_classifier_test.rs
git commit -m "$(cat <<'EOF'
Bundle CC0 English word list + loader

Embed atebits/Words en.txt (CC0) and load it once into a HashSet via
english_words(), for the reading-vs-translation content classifier.
Excluded from precious so typos does not scan the word list.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The content corrector

**Files:**
- Modify: `rust/src/enrich/select.rs` (`correct_alt_kind` + helpers)
- Test: `rust/tests/reading_classifier_test.rs`

- [ ] **Step 1: Write the failing corrector tests**

Append to `rust/tests/reading_classifier_test.rs`, and update the import line at the top of the file to:

```rust
use rust_lib_olivier::enrich::select::{correct_alt_kind, english_words, AltKind};
use std::collections::HashSet;
```

Then append:

```rust
fn dict(words: &[&str]) -> HashSet<String> {
    words.iter().map(|w| w.to_string()).collect()
}

#[test]
fn romaji_translation_is_corrected_to_reading() {
    // Only "no" is English; "yoru"/"tanken"/"hajimari"/"uta"/"kiseki" are not.
    let d = dict(&["no", "night", "song"]);
    let titles = ["Yoru no Tanken", "Hajimari no Uta", "Kiseki"];
    assert_eq!(correct_alt_kind(AltKind::Translate, &titles, &d), AltKind::Translit);
}

#[test]
fn english_translation_stays_translation() {
    let d = dict(&["night", "exploration", "song", "of", "the", "beginning"]);
    let titles = ["Night Exploration", "Song of the Beginning"];
    assert_eq!(correct_alt_kind(AltKind::Translate, &titles, &d), AltKind::Translate);
}

#[test]
fn translit_kind_is_never_changed() {
    let d = dict(&["night", "exploration"]);
    // English content, but mb_kind is already Translit -> unchanged.
    let titles = ["Night Exploration"];
    assert_eq!(correct_alt_kind(AltKind::Translit, &titles, &d), AltKind::Translit);
}

#[test]
fn non_latin_titles_keep_mb_classification() {
    let d = dict(&["no"]);
    let titles = ["Ночь", "Песня"]; // Cyrillic translation, not latin
    assert_eq!(correct_alt_kind(AltKind::Translate, &titles, &d), AltKind::Translate);
}

#[test]
fn single_token_keeps_mb_classification() {
    let d = dict(&["no"]);
    let titles = ["Yoru"]; // one token: too little signal
    assert_eq!(correct_alt_kind(AltKind::Translate, &titles, &d), AltKind::Translate);
}

#[test]
fn real_dictionary_corrects_the_chilldspot_case() {
    let titles = ["Yoru no Tanken"];
    assert_eq!(
        correct_alt_kind(AltKind::Translate, &titles, english_words()),
        AltKind::Translit
    );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd rust && cargo test --test reading_classifier_test`
Expected: FAIL to compile — `cannot find function correct_alt_kind`.

- [ ] **Step 3: Implement the corrector + helpers**

In `rust/src/enrich/select.rs`, add (after `english_words`):

```rust
/// Fraction of alphabetic characters that are ASCII letters (0.0 if none).
/// Gates the English check to latin-script titles: a Cyrillic/Greek translation
/// scores ~0 and keeps MB's classification.
fn ascii_latin_ratio(text: &str) -> f64 {
    let mut alpha = 0usize;
    let mut ascii = 0usize;
    for c in text.chars() {
        if c.is_alphabetic() {
            alpha += 1;
            if c.is_ascii_alphabetic() {
                ascii += 1;
            }
        }
    }
    if alpha == 0 {
        0.0
    } else {
        ascii as f64 / alpha as f64
    }
}

/// Split latin text into lowercase word tokens: maximal runs of ASCII letters,
/// keeping an apostrophe inside a word ("don't" stays one token) and trimming
/// any leading/trailing apostrophes.
fn tokenize(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for c in text.chars() {
        if c.is_ascii_alphabetic() {
            cur.push(c.to_ascii_lowercase());
        } else if c == '\'' && !cur.is_empty() {
            cur.push(c);
        } else if !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out.into_iter()
        .map(|w| w.trim_matches('\'').to_string())
        .filter(|w| !w.is_empty())
        .collect()
}

/// Correct MB's classification in the one failing direction: when MB says
/// `Translate` for a latin-script edition whose pooled titles are mostly NOT
/// English (a romanization MB mislabeled as a translation), return `Translit`.
/// Every other case is returned unchanged.
pub fn correct_alt_kind(mb_kind: AltKind, titles: &[&str], dict: &HashSet<String>) -> AltKind {
    if mb_kind != AltKind::Translate {
        return mb_kind;
    }
    let combined = titles.join(" ");
    // Latin-script guard: leave non-latin translations to MB.
    if ascii_latin_ratio(&combined) < 0.8 {
        return AltKind::Translate;
    }
    let tokens = tokenize(&combined);
    // Min-token guard: too little signal to override MB.
    if tokens.len() < 2 {
        return AltKind::Translate;
    }
    let found = tokens.iter().filter(|t| dict.contains(t.as_str())).count();
    let fraction = found as f64 / tokens.len() as f64;
    if fraction < 0.5 {
        AltKind::Translit
    } else {
        AltKind::Translate
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rust && cargo test --test reading_classifier_test`
Expected: PASS (7 tests: the loader test + 6 corrector tests).

- [ ] **Step 5: Lint**

Run: `just lint --all`
Expected: PASS (clippy `-D warnings`, rustfmt clean).

- [ ] **Step 6: Commit**

```bash
git add rust/src/enrich/select.rs rust/tests/reading_classifier_test.rs
git commit -m "$(cat <<'EOF'
Add reading-vs-translation content corrector

correct_alt_kind flips MB Translate -> Translit for latin-script editions
whose pooled titles are mostly not English (English-word fraction < 0.5),
with latin-script and min-token guards. MB-correct cases are untouched.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire the corrector into enrichment

**Files:**
- Modify: `rust/src/enrich/run.rs` (`apply_edition_alts`)

- [ ] **Step 1: Import the corrector**

In `rust/src/enrich/run.rs`, change the select import (line 8) from:

```rust
use crate::enrich::select::{classify_from_text_representation, select_transliteration};
```

to:

```rust
use crate::enrich::select::{
    classify_from_text_representation, correct_alt_kind, english_words, select_transliteration,
};
```

- [ ] **Step 2: Apply the correction per edition**

In `apply_edition_alts`, the loop body currently begins:

```rust
    for ed in ordered {
        let Some(kind) = classify_from_text_representation(ed.text_representation.as_ref()) else {
            continue;
        };
        store::upsert_release_alt(conn, release_mbid, kind, &ed.title)?;
```

Insert the correction between the `classify_from_text_representation` line and the `upsert_release_alt` line, so it reads:

```rust
    for ed in ordered {
        let Some(kind) = classify_from_text_representation(ed.text_representation.as_ref()) else {
            continue;
        };
        // Correct MB's classification for romanizations it mislabels as
        // translations (e.g. "Yoru no Tanken"): pool this edition's latin titles
        // (release + tracks) for one robust per-edition decision.
        let mut titles: Vec<&str> = vec![ed.title.as_str()];
        for medium in &ed.media {
            for tr in &medium.tracks {
                titles.push(tr.title.as_str());
            }
        }
        let kind = correct_alt_kind(kind, &titles, english_words());
        store::upsert_release_alt(conn, release_mbid, kind, &ed.title)?;
```

The rest of the loop (the track upserts and the `kind_label` decision-log line) is unchanged and now uses the corrected `kind`.

- [ ] **Step 3: Build + run the full Rust suite**

Run: `cd rust && cargo build` then `cd rust && cargo test`
Expected: compiles; ALL tests pass (the new reading_classifier_test plus the existing enrich tests — `apply_edition_alts`'s callers are unaffected because correction only changes a latin Translate→Translit when content is non-English, and the existing enrich fixtures are English/standard editions).

- [ ] **Step 4: Lint**

Run: `just lint --all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rust/src/enrich/run.rs
git commit -m "$(cat <<'EOF'
Apply the reading corrector in enrichment

apply_edition_alts now runs correct_alt_kind on each edition's pooled
latin titles, so a romanization MusicBrainz mislabels as a translation is
stored as a reading. Re-fetching an album/artist applies it.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (before finishing the branch)

- [ ] `cd rust && cargo test` — all Rust tests green (incl. `reading_classifier_test` and the existing enrich suite).
- [ ] `just lint --all` — whole-project gate green (the word list excluded from typos).
- [ ] `mise exec -- flutter test` — full Dart suite still green (no Dart change; confirms no regression).
- [ ] Manual smoke (optional, `just run`): right-click chilldspot's 夜の探検 album/artist → "Re-fetch from MusicBrainz"; "Yoru no Tanken" now displays as a reading, not a translation.

## Touched files

| File | Change |
|------|--------|
| `rust/data/en_words.txt` | bundled CC0 English word list (new) |
| `rust/data/README.md` | CC0 provenance note (new) |
| `precious.toml` | exclude the word list from linting |
| `rust/src/enrich/select.rs` | `english_words` loader + `correct_alt_kind` + helpers |
| `rust/src/enrich/run.rs` | apply the corrector per edition in `apply_edition_alts` |
| `rust/tests/reading_classifier_test.rs` | loader + corrector unit tests (new) |
