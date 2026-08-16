use rusqlite::{Connection, OptionalExtension};

use crate::enrich::select::{is_non_latin, AltKind, ChosenAlias};

fn kind_str(k: AltKind) -> &'static str {
    match k {
        AltKind::Translit => "translit",
        AltKind::Translate => "translate",
    }
}

/// §5.1 + §6.1 tier 1: store the chosen transliteration and overwrite the
/// artist sort key with the alias sort-name.
///
/// Before overwriting `sort_name`, preserve the pre-enrichment value (the
/// embedded `albumartistsort` tag, §6.1 tier 3 fallback) into
/// `sort_name_embedded` — but only on FIRST enrichment, i.e. when
/// `sort_name_embedded IS NULL`, so a re-enrich (`force=true`) never clobbers
/// the original embedded value with an already-overwritten alias sort-name.
/// This keeps the embedded fallback recoverable for a future manual-override
/// UI (2b/post-v1).
pub fn apply_artist_transliteration(
    conn: &Connection,
    artist_mbid: &str,
    chosen: &ChosenAlias,
    original_name: &str,
) -> anyhow::Result<()> {
    // Snapshot the embedded sort_name once (first enrichment only).
    conn.execute(
        "UPDATE artist
            SET sort_name_embedded = sort_name
          WHERE mbid = ?1 AND sort_name_embedded IS NULL",
        rusqlite::params![artist_mbid],
    )?;
    // Store the MusicBrainz original-script name (e.g. 椎名林檎) in its own column,
    // separate from the tag-derived `name` (which may be a romanization), so the
    // bilingual row can lead with the original and a re-scan can't clobber it.
    //
    // The §6.1 tier-3 fallback (`from_entity_sort_name`) yields a "Last, First"
    // SORT string, not a display reading — `chosen.name == chosen.sort_name`. We
    // must NOT store that sort key as the `transliteration` (reading) line (§6.1:
    // sort key ≠ display reading); instead we fall back to the Latin tag `name`
    // as the reading (see the tier-3 branch below). `sort_name` is still written
    // (it drives §6.1 ordering) and so is `name_original`.
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
    conn.execute(
        "UPDATE artist SET transliteration = ?1, sort_name = ?2, name_original = ?3 WHERE mbid = ?4",
        rusqlite::params![transliteration, chosen.sort_name, original_name, artist_mbid],
    )?;
    Ok(())
}

/// Original year ← release-group first-release-date; reissue year ← release date.
/// Only overwrites when MB supplies a value (COALESCE keeps any embedded tag value).
///
/// `real_rg_mbid` MUST be the release-group id read from the MB release JSON
/// (`release.release-group.id`), NOT the catalog's stored
/// `release.release_group_mbid` — which may be a `synth:rg:…` key when the
/// file's tags lacked the RG MBID. We (a) ensure the real RG row exists, (b)
/// write the original date onto it, and (c) re-point this release at the real
/// RG so future joins (and 2b's display) land the original year correctly.
pub fn apply_dates(
    conn: &Connection,
    release_mbid: &str,
    real_rg_mbid: &str,
    rg_title: &str,
    first_release_date: Option<&str>,
    release_date: Option<&str>,
) -> anyhow::Result<()> {
    // (a) Insert the real RG row if absent (keep an existing title/date).
    conn.execute(
        "INSERT INTO release_group(mbid, title) VALUES (?1, ?2)
         ON CONFLICT(mbid) DO NOTHING",
        rusqlite::params![real_rg_mbid, rg_title],
    )?;
    // (b) Write the original date onto the REAL release-group.
    conn.execute(
        "UPDATE release_group SET first_release_date = COALESCE(?1, first_release_date) WHERE mbid = ?2",
        rusqlite::params![first_release_date, real_rg_mbid],
    )?;
    // (c) Re-point this release at the real RG (it may have been a synth:rg:… key).
    conn.execute(
        "UPDATE release SET release_group_mbid = ?1 WHERE mbid = ?2",
        rusqlite::params![real_rg_mbid, release_mbid],
    )?;
    // Reissue date on the release itself.
    conn.execute(
        "UPDATE release SET date = COALESCE(?1, date) WHERE mbid = ?2",
        rusqlite::params![release_date, release_mbid],
    )?;
    Ok(())
}

pub fn upsert_release_alt(
    conn: &Connection,
    release_mbid: &str,
    kind: AltKind,
    title: &str,
) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO release_title_alt(release_mbid, kind, title) VALUES (?1, ?2, ?3)
         ON CONFLICT(release_mbid, kind) DO UPDATE SET title = excluded.title",
        rusqlite::params![release_mbid, kind_str(kind), title],
    )?;
    Ok(())
}

pub fn upsert_track_alt(
    conn: &Connection,
    recording_mbid: &str,
    kind: AltKind,
    title: &str,
) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO track_title_alt(recording_mbid, kind, title) VALUES (?1, ?2, ?3)
         ON CONFLICT(recording_mbid, kind) DO UPDATE SET title = excluded.title",
        rusqlite::params![recording_mbid, kind_str(kind), title],
    )?;
    Ok(())
}

