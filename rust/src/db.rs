use rusqlite::Connection;
use rusqlite_migration::{Migrations, M};

const MIGRATION_SLICE: &[M<'_>] = &[M::up(
    "CREATE VIRTUAL TABLE search USING fts5(text, tokenize='trigram');",
)];
const MIGRATIONS: Migrations<'_> = Migrations::from_slice(MIGRATION_SLICE);

pub fn open(path: &str) -> anyhow::Result<Connection> {
    let mut conn = Connection::open(path)?;
    if path != ":memory:" {
        // WAL only applies to file-backed DBs; it's a silent no-op for :memory:.
        conn.pragma_update(None, "journal_mode", "WAL")?;
    }
    MIGRATIONS.to_latest(&mut conn)?;
    Ok(conn)
}

/// CJK-aware contains: the trigram tokenizer's MATCH requires >=3 chars, so for
/// 1-2 char queries fall back to LIKE (a correctness fallback the trigram table
/// still supports; treat its cost as a scan for such short patterns).
pub fn search_contains(conn: &Connection, query: &str) -> anyhow::Result<Vec<String>> {
    let char_len = query.chars().count();
    let mut out = Vec::new();
    if char_len >= 3 {
        let mut stmt = conn.prepare("SELECT text FROM search WHERE search MATCH ?1")?;
        let rows = stmt.query_map([query], |r| r.get::<_, String>(0))?;
        for r in rows {
            out.push(r?);
        }
    } else {
        let mut stmt = conn.prepare("SELECT text FROM search WHERE text LIKE '%' || ?1 || '%'")?;
        let rows = stmt.query_map([query], |r| r.get::<_, String>(0))?;
        for r in rows {
            out.push(r?);
        }
    }
    Ok(out)
}
