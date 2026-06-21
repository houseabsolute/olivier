use rusqlite::Connection;

use crate::decision_log::DecisionLog;
use crate::enrich::client::{MbClient, Pacer};
use crate::enrich::http::MbHttp;
use crate::enrich::model::{MbRelease, MbTextRepresentation, MbTrack};
use crate::enrich::progress::EnrichProgress;
use crate::enrich::select::{
    classify_from_text_representation, english_words, is_non_latin, resolve_edition_kind,
    select_transliteration, store_alt_for, AltKind,
};
use crate::enrich::store;
use std::collections::HashMap;

fn is_real_mbid(mbid: &str) -> bool {
    !mbid.is_empty() && !mbid.starts_with("synth:")
}

/// Unique real-MBID album-artists needing (re)enrichment. With `force`, every
/// real-MBID album-artist. Otherwise an album-artist owning ≥1 un-enriched file
/// (new music) OR whose original-script name was never populated — the
/// Phase-2a→2b upgrade case, where the migration ALTERed `name_original` in but
/// nothing backfilled it and all files are already `enriched = 1`.
fn artists_to_enrich(conn: &Connection, force: bool) -> anyhow::Result<Vec<String>> {
    let sql = if force {
        "SELECT DISTINCT r.album_artist_mbid FROM release r
         WHERE r.album_artist_mbid NOT LIKE 'synth:%'"
    } else {
        // Non-force: an album-artist needs (re)enrichment when it owns an un-enriched
        // file (new music) OR its original-script name was never populated — e.g. a
        // Phase-2a library upgraded to 2b, where the ALTER added name_original but
        // nothing backfilled it and all files are already enriched=1. Re-running the
        // artist loop for the latter is cache-backed (artist JSON is in mb_cache), so
        // it fills name_original (and corrects any tier-3 transliteration via Bug 1)
        // without network, making the bilingual artist display appear after upgrade.
        "SELECT DISTINCT r.album_artist_mbid FROM release r
         JOIN artist a ON a.mbid = r.album_artist_mbid
         WHERE r.album_artist_mbid NOT LIKE 'synth:%'
           AND (a.name_original IS NULL
                OR EXISTS (SELECT 1 FROM track t JOIN file f ON f.track_id = t.id
                           WHERE t.release_mbid = r.mbid AND f.enriched = 0))"
    };
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// Unique real-MBID releases owning ≥1 un-enriched file (or all, if force).
/// The catalog's stored `release_group_mbid` is selected too but no longer
/// drives any fetch — the sibling-edition browse and dates both use the REAL RG
/// read from the release JSON — so it is currently ignored by the caller.
fn releases_to_enrich(
    conn: &Connection,
    force: bool,
) -> anyhow::Result<Vec<(String, Option<String>, String)>> {
    let filter = if force { "" } else { "AND f.enriched = 0" };
    let sql = format!(
        "SELECT DISTINCT r.mbid, r.release_group_mbid, COALESCE(r.title,'')
         FROM release r
         JOIN track t ON t.release_mbid = r.mbid
         JOIN file f ON f.track_id = t.id
         WHERE r.mbid NOT LIKE 'synth:%' {filter}"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, Option<String>>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// Orchestrate enrichment. `on_progress` returns `false` to request cancellation;
/// the FFI wrapper checks `sink.add()` and returns `false` when the Dart side
/// drops the stream, propagating cooperative cancellation into this loop.
pub async fn enrich<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    force: bool,
    log: &DecisionLog,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    let artists = artists_to_enrich(conn, force)?;
    let releases = releases_to_enrich(conn, force)?;
    log.header("Enrich library");
    enrich_lists(conn, client, artists, releases, log, on_progress).await
}

/// Re-enrich ONE artist and all of its releases, refetching from the network.
/// The artist's cached MB responses are cleared first so the refetch is fresh.
pub async fn enrich_artist<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    artist_mbid: &str,
    log: &DecisionLog,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    clear_artist_cache(conn, artist_mbid)?;
    let releases = artist_releases(conn, artist_mbid)?;
    log.header(&format!("Enrich artist {artist_mbid}"));
    enrich_lists(
        conn,
        client,
        vec![artist_mbid.to_string()],
        releases,
        log,
        on_progress,
    )
    .await
}

/// Re-enrich ONE release (and its sibling editions), refetching from the network.
/// The release's cached MB responses are cleared first so the refetch is fresh.
pub async fn enrich_album<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    release_mbid: &str,
    log: &DecisionLog,
    on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    clear_album_cache(conn, release_mbid)?;
    let releases = one_release(conn, release_mbid)?;
    log.header(&format!("Enrich album {release_mbid}"));
    enrich_lists(conn, client, Vec::new(), releases, log, on_progress).await
}

