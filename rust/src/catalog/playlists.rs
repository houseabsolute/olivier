use rusqlite::{params, Connection};

use crate::catalog::query;
use crate::catalog::schema::QueueTrack;

/// A playlist with its track count (for the list view).
#[derive(Debug, Clone)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    pub count: i64,
}

fn now_secs() -> anyhow::Result<i64> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64)
}

/// Create a playlist appended after the last one; returns its id.
pub fn create_playlist(conn: &Connection, name: &str) -> anyhow::Result<i64> {
    let pos: i64 = conn.query_row(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist",
        [],
        |r| r.get(0),
    )?;
    conn.execute(
        "INSERT INTO playlist(name, position, created_at) VALUES (?1, ?2, ?3)",
        params![name, pos, now_secs()?],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn rename_playlist(conn: &Connection, id: i64, name: &str) -> anyhow::Result<()> {
    conn.execute(
        "UPDATE playlist SET name = ?2 WHERE id = ?1",
        params![id, name],
    )?;
    Ok(())
}

/// Delete a playlist; its items cascade away.
pub fn delete_playlist(conn: &Connection, id: i64) -> anyhow::Result<()> {
    conn.execute("DELETE FROM playlist WHERE id = ?1", params![id])?;
    Ok(())
}

/// Set the manual order of playlists to `ids` (index becomes position).
pub fn reorder_playlists(conn: &Connection, ids: &[i64]) -> anyhow::Result<()> {
    let tx = conn.unchecked_transaction()?;
    for (i, id) in ids.iter().enumerate() {
        tx.execute(
            "UPDATE playlist SET position = ?2 WHERE id = ?1",
            params![id, i as i64],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn list_playlists(conn: &Connection) -> anyhow::Result<Vec<Playlist>> {
    let mut stmt = conn.prepare(
        "SELECT p.id, p.name, COUNT(pi.path)
         FROM playlist p
         LEFT JOIN playlist_item pi ON pi.playlist_id = p.id
         GROUP BY p.id
         ORDER BY p.position",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(Playlist {
            id: r.get(0)?,
            name: r.get(1)?,
            count: r.get(2)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// The playlist's tracks, in order (duplicates preserved), with catalog metadata.
pub fn playlist_tracks(conn: &Connection, id: i64) -> anyhow::Result<Vec<QueueTrack>> {
    let paths: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT path FROM playlist_item WHERE playlist_id = ?1 ORDER BY position")?;
        let paths = stmt.query_map([id], |r| r.get(0))?.collect::<Result<_, _>>()?;
        paths
    };
    query::tracks_for_paths(conn, &paths)
}

/// Append paths to the end of a playlist.
pub fn add_to_playlist(conn: &Connection, id: i64, paths: &[String]) -> anyhow::Result<()> {
    let tx = conn.unchecked_transaction()?;
    let mut pos: i64 = tx.query_row(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_item WHERE playlist_id = ?1",
        params![id],
        |r| r.get(0),
    )?;
    for p in paths {
        tx.execute(
            "INSERT INTO playlist_item(playlist_id, position, path) VALUES (?1, ?2, ?3)",
            params![id, pos, p],
        )?;
        pos += 1;
    }
    tx.commit()?;
    Ok(())
}

/// Replace a playlist's items with `paths` (in order). Backs reorder + remove.
pub fn set_playlist_items(conn: &Connection, id: i64, paths: &[String]) -> anyhow::Result<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "DELETE FROM playlist_item WHERE playlist_id = ?1",
        params![id],
    )?;
    for (i, p) in paths.iter().enumerate() {
        tx.execute(
            "INSERT INTO playlist_item(playlist_id, position, path) VALUES (?1, ?2, ?3)",
            params![id, i as i64, p],
        )?;
    }
    tx.commit()?;
    Ok(())
}
