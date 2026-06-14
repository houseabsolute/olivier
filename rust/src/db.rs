use rusqlite::Connection;
use rusqlite_migration::{Migrations, M};

const MIGRATION_SLICE: &[M<'_>] = &[
    M::up("CREATE VIRTUAL TABLE search USING fts5(text, tokenize='trigram');"),
    M::up(
        "CREATE TABLE queue_item (
            position INTEGER PRIMARY KEY,
            path TEXT NOT NULL,
            shuffled_position INTEGER
         );
         CREATE TABLE playback_state (
            id INTEGER PRIMARY KEY CHECK (id = 0),
            current_index INTEGER NOT NULL,
            position_ms INTEGER NOT NULL,
            shuffle INTEGER NOT NULL
         );",
    ),
    M::up(
        "CREATE TABLE artist (
            mbid       TEXT PRIMARY KEY,
            name       TEXT NOT NULL,
            sort_name  TEXT NOT NULL
         );
         CREATE TABLE release_group (
            mbid                TEXT PRIMARY KEY,
            title               TEXT,
            first_release_date  TEXT
         );
         CREATE TABLE release (
            mbid                TEXT PRIMARY KEY,
            release_group_mbid  TEXT REFERENCES release_group(mbid),
            album_artist_mbid   TEXT REFERENCES artist(mbid),
            title               TEXT,
            date                TEXT
         );
         CREATE TABLE track (
            id              INTEGER PRIMARY KEY,
            release_mbid    TEXT NOT NULL REFERENCES release(mbid),
            recording_mbid  TEXT,
            artist          TEXT,
            disc            INTEGER NOT NULL DEFAULT 1,
            position        INTEGER NOT NULL DEFAULT 1,
            title           TEXT,
            length_ms       INTEGER,
            UNIQUE(release_mbid, disc, position)
         );
         CREATE TABLE file (
            id              INTEGER PRIMARY KEY,
            path            TEXT UNIQUE NOT NULL,
            mtime           INTEGER NOT NULL,
            size            INTEGER NOT NULL,
            codec           TEXT,
            track_id        INTEGER NOT NULL REFERENCES track(id),
            added_at        INTEGER NOT NULL,
            has_cover       INTEGER NOT NULL DEFAULT 0,
            enriched        INTEGER NOT NULL DEFAULT 0,
            scan_epoch      INTEGER NOT NULL DEFAULT 0
         );
         CREATE TABLE track_stats (
            track_id     INTEGER PRIMARY KEY REFERENCES track(id),
            last_played  INTEGER,
            play_count   INTEGER NOT NULL DEFAULT 0,
            first_played INTEGER
         );
         CREATE INDEX idx_release_albumartist ON release(album_artist_mbid);
         CREATE INDEX idx_track_release ON track(release_mbid);
         CREATE INDEX idx_artist_sort ON artist(sort_name);
         CREATE INDEX idx_file_track ON file(track_id);",
    ),
];
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
        // NOTE (Phase 3): this LIKE does not escape % or _ in `query`. Fine for the
        // Phase-0 spike, but add `ESCAPE` handling before this backs real search.
        let mut stmt = conn.prepare("SELECT text FROM search WHERE text LIKE '%' || ?1 || '%'")?;
        let rows = stmt.query_map([query], |r| r.get::<_, String>(0))?;
        for r in rows {
            out.push(r?);
        }
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueSnapshot {
    pub paths: Vec<String>,
    pub current_index: u32,
    pub position_ms: u64,
    pub shuffle: bool,
}

pub fn save_queue(conn: &Connection, snap: &QueueSnapshot) -> anyhow::Result<()> {
    // One transaction so a crash mid-save can't leave a truncated queue, and so
    // the whole replace is a single fsync rather than one per row.
    let tx = conn.unchecked_transaction()?;
    tx.execute("DELETE FROM queue_item", [])?;
    for (i, p) in snap.paths.iter().enumerate() {
        tx.execute(
            "INSERT INTO queue_item(position, path) VALUES (?1, ?2)",
            rusqlite::params![i as i64, p],
        )?;
    }
    tx.execute(
        "INSERT INTO playback_state(id, current_index, position_ms, shuffle)
         VALUES (0, ?1, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET current_index=?1, position_ms=?2, shuffle=?3",
        rusqlite::params![
            snap.current_index as i64,
            snap.position_ms as i64,
            snap.shuffle as i64
        ],
    )?;
    tx.commit()?;
    Ok(())
}

pub fn load_queue(conn: &Connection) -> anyhow::Result<Option<QueueSnapshot>> {
    let mut stmt = conn.prepare("SELECT path FROM queue_item ORDER BY position")?;
    let paths: Vec<String> = stmt
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    if paths.is_empty() {
        return Ok(None);
    }
    let st = conn.query_row(
        "SELECT current_index, position_ms, shuffle FROM playback_state WHERE id = 0",
        [],
        |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        },
    );
    let (ci, pos, sh) = st.unwrap_or((0, 0, 0));
    Ok(Some(QueueSnapshot {
        paths,
        current_index: ci as u32,
        position_ms: pos as u64,
        shuffle: sh != 0,
    }))
}
