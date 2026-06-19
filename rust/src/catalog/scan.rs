use std::path::Path;

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, Transaction};

use crate::catalog::ids;
use crate::decision_log::{Decision, DecisionLog};
use crate::tags::{read_tags, TrackTags};

const AUDIO_EXTENSIONS: &[&str] = &["mp3", "flac", "m4a", "ogg", "oga", "opus"];

#[derive(Clone)]
pub struct ScanProgress {
    pub files_seen: u64,
    pub files_changed: u64,
    pub current: String,
    pub done: bool,
}

pub fn scan_roots(
    conn: &mut Connection,
    roots: &[String],
    log: &DecisionLog,
    mut on_progress: impl FnMut(ScanProgress),
) -> anyhow::Result<()> {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?;
    // scan_epoch is a per-run id used by the deletion sweep; use nanos so two scans
    // in the same wall-clock second still get distinct epochs. added_at is a real
    // unix-seconds timestamp — don't conflate the two.
    let epoch = now.as_nanos() as i64;
    let now_secs = now.as_secs() as i64;

    let mut files_seen: u64 = 0;
    let mut files_changed: u64 = 0;

    log.header(&format!("Scan {}", roots.join(", ")));

    for root in roots {
        let walker = ignore::WalkBuilder::new(root)
            .standard_filters(false)
            .build();

        for entry in walker {
            let entry = entry.context("walk error")?;
            let path = entry.path();

            // Only process files with audio extensions
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if !AUDIO_EXTENSIONS.contains(&ext.as_str()) {
                continue;
            }

            let path_str = path.to_string_lossy().to_string();

            let meta =
                std::fs::metadata(path).with_context(|| format!("metadata for {path_str}"))?;
            let mtime = meta
                .modified()?
                .duration_since(std::time::UNIX_EPOCH)?
                .as_secs() as i64;
            let size = meta.len() as i64;

            // Pre-filter: check if file is unchanged
            let cached: Option<(i64, i64)> = conn
                .query_row(
                    "SELECT mtime, size FROM file WHERE path = ?1",
                    rusqlite::params![path_str],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .ok();

            if let Some((cached_mtime, cached_size)) = cached {
                if cached_mtime == mtime && cached_size == size {
                    // File unchanged — just refresh scan_epoch
                    conn.execute(
                        "UPDATE file SET scan_epoch = ?1 WHERE path = ?2",
                        rusqlite::params![epoch, path_str],
                    )?;
                    files_seen += 1;
                    // Emit on every file so the UI count updates continuously and small
                    // libraries (<50 files) still show progress. Flutter coalesces the
                    // setState per frame, so UI rebuilds stay bounded. If very large
                    // all-cached rescans (>50k files) ever show bridge pressure, switch
                    // to a time-based throttle (emit if >16ms since the last emission).
                    on_progress(ScanProgress {
                        files_seen,
                        files_changed,
                        current: path_str,
                        done: false,
                    });
                    continue;
                }
            }

            // Parse tags and upsert. A single unreadable file is logged and
            // skipped — it must not abort the whole scan.
            let tags = match read_tags(path) {
                Ok(t) => t,
                Err(e) => {
                    log.record(&Decision::Fail {
                        path: path_str.clone(),
                        error: e.to_string(),
                    });
                    files_seen += 1;
                    on_progress(ScanProgress {
                        files_seen,
                        files_changed,
                        current: path_str,
                        done: false,
                    });
                    continue;
                }
            };
            let tx = conn.transaction()?;
            let decisions = upsert_file(&tx, &tags, &path_str, mtime, size, epoch, now_secs)?;
            tx.commit()?;
            for d in &decisions {
                log.record(d);
            }

            files_changed += 1;
            files_seen += 1;
            on_progress(ScanProgress {
                files_seen,
                files_changed,
                current: path_str,
                done: false,
            });
        }
    }

    // Deletion sweep — only prune files under the roots we actually scanned, so
    // scanning one root never deletes files that belong to another root. A file is
    // "under" a root when its path begins with `<root>/`; the trailing '/' stops a
    // root like `/m/Rock` from also matching a sibling `/m/RockAndRoll`, and the
    // char-counted substr keeps the prefix match correct for non-ASCII (e.g.
    // Japanese) paths.
    for root in roots {
        let prefix = format!("{}/", root.trim_end_matches('/'));
        conn.execute(
            "DELETE FROM file WHERE scan_epoch != ?1 AND substr(path, 1, ?2) = ?3",
            rusqlite::params![epoch, prefix.chars().count() as i64, prefix],
        )?;
    }
    // Files missing a MusicBrainz album-artist ID get a synthetic key; merge them
    // into a real same-name artist so an album-artist tagged inconsistently across
    // its albums shows up once, not twice.
    reconcile_album_artists(conn)?;
    prune_orphans(conn)?;

    on_progress(ScanProgress {
        files_seen,
        files_changed,
        current: String::new(),
        done: true,
    });

    Ok(())
}

/// Re-read the tags of every file backing one track and re-upsert it, re-homing
/// the track to the correct album/artist if the tags changed, then clean up any
/// now-orphaned rows. Local tags only (MusicBrainz re-fetch is a separate action).
pub fn reread_track_tags(
    conn: &mut Connection,
    track_id: i64,
    log: &DecisionLog,
) -> anyhow::Result<()> {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?;
    let epoch = now.as_nanos() as i64;
    let now_secs = now.as_secs() as i64;

    let paths: Vec<String> = {
        let mut stmt = conn.prepare("SELECT path FROM file WHERE track_id = ?1")?;
        let rows = stmt.query_map([track_id], |r| r.get::<_, String>(0))?;
        rows.collect::<Result<Vec<_>, _>>()?
    };

    for path in &paths {
        // The file may have moved/vanished since the scan; skip missing ones (a
        // future full scan's deletion sweep removes them).
        let meta = match std::fs::metadata(path) {
            Ok(m) => m,
            Err(_) => continue,
        };
        let mtime = meta
            .modified()?
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs() as i64;
        let size = meta.len() as i64;
        let tags = read_tags(Path::new(path)).with_context(|| format!("read_tags for {path}"))?;
        let tx = conn.transaction()?;
        let decisions = upsert_file(&tx, &tags, path, mtime, size, epoch, now_secs)?;
        tx.commit()?;
        for d in &decisions {
            log.record(d);
        }
    }

    reconcile_album_artists(conn)?;
    prune_orphans(conn)?;
    Ok(())
}

/// Remove catalog rows orphaned by file deletions, child-first. track_stats
/// references track, so it must be deleted BEFORE the track — FKs ARE enforced
/// here (libsqlite3-sys bundles SQLite with SQLITE_DEFAULT_FOREIGN_KEYS=1). Keying
/// each level off the level below drops a whole orphaned album/artist together.
pub(crate) fn prune_orphans(conn: &Connection) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM track_stats WHERE track_id NOT IN (SELECT track_id FROM file)",
        [],
    )?;
    conn.execute(
        "DELETE FROM track WHERE id NOT IN (SELECT track_id FROM file)",
        [],
    )?;
    conn.execute(
        "DELETE FROM release WHERE mbid NOT IN (SELECT release_mbid FROM track)",
        [],
    )?;
    conn.execute(
        "DELETE FROM release_group WHERE mbid NOT IN (SELECT release_group_mbid FROM release WHERE release_group_mbid IS NOT NULL)",
        [],
    )?;
    conn.execute(
        "DELETE FROM artist WHERE mbid NOT IN (SELECT album_artist_mbid FROM release WHERE album_artist_mbid IS NOT NULL)",
        [],
    )?;
    Ok(())
}

