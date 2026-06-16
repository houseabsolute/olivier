use rusqlite::Connection;

use crate::enrich::client::{MbClient, Pacer};
use crate::enrich::http::MbHttp;
use crate::enrich::model::MbRelease;
use crate::enrich::progress::EnrichProgress;
use crate::enrich::select::{classify_pseudo, pseudo_release_targets, select_transliteration};
use crate::enrich::store;

fn is_real_mbid(mbid: &str) -> bool {
    !mbid.is_empty() && !mbid.starts_with("synth:")
}

/// Unique real-MBID album-artists owning ≥1 un-enriched file (or all, if force).
fn artists_to_enrich(conn: &Connection, force: bool) -> anyhow::Result<Vec<String>> {
    let sql = if force {
        "SELECT DISTINCT r.album_artist_mbid FROM release r
         WHERE r.album_artist_mbid NOT LIKE 'synth:%'"
    } else {
        "SELECT DISTINCT r.album_artist_mbid FROM release r
         JOIN track t ON t.release_mbid = r.mbid
         JOIN file f ON f.track_id = t.id
         WHERE r.album_artist_mbid NOT LIKE 'synth:%' AND f.enriched = 0"
    };
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// Unique real-MBID releases owning ≥1 un-enriched file (or all, if force),
/// paired with their release-group MBID for the fallback browse + dates.
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
    mut on_progress: impl FnMut(EnrichProgress) -> bool,
) -> anyhow::Result<()> {
    let artists = artists_to_enrich(conn, force)?;
    let releases = releases_to_enrich(conn, force)?;
    let total = (artists.len() + releases.len()) as u64;
    let mut done = 0u64;

    // ── artists ──
    for artist_mbid in &artists {
        if !is_real_mbid(artist_mbid) {
            continue;
        }
        let mb = client.fetch_artist(conn, artist_mbid).await?;
        if let Some(chosen) = select_transliteration(&mb) {
            store::apply_artist_transliteration(conn, artist_mbid, &chosen)?;
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
    // it is used only for the release-group browse fallback URL. The original
    // date is written to the REAL RG read from the release JSON below.
    for (rel_mbid, rg_mbid, title) in &releases {
        // Network fetches happen OUTSIDE the per-release transaction (a tokio
        // sleep must not hold a SQLite write lock). The pseudo-releases are
        // fetched first, then all DB writes for this release commit atomically.
        let release = client.fetch_release(conn, rel_mbid).await?;

        // pseudo-releases on this release, else fall back to browsing the group
        // (browse keyed by the catalog RG mbid — it's only a fetch URL).
        let mut targets = pseudo_release_targets(&release);
        if targets.is_empty() {
            if let Some(rg) = rg_mbid {
                if is_real_mbid(rg) {
                    targets = find_pseudo_via_browse(conn, client, rg).await?;
                }
            }
        }
        let mut pseudos = Vec::new();
        for pseudo_mbid in targets {
            pseudos.push(client.fetch_pseudo_release(conn, &pseudo_mbid).await?);
        }

        // ── per-release unit of work: ONE transaction ──
        // apply dates + all pseudo title-alts + mark files enriched commit
        // together, so a crash can't leave dates committed but files
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
        }

        for pseudo in &pseudos {
            apply_pseudo_alts(&tx, rel_mbid, title, pseudo)?;
        }

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

/// Album title alt = pseudo-release `title`; track title alts joined by
/// recording MBID against media[].tracks[].recording.id.
///
/// A single pseudo-release is uniformly one kind (MB attaches a transliteration
/// pseudo-release OR a translation pseudo-release, not mixed), so `classify_pseudo`
/// is called once at the release level — using that pseudo-release's
/// `text-representation` — and the resulting kind is applied to all its track
/// titles. This is correct and avoids needing each original track title.
fn apply_pseudo_alts(
    conn: &Connection,
    release_mbid: &str,
    original_title: &str,
    pseudo: &MbRelease,
) -> anyhow::Result<()> {
    // Authoritative: the pseudo-release's text-representation (script/language);
    // falls back to the title-pair heuristic only when that metadata is absent.
    let kind = classify_pseudo(original_title, pseudo);
    store::upsert_release_alt(conn, release_mbid, kind, &pseudo.title)?;
    for medium in &pseudo.media {
        for tr in &medium.tracks {
            if let Some(rec) = &tr.recording {
                // classify each track title against… the original track title is
                // unknown here cheaply; reuse the release-level kind (a pseudo
                // release is uniformly translit OR translate per MB convention).
                store::upsert_track_alt(conn, &rec.id, kind, &tr.title)?;
            }
        }
    }
    Ok(())
}

/// Release-group browse fallback (§5.1): page release-rels, collect any
/// transl-tracklisting targets found on sibling releases.
async fn find_pseudo_via_browse<H: MbHttp, P: Pacer>(
    conn: &Connection,
    client: &MbClient<H, P>,
    rg_mbid: &str,
) -> anyhow::Result<Vec<String>> {
    let mut offset = 0u32;
    let mut out = Vec::new();
    loop {
        let page = client.browse_release_group(conn, rg_mbid, offset).await?;
        for rel in &page.releases {
            out.extend(pseudo_release_targets(rel));
        }
        offset += page.releases.len() as u32;
        if page.releases.is_empty() || offset >= page.release_count {
            break;
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}
