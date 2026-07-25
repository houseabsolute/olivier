use rusqlite::Connection;

use crate::catalog::scan;
use crate::decision_log::DecisionLog;

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
    scan::prune_orphans(conn, &DecisionLog::to_path(None))?;
    Ok(())
}

/// Move a root to a new location, rewriting every stored path beneath it.
///
/// Paths are stored absolute in four places — `root`, `file`, `queue_item` and
/// `playlist_item` — so relocating a library folder (or retargeting a catalog
/// copy at a different machine's layout) is a prefix rewrite across all four.
/// Without this, moving a folder orphans its entire catalog.
///
/// Returns the number of `file` rows rewritten. All four updates run in one
/// transaction: a failure leaves the catalog exactly as it was.
///
/// `playlist_item.path` declares `REFERENCES file(path)` with no `ON UPDATE`
/// clause, so it defaults to NO ACTION: with foreign keys enforced (rusqlite
/// turns them on), rewriting `file.path` breaks its referencing rows, and
/// rewriting `playlist_item.path` first points it at rows that don't exist yet.
/// Either order violates the constraint mid-transaction, so this defers foreign
/// keys to commit time — both sides are consistent again by then.
///
/// Rebasing a root onto itself is a no-op that still rewrites every row to the
/// same value. Rebasing *into* the old root (`/music` → `/music/sub`) is allowed:
/// each `UPDATE` is a single pass whose `WHERE` sees pre-update values, so paths
/// are never rewritten twice.
///
/// Must be called at autocommit level — it issues a bare `BEGIN`, so wrapping a
/// call in an outer transaction fails with "cannot start a transaction within a
/// transaction".
pub fn rebase_root(conn: &Connection, old_root: &str, new_root: &str) -> anyhow::Result<usize> {
    let old = old_root.trim_end_matches('/');
    let new = new_root.trim_end_matches('/');

    // Guard the degenerate cases before anything else: "" and "/" both trim to
    // the empty string, which would store an empty root whose "{root}/" prefix
    // matches every absolute path in the catalog.
    if new.is_empty() || !new.starts_with('/') {
        anyhow::bail!("{new_root:?} is not an absolute path");
    }

    // Open the transaction before validating so the checks and the rewrite see
    // one consistent snapshot of `root`.
    let tx = conn.unchecked_transaction()?;
    // Scoped to this transaction; SQLite resets it at commit or rollback.
    tx.pragma_update(None, "defer_foreign_keys", true)?;

    let roots: Vec<String> = {
        let mut stmt = tx.prepare("SELECT path FROM root")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    if !roots.iter().any(|r| r == old) {
        anyhow::bail!("{old} is not a registered root");
    }
    if old != new {
        // Merging two roots would collide on file.path's UNIQUE constraint, and
        // there's no sensible way to reconcile two catalogs of the same folder.
        // Nesting is rejected for the same reason — a nested destination can
        // collide with files already scanned under the outer root, and even when
        // it doesn't, it leaves overlapping roots that `remove_root`'s
        // "covered by ANY other root" rule then treats surprisingly.
        for r in roots.iter().filter(|r| *r != old) {
            if r == new {
                anyhow::bail!("{new} is already a registered root");
            }
            if new.starts_with(&format!("{r}/")) || r.starts_with(&format!("{new}/")) {
                anyhow::bail!("{new} overlaps the registered root {r}");
            }
        }
    }

    let prefix = format!("{old}/");
    let replacement = format!("{new}/");
    // Match on the prefix *including* the trailing slash so a root that is a
    // string prefix of a sibling ("/music" vs "/music-archive") can't capture
    // the sibling's files. Length is in chars because SQLite's substr counts
    // characters, not bytes — the same convention as `remove_root`.
    let prefix_len = prefix.chars().count() as i64;
    let keep_from = prefix_len + 1;

    let rewrite = |table: &str| -> anyhow::Result<usize> {
        Ok(tx.execute(
            &format!(
                "UPDATE {table} SET path = ?1 || substr(path, ?2)
                 WHERE substr(path, 1, ?3) = ?4"
            ),
            rusqlite::params![replacement, keep_from, prefix_len, prefix],
        )?)
    };
    let rewritten = rewrite("file")?;
    rewrite("queue_item")?;
    rewrite("playlist_item")?;
    tx.execute(
        "UPDATE root SET path = ?1 WHERE path = ?2",
        rusqlite::params![new, old],
    )?;
    tx.commit()?;
    Ok(rewritten)
}

/// List persisted root folders, ordered by path.
pub fn list_roots(conn: &Connection) -> anyhow::Result<Vec<String>> {
    let mut stmt = conn.prepare("SELECT path FROM root ORDER BY path")?;
    let roots = stmt
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(roots)
}