/// Merge synthetic album-artists into a real (MBID-keyed) artist of the same
/// name. A file lacking a MusicBrainz album-artist ID gets a `synth:aa:<name>`
/// key; if other files by the same artist *were* tagged with the real MBID, the
/// artist would otherwise appear twice in the browse list. For each real artist
/// we recompute the synthetic key it *would* own — using the exact same
/// lowercase + whitespace-collapse the scanner uses — and re-point any release
/// still keyed that way onto the real MBID. The now-unreferenced synth artist is
/// dropped by the following orphan sweep. Matching on the recomputed key (rather
/// than a SQL name comparison) means case/whitespace tagging differences can't
/// cause a missed merge, and a synth release with no real counterpart is simply
/// never touched.
pub fn reconcile_album_artists(conn: &Connection) -> anyhow::Result<()> {
    let mut reals: Vec<(String, String)> = Vec::new();
    {
        let mut stmt =
            conn.prepare("SELECT mbid, name FROM artist WHERE mbid NOT LIKE 'synth:%'")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        for row in rows {
            reals.push(row?);
        }
    }
    let tx = conn.unchecked_transaction()?;
    for (mbid, name) in &reals {
        let synth_key = format!("synth:aa:{}", ids::normalize(name));
        tx.execute(
            "UPDATE release SET album_artist_mbid = ?1 WHERE album_artist_mbid = ?2",
            rusqlite::params![mbid, synth_key],
        )?;
    }
    tx.commit()?;
    Ok(())
}