/// The shared artist-loop + release-loop body. `enrich` (full library) and the
/// per-entity entry points (`enrich_artist`/`enrich_album`) all gather their
/// artist/release lists and delegate here so the network + DB logic lives once.
async fn enrich_lists<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    artists: Vec<String>,
    releases: Vec<(String, Option<String>, String)>,
    log: &DecisionLog,
    mut on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    let total = (artists.len() + releases.len()) as u64;
    let mut done = 0u64;

    // ── artists ──
    for artist_mbid in &artists {
        if !is_real_mbid(artist_mbid) {
            continue;
        }
        log.line(
            if client.is_cached_artist(conn, artist_mbid) {
                "CACHE"
            } else {
                "FETCH"
            },
            &format!("artist {artist_mbid}"),
        );
        let mb = client.fetch_artist(conn, artist_mbid).await?;
        if let Some(chosen) = select_transliteration(&mb) {
            store::apply_artist_transliteration(conn, artist_mbid, &chosen, &mb.name)?;
            if chosen.from_entity_sort_name {
                log.line(
                    "APPLY",
                    &format!(
                        "artist \"{}\": sort name = \"{}\"",
                        mb.name, chosen.sort_name
                    ),
                );
            } else {
                log.line(
                    "APPLY",
                    &format!("artist \"{}\": reading = \"{}\"", mb.name, chosen.name),
                );
            }
        } else {
            log.line(
                "NOMATCH",
                &format!("artist \"{}\": no reading from MusicBrainz", mb.name),
            );
        }
        done += 1;
        if !on_progress(EnrichProgress {
            entities_done: done,
            entities_total: total,
            current: mb.name.clone(),
            done: false,
        }) {
            return Ok(()); // cancelled
        }
    }

    // ── releases ──
    // `rg_mbid` is the CATALOG's stored release_group_mbid (may be `synth:rg:…`);
    // it is NOT used for the sibling-edition browse — that browses the REAL RG
    // read from the release JSON. The original date is written to the REAL RG too.
    for (rel_mbid, _rg_mbid, title) in &releases {
        // Network fetches happen OUTSIDE the per-release transaction (a tokio
        // sleep must not hold a SQLite write lock). The release + its sibling
        // editions are fetched first, then all DB writes commit atomically.
        log.line(
            if client.is_cached_release(conn, rel_mbid) {
                "CACHE"
            } else {
                "FETCH"
            },
            &format!("release {rel_mbid}"),
        );
        let release = client.fetch_release(conn, rel_mbid).await?;

        // Title alts come from this release's SIBLING EDITIONS in the same
        // release group: a regular international edition (Latin/English) or a
        // Pseudo-Release (which IS just a sibling release in the group with a
        // Latin `text-representation`) is handled uniformly. We browse the REAL
        // release group from the fetched JSON (`release.release-group.id`), NOT
        // the catalog's possibly-`synth:` release_group_mbid, then page until
        // we've seen every edition.
        let mut editions = Vec::new();
        if let Some(rg) = release.release_group.as_ref() {
            if is_real_mbid(&rg.id) {
                editions = browse_all_editions(conn, client, &rg.id).await?;
            }
        }

        // ── per-release unit of work: ONE transaction ──
        // apply dates + all sibling-edition title-alts + mark files enriched
        // commit together, so a crash can't leave dates committed but files
        // un-enriched (inconsistent). Uses the codebase's existing
        // `conn.unchecked_transaction()` pattern. One commit per release.
        let tx = conn.unchecked_transaction()?;

        // dates: original ← release-group first-release-date written to the REAL
        // RG (release.release-group.id), NOT the catalog's possibly-synthetic
        // release_group_mbid; reissue ← release date.
        if let Some(rg) = release.release_group.as_ref() {
            store::apply_dates(
                &tx,
                rel_mbid,
                &rg.id,
                title,
                rg.first_release_date.as_deref(),
                release.date.as_deref(),
            )?;
            if let Some(d) = rg.first_release_date.as_deref() {
                log.line("APPLY", &format!("release \"{title}\": original date {d}"));
            }
            if let Some(d) = release.date.as_deref() {
                log.line("APPLY", &format!("release \"{title}\": reissue date {d}"));
            }
        }

        apply_edition_alts(
            &tx,
            rel_mbid,
            release.text_representation.as_ref(),
            &editions,
            log,
            title,
        )?;

        store::mark_release_files_enriched(&tx, rel_mbid)?;
        tx.commit()?;

        done += 1;
        if !on_progress(EnrichProgress {
            entities_done: done,
            entities_total: total,
            current: title.clone(),
            done: false,
        }) {
            return Ok(()); // cancelled
        }
    }

    on_progress(EnrichProgress {
        entities_done: done,
        entities_total: total,
        current: String::new(),
        done: true,
    });
    Ok(())
}

