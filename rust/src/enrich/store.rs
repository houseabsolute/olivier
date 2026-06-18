use rusqlite::Connection;

use crate::enrich::select::{AltKind, ChosenAlias};

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
    // sort key ≠ display reading), so in that case the reading is NULL and the
    // bilingual row collapses to the single original-script line. `sort_name` is
    // still written (it drives §6.1 ordering) and so is `name_original`.
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

/// Flip `enriched` for every file whose track belongs to this release.
pub fn mark_release_files_enriched(conn: &Connection, release_mbid: &str) -> anyhow::Result<()> {
    conn.execute(
        "UPDATE file SET enriched = 1 WHERE track_id IN
           (SELECT id FROM track WHERE release_mbid = ?1)",
        rusqlite::params![release_mbid],
    )?;
    Ok(())
}
