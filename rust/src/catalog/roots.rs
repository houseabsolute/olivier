use rusqlite::Connection;

use crate::catalog::scan;

/// Persist a library root folder. Idempotent — re-adding the same path is a no-op.
/// Only a trailing slash is trimmed; the path is otherwise stored exactly as passed
/// so it matches the file paths produced when scanning that root.
pub fn add_root(conn: &Connection, path: &str) -> anyhow::Result<()> {
    let normalized = path.trim_end_matches('/');
    conn.execute(
        "INSERT OR IGNORE INTO root(path) VALUES (?1)",
        rusqlite::params![normalized],
    )?;
    Ok(())
}

/// Forget a root folder and prune every file beneath it, plus any catalog rows
/// (tracks/releases/artists) thereby orphaned.
pub fn remove_root(conn: &Connection, path: &str) -> anyhow::Result<()> {
    let normalized = path.trim_end_matches('/');
    conn.execute(
        "DELETE FROM root WHERE path = ?1",
        rusqlite::params![normalized],
    )?;
    let prefix = format!("{normalized}/");
    // Drop files beneath this root, but only those no longer covered by ANY other
    // still-registered root (`r` already excludes the root deleted just above).
    // Music that also lives under a remaining root — a parent folder still in the
    // library, or an overlapping sibling — stays: removing one folder must never
    // evict files another registered folder still includes (and a rescan of that
    // folder would re-add them anyway, so deleting them would be incoherent).
    conn.execute(
        "DELETE FROM file
         WHERE substr(path, 1, ?1) = ?2
           AND NOT EXISTS (
               SELECT 1 FROM root r
               WHERE substr(file.path, 1, length(r.path) + 1) = r.path || '/'
           )",
        rusqlite::params![prefix.chars().count() as i64, prefix],
    )?;
    scan::prune_orphans(conn)?;
    Ok(())
}

/// List persisted root folders, ordered by path.
pub fn list_roots(conn: &Connection) -> anyhow::Result<Vec<String>> {
    let mut stmt = conn.prepare("SELECT path FROM root ORDER BY path")?;
    let roots = stmt
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(roots)
}