/// The real-MBID releases owned by one album-artist (skipping synthetic keys).
/// Mirrors `releases_to_enrich`'s tuple shape — the stored `release_group_mbid`
/// is carried but, as there, no longer drives any fetch (the release loop reads
/// the REAL release group from the fetched JSON).
fn artist_releases(
    conn: &Connection,
    artist_mbid: &str,
) -> anyhow::Result<Vec<(String, Option<String>, String)>> {
    let mut stmt = conn.prepare(
        "SELECT r.mbid, r.release_group_mbid, COALESCE(r.title,'')
         FROM release r WHERE r.album_artist_mbid = ?1 AND r.mbid NOT LIKE 'synth:%'",
    )?;
    let rows = stmt.query_map([artist_mbid], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, Option<String>>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// One release as a single-element list (empty if the MBID is unknown), in the
/// same tuple shape `enrich_lists` consumes.
fn one_release(
    conn: &Connection,
    release_mbid: &str,
) -> anyhow::Result<Vec<(String, Option<String>, String)>> {
    let row = conn.query_row(
        "SELECT r.mbid, r.release_group_mbid, COALESCE(r.title,'') FROM release r WHERE r.mbid = ?1",
        [release_mbid],
        |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Option<String>>(1)?,
                r.get::<_, String>(2)?,
            ))
        },
    );
    match row {
        Ok(t) => Ok(vec![t]),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(Vec::new()),
        Err(e) => Err(e.into()),
    }
}

/// Drop the cached MB responses for one artist (its artist fetch, its releases,
/// and their release-groups) so the re-enrich hits the network fresh.
fn clear_artist_cache(conn: &Connection, artist_mbid: &str) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM mb_cache WHERE mbid = ?1
           OR mbid IN (SELECT mbid FROM release WHERE album_artist_mbid = ?1)
           OR mbid IN (SELECT release_group_mbid FROM release
                       WHERE album_artist_mbid = ?1 AND release_group_mbid IS NOT NULL)",
        [artist_mbid],
    )?;
    Ok(())
}

/// Drop the cached MB responses for one release (and its release-group browse).
fn clear_album_cache(conn: &Connection, release_mbid: &str) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM mb_cache WHERE mbid = ?1
           OR mbid IN (SELECT release_group_mbid FROM release
                       WHERE mbid = ?1 AND release_group_mbid IS NOT NULL)",
        [release_mbid],
    )?;
    Ok(())
}

