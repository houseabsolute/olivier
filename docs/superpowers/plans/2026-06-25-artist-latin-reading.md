# Artist Latin-Name Reading Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When MusicBrainz gives an artist no English alias (tier 3), store the artist's Latin tag `name` as the bilingual reading instead of `NULL`, so the row leads with the Latin name + original-script secondary.

**Architecture:** A single change in `apply_artist_transliteration` (`rust/src/enrich/store.rs`): in the `from_entity_sort_name` (tier-3) branch, fall back to the catalog `name` as the reading when it is Latin-script and differs from the MB original. No display or query changes — every consumer reads the now-correct `transliteration`. Existing data is corrected by the user's "Re-fetch from MusicBrainz".

**Tech Stack:** Rust + rusqlite; the existing `is_non_latin` predicate from `rust/src/enrich/select.rs`.

**Spec:** `docs/superpowers/specs/2026-06-25-artist-latin-reading-design.md`

**Conventions:** Rust tests via `cd rust && cargo test`. Lint gate: `just lint --all` (run it before committing — it covers clippy/rustfmt that `cargo test` does not). NEVER `git add` the `TODO` file (and don't touch the stray untracked `#TODO#` autosave file). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `rust/src/enrich/store.rs` (modify) — the tier-3 reading fallback in `apply_artist_transliteration`.
- `rust/tests/artist_reading_test.rs` (create) — unit tests for the three branches.

---

## Task 1: Tier-3 Latin-name reading fallback

**Files:**
- Modify: `rust/src/enrich/store.rs`
- Test: `rust/tests/artist_reading_test.rs` (create)

Context — the function today (`rust/src/enrich/store.rs`):
```rust
pub fn apply_artist_transliteration(
    conn: &Connection,
    artist_mbid: &str,
    chosen: &ChosenAlias,
    original_name: &str,
) -> anyhow::Result<()> {
    // ... snapshots sort_name_embedded ...
    let transliteration: Option<&str> = if chosen.from_entity_sort_name {
        None
    } else {
        Some(&chosen.name)
    };
    conn.execute(
        "UPDATE artist SET transliteration = ?1, sort_name = ?2, name_original = ?3 WHERE mbid = ?4",
        rusqlite::params![transliteration, chosen.sort_name, original_name, artist_mbid],
    )?;
    Ok(())
}
```
`ChosenAlias` (`rust/src/enrich/select.rs`) has public fields `name: String`, `sort_name: String`, `from_entity_sort_name: bool`. `is_non_latin(&str) -> bool` is public in the same module.

- [ ] **Step 1: Write the failing test** — create `rust/tests/artist_reading_test.rs`:

```rust
use rust_lib_olivier::db::open;
use rust_lib_olivier::enrich::select::ChosenAlias;
use rust_lib_olivier::enrich::store::apply_artist_transliteration;

fn seed_artist(conn: &rusqlite::Connection, mbid: &str, name: &str) {
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES (?1, ?2, ?2)",
        rusqlite::params![mbid, name],
    )
    .unwrap();
}

fn translit_of(conn: &rusqlite::Connection, mbid: &str) -> Option<String> {
    conn.query_row(
        "SELECT transliteration FROM artist WHERE mbid = ?1",
        [mbid],
        |r| r.get(0),
    )
    .unwrap()
}

fn tier3(sort: &str) -> ChosenAlias {
    ChosenAlias {
        name: sort.to_string(),
        sort_name: sort.to_string(),
        from_entity_sort_name: true,
    }
}

#[test]
fn tier3_latin_tag_name_becomes_the_reading() {
    let conn = open(":memory:").unwrap();
    seed_artist(&conn, "A1", "Yayoi Yula"); // tag name is the romanization
    apply_artist_transliteration(&conn, "A1", &tier3("Yula, Yayoi"), "柚楽弥衣").unwrap();

    assert_eq!(translit_of(&conn, "A1").as_deref(), Some("Yayoi Yula"));
    let orig: Option<String> = conn
        .query_row("SELECT name_original FROM artist WHERE mbid='A1'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(orig.as_deref(), Some("柚楽弥衣"));
}

#[test]
fn tier3_non_latin_tag_name_stays_null() {
    let conn = open(":memory:").unwrap();
    seed_artist(&conn, "A2", "日本語名"); // tag name is itself non-Latin: no usable reading
    apply_artist_transliteration(&conn, "A2", &tier3("Sort, Key"), "柚楽弥衣").unwrap();

    assert_eq!(translit_of(&conn, "A2"), None);
}

#[test]
fn tier1_alias_reading_is_unchanged() {
    let conn = open(":memory:").unwrap();
    seed_artist(&conn, "A3", "Kenichi Asai");
    let chosen = ChosenAlias {
        name: "Kenichi Asai".to_string(),
        sort_name: "Asai, Kenichi".to_string(),
        from_entity_sort_name: false, // MB had an English alias
    };
    apply_artist_transliteration(&conn, "A3", &chosen, "浅井健一").unwrap();

    assert_eq!(translit_of(&conn, "A3").as_deref(), Some("Kenichi Asai"));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test --test artist_reading_test`
Expected: `tier3_latin_tag_name_becomes_the_reading` FAILS (today tier-3 stores `NULL`, so the reading is `None`, not `"Yayoi Yula"`). The other two PASS (they pin current behavior).

- [ ] **Step 3: Implement the fallback** — in `rust/src/enrich/store.rs`:

First extend the import. Change:
```rust
use crate::enrich::select::{AltKind, ChosenAlias};
```
to:
```rust
use crate::enrich::select::{is_non_latin, AltKind, ChosenAlias};
```

Then replace the tier-3 `transliteration` computation. Change:
```rust
    let transliteration: Option<&str> = if chosen.from_entity_sort_name {
        None
    } else {
        Some(&chosen.name)
    };
```
to:
```rust
    let transliteration: Option<String> = if chosen.from_entity_sort_name {
        // Tier 3: MB gave only a "Surname, Given" sort key, never a reading. But
        // the tag-derived `name` is often a Latin romanization of the non-Latin
        // original — use it as the reading so the bilingual row leads with the
        // Latin name. Guard: only when `name` is Latin-script and differs from
        // the original, so we never duplicate the original or store a non-Latin
        // string as a reading.
        let name: String = conn.query_row(
            "SELECT name FROM artist WHERE mbid = ?1",
            rusqlite::params![artist_mbid],
            |r| r.get(0),
        )?;
        (!name.is_empty() && !is_non_latin(&name) && name != original_name).then_some(name)
    } else {
        Some(chosen.name.clone())
    };
```

(The `UPDATE` statement below it is unchanged — `rusqlite::params![transliteration, ...]` binds an `Option<String>` the same as the old `Option<&str>`.)

- [ ] **Step 4: Run to verify it passes**

Run: `cd rust && cargo test --test artist_reading_test`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full Rust suite + lint**

Run: `cd rust && cargo test`
Expected: entire suite green (no regression — the existing enrich tests still pass).

Run: `just lint --all`
Expected: PASS (watch clippy — the `.then_some(name)` form avoids a manual `if/else`; rustfmt/clippy clean).

- [ ] **Step 6: Commit**

```bash
git add rust/src/enrich/store.rs rust/tests/artist_reading_test.rs
git commit -m "$(cat <<'EOF'
Use the Latin tag name as the artist reading when MB gives none

In the tier-3 enrichment case (no English MB alias) apply_artist_transliteration
stored transliteration = NULL, so artists with a non-Latin MB name_original but a
Latin tag name (e.g. "Yayoi Yula" / 柚楽弥衣) displayed original-script only. Now it
falls back to the Latin tag name as the reading (when it is Latin and differs
from the original), so the bilingual row leads with the Latin name. Existing
artists pick this up on a Re-fetch from MusicBrainz.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Definition of Done

- Tier-3 artists with a Latin tag name get `transliteration` = that name (verified by test); non-Latin tag names stay `NULL`; tier-1/2 behavior unchanged.
- Full Rust suite green; `just lint --all` clean.
- (Manual, by the user) a Re-fetch from MusicBrainz repopulates the 176 existing artists so they display Latin-primary + original-secondary.
```