fn upsert_file(
    tx: &Transaction,
    tags: &TrackTags,
    path: &str,
    mtime: i64,
    size: i64,
    epoch: i64,
    now_secs: i64,
) -> anyhow::Result<Vec<Decision>> {
    let album_artist_name = tags
        .album_artist
        .as_deref()
        .or(tags.artist.as_deref())
        .unwrap_or("");
    let album = tags.album.as_deref().unwrap_or("");

    let artist_mbid = ids::album_artist_key(tags.album_artist_mbid.as_deref(), album_artist_name);
    let rg_mbid =
        ids::release_group_key(tags.release_group_mbid.as_deref(), album_artist_name, album);
    let rel_mbid = ids::release_key(tags.release_mbid.as_deref(), album_artist_name, album);

    let sort_name = ids::sort_name(album_artist_name, tags.album_artist_sort.as_deref());

    let artist_existed = tx
        .query_row(
            "SELECT 1 FROM artist WHERE mbid = ?1",
            rusqlite::params![artist_mbid],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    let album_existed = tx
        .query_row(
            "SELECT 1 FROM release WHERE mbid = ?1",
            rusqlite::params![rel_mbid],
            |_| Ok(()),
        )
        .optional()?
        .is_some();

    // Upsert artist
    tx.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES (?1, ?2, ?3)
         ON CONFLICT(mbid) DO UPDATE SET
             name      = excluded.name,
             sort_name = excluded.sort_name",
        rusqlite::params![artist_mbid, album_artist_name, sort_name],
    )?;

    // Upsert release_group
    tx.execute(
        "INSERT INTO release_group(mbid, title, first_release_date) VALUES (?1, ?2, ?3)
         ON CONFLICT(mbid) DO UPDATE SET
             title              = COALESCE(excluded.title, title),
             first_release_date = COALESCE(excluded.first_release_date, first_release_date)",
        rusqlite::params![
            rg_mbid,
            tags.album.as_deref(),
            tags.original_date.as_deref()
        ],
    )?;

    // Upsert release
    tx.execute(
        "INSERT INTO release(mbid, release_group_mbid, album_artist_mbid, title, date)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(mbid) DO UPDATE SET
             title = COALESCE(excluded.title, title),
             date  = COALESCE(excluded.date, date)",
        rusqlite::params![
            rel_mbid,
            rg_mbid,
            artist_mbid,
            tags.album.as_deref(),
            tags.reissue_date.as_deref()
        ],
    )?;

    // Upsert track — get its id via RETURNING
    let disc = tags.disc_no.unwrap_or(1) as i64;
    let position = tags.track_no.unwrap_or(1) as i64;
    let prior_track_id: Option<i64> = tx
        .query_row(
            "SELECT id FROM track WHERE release_mbid = ?1 AND disc = ?2 AND position = ?3",
            rusqlite::params![rel_mbid, disc, position],
            |r| r.get(0),
        )
        .optional()?;
    let prior_other_file: Option<String> = match prior_track_id {
        Some(tid) => tx
            .query_row(
                "SELECT path FROM file WHERE track_id = ?1 AND path != ?2 LIMIT 1",
                rusqlite::params![tid, path],
                |r| r.get(0),
            )
            .optional()?,
        None => None,
    };
    let length_ms = if tags.length_ms > 0 {
        Some(tags.length_ms as i64)
    } else {
        None
    };

    let track_id: i64 = tx.query_row(
        "INSERT INTO track(release_mbid, recording_mbid, artist, disc, position, title, length_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(release_mbid, disc, position) DO UPDATE SET
             recording_mbid = COALESCE(excluded.recording_mbid, recording_mbid),
             artist         = COALESCE(excluded.artist, artist),
             title          = COALESCE(excluded.title, title),
             length_ms      = COALESCE(excluded.length_ms, length_ms)
         RETURNING id",
        rusqlite::params![
            rel_mbid,
            tags.recording_mbid.as_deref(),
            tags.artist.as_deref(),
            disc,
            position,
            tags.title.as_deref(),
            length_ms
        ],
        |r| r.get(0),
    )?;

    // Upsert file
    tx.execute(
        "INSERT INTO file(path, mtime, size, codec, track_id, added_at, has_cover, scan_epoch)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(path) DO UPDATE SET
             mtime      = excluded.mtime,
             size       = excluded.size,
             codec      = excluded.codec,
             track_id   = excluded.track_id,
             has_cover  = excluded.has_cover,
             scan_epoch = excluded.scan_epoch",
        rusqlite::params![
            path,
            mtime,
            size,
            tags.codec.as_deref(),
            track_id,
            now_secs,
            tags.has_cover as i64,
            epoch
        ],
    )?;

    // Insert track_stats if not present
    tx.execute(
        "INSERT OR IGNORE INTO track_stats(track_id) VALUES (?1)",
        rusqlite::params![track_id],
    )?;

    let mut decisions = Vec::new();
    if !artist_existed {
        decisions.push(Decision::AddArtist {
            name: album_artist_name.to_string(),
        });
    }
    if !album_existed {
        decisions.push(Decision::AddAlbum {
            title: album.to_string(),
            artist: album_artist_name.to_string(),
        });
    }
    match (prior_track_id, prior_other_file) {
        (None, _) => decisions.push(Decision::AddTrack {
            title: tags.title.clone().unwrap_or_default(),
            artist: album_artist_name.to_string(),
            album: album.to_string(),
            path: path.to_string(),
        }),
        (Some(_), Some(existing_path)) => decisions.push(Decision::Dedup {
            path: path.to_string(),
            track_title: tags.title.clone().unwrap_or_default(),
            album: album.to_string(),
            disc,
            position,
            existing_path,
        }),
        (Some(_), None) => {}
    }
    Ok(decisions)
}
