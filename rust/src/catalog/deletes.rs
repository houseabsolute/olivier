use rusqlite::Connection;

use crate::catalog::scan;
use crate::decision_log::DecisionLog;

/// Forget a single track from the catalog: delete its file row(s); the
/// child-first orphan sweep then drops the now-fileless track (and its album /
/// artist if nothing of theirs remains). Files on disk are NOT touched.
pub fn remove_track(conn: &Connection, track_id: i64) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM file WHERE track_id = ?1",
        rusqlite::params![track_id],
    )?;
    scan::prune_orphans(conn, &DecisionLog::to_path(None))?;
    Ok(())
}

/// Forget an album (release) from the catalog: delete the file rows of all its
/// tracks; the orphan sweep then drops those tracks, the release, and the
/// album-artist if it has no other releases. Files on disk are NOT touched.
pub fn remove_album(conn: &Connection, release_mbid: &str) -> anyhow::Result<()> {
    conn.execute(
        "DELETE FROM file WHERE track_id IN (SELECT id FROM track WHERE release_mbid = ?1)",
        rusqlite::params![release_mbid],
    )?;
    scan::prune_orphans(conn, &DecisionLog::to_path(None))?;
    Ok(())
}
