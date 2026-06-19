use crate::catalog::schema::{Album, Artist, QueueTrack, Track};
use rusqlite::{Connection, OptionalExtension};

/// Keyset page of album-artists ordered by sort_name (case-insensitive). Pass
/// the previous page's last sort_name as `after` (None for the first page).
pub fn artists_page(
    conn: &Connection,
    after: Option<&str>,
    limit: u32,
) -> anyhow::Result<Vec<Artist>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT a.mbid, a.name, a.sort_name, a.transliteration, a.name_original FROM artist a
         WHERE a.mbid IN (SELECT DISTINCT album_artist_mbid FROM release)
           AND (?1 IS NULL OR a.sort_name > ?1 COLLATE NOCASE)
         ORDER BY a.sort_name COLLATE NOCASE LIMIT ?2",
    )?;
    let rows = stmt.query_map(rusqlite::params![after, limit], |r| {
        Ok(Artist {
            mbid: r.get(0)?,
            name: r.get(1)?,
            sort_name: r.get(2)?,
            transliteration: r.get(3)?,
            name_original: r.get(4)?,
        })
    })?;
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// Albums for one album-artist, ordered by original year then title
/// (case-insensitive; spec §6.1).
pub fn albums_for_artist(conn: &Connection, album_artist_mbid: &str) -> anyhow::Result<Vec<Album>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT r.mbid, r.title, a.name,
                substr(rg.first_release_date, 1, 4), substr(r.date, 1, 4),
                (SELECT title FROM release_title_alt
                   WHERE release_mbid = r.mbid AND kind = 'translit'),
                (SELECT title FROM release_title_alt
                   WHERE release_mbid = r.mbid AND kind = 'translate'),
                (SELECT MIN(f.added_at) FROM track t JOIN file f ON f.track_id = t.id
                   WHERE t.release_mbid = r.mbid)
         FROM release r
         JOIN artist a ON a.mbid = r.album_artist_mbid
         LEFT JOIN release_group rg ON rg.mbid = r.release_group_mbid
         WHERE r.album_artist_mbid = ?1
         ORDER BY COALESCE(rg.first_release_date, r.date, '9999'), r.title COLLATE NOCASE",
    )?;
    let rows = stmt.query_map([album_artist_mbid], |r| {
        Ok(Album {
            release_mbid: r.get(0)?,
            title: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
            album_artist: r.get(2)?,
            original_year: r.get(3)?,
            reissue_year: r.get(4)?,
            title_translit: r.get(5)?,
            title_translate: r.get(6)?,
            added_at: r.get::<_, Option<i64>>(7)?.unwrap_or(0),
        })
    })?;
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// Tracks for one album (release), ordered by disc then position (spec §6.1).
pub fn tracks_for_album(conn: &Connection, release_mbid: &str) -> anyhow::Result<Vec<Track>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT t.id, t.disc, t.position, t.title, t.artist, t.length_ms,
                s.last_played, MIN(f.added_at),
                MAX(CASE WHEN tta.kind = 'translit' THEN tta.title END),
                MAX(CASE WHEN tta.kind = 'translate' THEN tta.title END)
         FROM track t
         LEFT JOIN track_stats s ON s.track_id = t.id
         LEFT JOIN file f ON f.track_id = t.id
         LEFT JOIN track_title_alt tta ON tta.recording_mbid = t.recording_mbid
         WHERE t.release_mbid = ?1
         GROUP BY t.id
         ORDER BY t.disc, t.position",
    )?;
    let rows = stmt.query_map([release_mbid], |r| {
        Ok(Track {
            id: r.get(0)?,
            disc: r.get::<_, i64>(1)? as u32,
            position: r.get::<_, i64>(2)? as u32,
            title: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
            artist: r.get(4)?,
            length_ms: r.get::<_, Option<i64>>(5)?.map(|v| v as u64),
            last_played: r.get(6)?,
            added_at: r.get::<_, Option<i64>>(7)?.unwrap_or(0),
            title_translit: r.get(8)?,
            title_translate: r.get(9)?,
        })
    })?;
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// Record one qualifying play. The "what counts as a play" threshold is enforced
/// Dart-side; this just bumps the aggregate. (Spec §4's per-play event table is
/// deferred — Phase 1 keeps only the track_stats aggregate.)
pub fn record_play(conn: &Connection, track_id: i64, played_at: i64) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO track_stats(track_id, last_played, play_count, first_played)
         VALUES (?1, ?2, 1, ?2)
         ON CONFLICT(track_id) DO UPDATE SET
             last_played  = excluded.last_played,
             play_count   = play_count + 1,
             first_played = COALESCE(first_played, excluded.first_played)",
        rusqlite::params![track_id, played_at],
    )?;
    Ok(())
}

