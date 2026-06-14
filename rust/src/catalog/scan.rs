use anyhow::Context;
use rusqlite::{Connection, Transaction};

use crate::catalog::ids;
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
                    if files_seen.is_multiple_of(50) {
                        on_progress(ScanProgress {
                            files_seen,
                            files_changed,
                            current: path_str,
                            done: false,
                        });
                    }
                    continue;
                }
            }

            // Parse tags and upsert
            let tags = read_tags(path).with_context(|| format!("read_tags for {path_str}"))?;
            let tx = conn.transaction()?;
            upsert_file(&tx, &tags, &path_str, mtime, size, epoch, now_secs)?;
            tx.commit()?;

            files_changed += 1;
            files_seen += 1;

            if files_seen.is_multiple_of(50) {
                on_progress(ScanProgress {
                    files_seen,
                    files_changed,
                    current: path_str,
                    done: false,
                });
            }
        }
    }

    // Deletion sweep — child-first
    conn.execute(
        "DELETE FROM file WHERE scan_epoch != ?1",
        rusqlite::params![epoch],
    )?;
    // track_stats references track, so it must be deleted BEFORE the track — FKs ARE
    // enforced here (libsqlite3-sys bundles SQLite with SQLITE_DEFAULT_FOREIGN_KEYS=1).
    // Key both off `file` so an orphaned (no-file) track and its stats go together.
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

    on_progress(ScanProgress {
        files_seen,
        files_changed,
        current: String::new(),
        done: true,
    });

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
) -> anyhow::Result<()> {
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

    Ok(())
}