/// Store title alts for the original release from its sibling editions.
///
/// A sibling edition supplies title alts when its `text-representation` classifies
/// (Latin script ⇒ transliteration; `language == "eng"` ⇒ translation). The
/// edition's album title is the original release's album-title alt; each track
/// title is joined to OUR tracks by recording MBID (`track_title_alt` is keyed
/// `(recording_mbid, kind)`), so a sibling edition only needs to share recording
/// MBIDs with the original — it does NOT need the original track titles.
///
/// Pseudo-releases require no special handling: a Pseudo-Release IS a sibling
/// release in the group with a Latin `text-representation`, classified the same
/// way as a regular international edition.
///
/// Editions written in the SAME script as the original are skipped: another
/// native-script edition (e.g. a Japanese reissue of a Japanese album) is not a
/// transliteration or translation, and `classify_from_text_representation` would
/// otherwise label a non-Latin native script as a (spurious) translation. When
/// the original's own script is unknown (no `text-representation`) we can't
/// detect a same-script reissue, so only the two reliably-safe alt forms are
/// accepted — a Latin-script (`Latn`) sibling or an English-language (`eng`)
/// sibling; any other-script sibling is skipped.
///
/// Editions are processed in ascending `id` order so the `ON CONFLICT(...,kind)`
/// last-writer is deterministic when two editions share a kind.
fn apply_edition_alts(
    conn: &Connection,
    release_mbid: &str,
    original_text_rep: Option<&MbTextRepresentation>,
    editions: &[MbRelease],
    log: &DecisionLog,
    title: &str,
) -> anyhow::Result<()> {
    let original_script = original_text_rep.and_then(|tr| tr.script.as_deref());

    let mut ordered: Vec<&MbRelease> = editions
        .iter()
        .filter(|ed| ed.id != release_mbid)
        .filter(|ed| {
            let tr = ed.text_representation.as_ref();
            let ed_script = tr.and_then(|t| t.script.as_deref());
            let ed_lang = tr.and_then(|t| t.language.as_deref());
            match original_script {
                // Known original script: skip a sibling written in that SAME
                // script — a native-script reissue is neither a transliteration
                // nor a translation, and would otherwise be stored as a
                // (spurious) translation (the Some(_) arm of
                // classify_from_text_representation).
                Some(orig) => ed_script != Some(orig),
                // Unknown original script: we can't confirm a non-Latin /
                // non-English sibling differs from the original, so accept only
                // the two reliably-safe alt forms — a Latin-script romanization
                // or an English translation.
                None => ed_script == Some("Latn") || ed_lang == Some("eng"),
            }
        })
        .collect();
    ordered.sort_by(|a, b| a.id.cmp(&b.id));

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
    let album_non_latin = is_non_latin(original_album_title);

    for ed in ordered {
        let Some(mb_kind) = classify_from_text_representation(ed.text_representation.as_ref())
        else {
            continue;
        };
        // Decide reading-vs-translation over ONLY the non-Latin-original titles.
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
        let album_stored = store_alt_for(kind, album_non_latin);
        if album_stored {
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
        let album_note = if album_stored {
            format!(" + album \"{}\"", ed.title)
        } else {
            String::new()
        };
        log.line(
            "APPLY",
            &format!(
                "release \"{title}\": stored {n_tracks} {kind_label} track titles{album_note}"
            ),
        );
    }
    Ok(())
}

/// Browse every edition in a release group, paging `limit=100&offset=` until
/// we've seen all of them (`offset >= release_count`). Each edition carries its
/// full tracklist (`inc=recordings`) and its `text-representation`.
async fn browse_all_editions<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    rg_mbid: &str,
) -> anyhow::Result<Vec<MbRelease>> {
    let mut offset = 0u32;
    let mut out = Vec::new();
    loop {
        let page = client.browse_release_group(conn, rg_mbid, offset).await?;
        let n = page.releases.len() as u32;
        out.extend(page.releases);
        offset += n;
        if n == 0 || offset >= page.release_count {
            break;
        }
    }
    Ok(out)
}