/// One absolute file path per track, in disc/position order — the play queue for
/// an album. Returns exactly one path per track (the lexically-first file when a
/// track has several, e.g. the same rip in two formats) so the queue lines up
/// 1:1 with `tracks_for_album`, which the caller zips it against. Uses an INNER
/// join, so a track with no files is omitted — a post-scan DB never has one (the
/// orphan sweep removes file-less tracks); the caller's `min()` guard is the
/// backstop if that invariant is ever broken.
pub fn file_paths_for_album(conn: &Connection, release_mbid: &str) -> anyhow::Result<Vec<String>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT MIN(f.path) FROM track t JOIN file f ON f.track_id = t.id
         WHERE t.release_mbid = ?1 GROUP BY t.id ORDER BY t.disc, t.position",
    )?;
    let rows = stmt.query_map([release_mbid], |r| r.get::<_, String>(0))?;
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// The single play path for one track — `MIN(f.path)` so a track with several
/// files (same rip in two formats) yields exactly one entry, matching
/// `file_paths_for_album`. `None` when the track has no files or does not exist,
/// so a double-click on such a row enqueues nothing.
pub fn track_path(conn: &Connection, track_id: i64) -> anyhow::Result<Option<String>> {
    let path = conn
        .query_row(
            "SELECT MIN(f.path) FROM file f WHERE f.track_id = ?1",
            [track_id],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    Ok(path)
}

/// One absolute file path per track for every release by one album-artist, in the
/// album browse order (original-year then title, case-insensitive — matching
/// `albums_for_artist`) and within each album by disc then position. One path per
/// track (`MIN(path)`), so an artist enqueue lines up with the displayed albums.
pub fn track_paths_for_artist(
    conn: &Connection,
    album_artist_mbid: &str,
) -> anyhow::Result<Vec<String>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT MIN(f.path)
         FROM release r
         JOIN track t ON t.release_mbid = r.mbid
         JOIN file f ON f.track_id = t.id
         LEFT JOIN release_group rg ON rg.mbid = r.release_group_mbid
         WHERE r.album_artist_mbid = ?1
         GROUP BY t.id
         ORDER BY COALESCE(rg.first_release_date, r.date, '9999'),
                  r.title COLLATE NOCASE, t.disc, t.position",
    )?;
    let rows = stmt.query_map([album_artist_mbid], |r| r.get::<_, String>(0))?;
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// One absolute file path per track for the entire catalog, in a deterministic
/// order (by track id). Used by "Shuffle entire library", which shuffles the
/// playback order afterward, so the on-disk order only needs to be stable, not
/// musically meaningful. One path per track (`MIN(path)`).
pub fn track_paths_for_library(conn: &Connection) -> anyhow::Result<Vec<String>> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT MIN(f.path) FROM track t JOIN file f ON f.track_id = t.id
         GROUP BY t.id ORDER BY t.id",
    )?;
    let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// Track metadata for an explicit, ordered list of file paths — used to rebuild
/// the now-playing items for a restored queue. Returns exactly one entry per
/// input path, in the same order; a path no longer in the catalog gets a
/// placeholder (filename as title, no track id) so the result still lines up 1:1
/// with the player's restored sources.
pub fn tracks_for_paths(conn: &Connection, paths: &[String]) -> anyhow::Result<Vec<QueueTrack>> {
    let mut stmt = conn.prepare(
        "SELECT t.id, t.title, t.artist, t.length_ms, r.title,
                (SELECT title FROM track_title_alt
                   WHERE recording_mbid = t.recording_mbid AND kind = 'translit'),
                (SELECT title FROM track_title_alt
                   WHERE recording_mbid = t.recording_mbid AND kind = 'translate'),
                f.added_at, s.last_played
         FROM file f JOIN track t ON t.id = f.track_id
         JOIN release r ON r.mbid = t.release_mbid
         LEFT JOIN track_stats s ON s.track_id = t.id
         WHERE f.path = ?1",
    )?;
    let mut out = Vec::with_capacity(paths.len());
    for path in paths {
        let found = stmt
            .query_row([path], |r| {
                Ok(QueueTrack {
                    path: path.clone(),
                    track_id: Some(r.get(0)?),
                    title: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    artist: r.get(2)?,
                    album: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
                    length_ms: r.get::<_, Option<i64>>(3)?.map(|v| v as u64),
                    added_at: r.get::<_, Option<i64>>(7)?.unwrap_or(0),
                    last_played: r.get(8)?,
                    title_translit: r.get(5)?,
                    title_translate: r.get(6)?,
                })
            })
            .optional()?;
        out.push(found.unwrap_or_else(|| QueueTrack {
            path: path.clone(),
            track_id: None,
            title: path.rsplit('/').next().unwrap_or(path).to_string(),
            artist: None,
            album: String::new(),
            length_ms: None,
            added_at: 0,
            last_played: None,
            title_translit: None,
            title_translate: None,
        }));
    }
    Ok(out)
}