/// Fold away the differences that don't make two titles different titles to a
/// reader: case, punctuation, and whitespace. Every non-alphanumeric character
/// becomes a separator, so `Rock'n'Roll` / `Rock’n’Roll` / `Rock n Roll` and
/// `Moondust` / `moondust` / `Moondust!` all compare equal. `is_alphanumeric` is
/// Unicode-aware, so CJK titles survive as themselves.
///
/// Comparison only — never what gets stored.
fn norm(s: &str) -> String {
    s.split(|c: char| !c.is_alphanumeric())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// Delete stored alts that don't actually differ from what they annotate, for
/// one release. Returns how many rows were removed.
///
/// Two rules, applied in order (the first can make the second apply):
///
/// 1. An alt equal to its own original title is not an alternate. This is
///    routine in MB data: an English edition repeats an already-English track
///    title verbatim, and editors often leave an English edition's ALBUM title
///    in the original script — which then lands as a "translation" that is the
///    untranslated title.
/// 2. A translation equal to the reading is a duplicate; the reading is kept.
///    Katakana loanwords do this by construction — the romanization of
///    アネモネ and its English translation are both "Anemone".
///
/// A post-pass rather than a check at insert time so the outcome can't depend on
/// the order editions were processed in. Runs inside the caller's per-release
/// transaction. Track alts are keyed by recording, so a deletion also clears the
/// row for any other release sharing that recording — correct, since the
/// recording's original title is the same there too.
pub fn prune_redundant_alts(conn: &Connection, release_mbid: &str) -> anyhow::Result<usize> {
    let mut pruned = 0usize;

    let album_title: Option<String> = conn
        .query_row(
            "SELECT COALESCE(title,'') FROM release WHERE mbid = ?1",
            rusqlite::params![release_mbid],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(album_title) = album_title {
        let alts: Vec<(String, String)> = conn
            .prepare("SELECT kind, title FROM release_title_alt WHERE release_mbid = ?1")?
            .query_map(rusqlite::params![release_mbid], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?
            .collect::<Result<_, _>>()?;
        for kind in redundant_kinds(&album_title, &alts) {
            pruned += conn.execute(
                "DELETE FROM release_title_alt WHERE release_mbid = ?1 AND kind = ?2",
                rusqlite::params![release_mbid, kind],
            )?;
        }
    }

    let tracks: Vec<(String, String)> = conn
        .prepare(
            "SELECT recording_mbid, COALESCE(title,'') FROM track
              WHERE release_mbid = ?1 AND recording_mbid IS NOT NULL",
        )?
        .query_map(rusqlite::params![release_mbid], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?
        .collect::<Result<_, _>>()?;
    for (recording_mbid, track_title) in tracks {
        let alts: Vec<(String, String)> = conn
            .prepare("SELECT kind, title FROM track_title_alt WHERE recording_mbid = ?1")?
            .query_map(rusqlite::params![&recording_mbid], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?
            .collect::<Result<_, _>>()?;
        for kind in redundant_kinds(&track_title, &alts) {
            pruned += conn.execute(
                "DELETE FROM track_title_alt WHERE recording_mbid = ?1 AND kind = ?2",
                rusqlite::params![&recording_mbid, kind],
            )?;
        }
    }

    Ok(pruned)
}

/// Which of `alts` (a `(kind, title)` list for ONE entity) are redundant against
/// the entity's `original` title. See [`prune_redundant_alts`] for the rules.
fn redundant_kinds(original: &str, alts: &[(String, String)]) -> Vec<&'static str> {
    let mut doomed = Vec::new();
    let alt_of = |want: &str| {
        alts.iter()
            .find(|(kind, _)| kind == want)
            .map(|(_, title)| title.as_str())
    };
    let translit = alt_of("translit").filter(|t| norm(t) != norm(original));
    let translate = alt_of("translate").filter(|t| norm(t) != norm(original));

    if alt_of("translit").is_some() && translit.is_none() {
        doomed.push("translit");
    }
    // A translation is dropped when it repeats the original OR the surviving
    // reading.
    let translate_dupes_reading =
        matches!((translate, translit), (Some(a), Some(b)) if norm(a) == norm(b));
    if alt_of("translate").is_some() && (translate.is_none() || translate_dupes_reading) {
        doomed.push("translate");
    }
    doomed
}

/// Run [`prune_redundant_alts`] over every release in the catalog. Returns the
/// total rows removed.
///
/// For the one-time migration that cleans up libraries enriched before the prune
/// pass existed — those rows were written by an earlier build and nothing else
/// revisits them until each album happens to be re-enriched. Pure SQLite work:
/// no network, no MusicBrainz refetch.
pub fn prune_all_redundant_alts(conn: &Connection) -> anyhow::Result<usize> {
    let releases: Vec<String> = conn
        .prepare("SELECT mbid FROM release")?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    let mut pruned = 0usize;
    for release_mbid in releases {
        pruned += prune_redundant_alts(conn, &release_mbid)?;
    }
    Ok(pruned)
}

/// Flip `enriched` for every file whose track belongs to this release.
pub fn mark_release_files_enriched(conn: &Connection, release_mbid: &str) -> anyhow::Result<()> {
    conn.execute(
        "UPDATE file SET enriched = 1 WHERE track_id IN
           (SELECT id FROM track WHERE release_mbid = ?1)",
        rusqlite::params![release_mbid],
    )?;
    Ok(())
}
