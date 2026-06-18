use crate::catalog::query;
use crate::catalog::roots;
use crate::catalog::scan::{self, ScanProgress};
use crate::catalog::schema::{Album, Artist, QueueTrack, Track};
use crate::db;
use crate::frb_generated::StreamSink;

pub fn scan_library(
    db_path: String,
    roots: Vec<String>,
    sink: StreamSink<ScanProgress>,
) -> anyhow::Result<()> {
    let mut conn = db::open(&db_path)?;
    scan::scan_roots(&mut conn, &roots, |p| {
        let _ = sink.add(p);
    })
}

pub fn list_artists(
    db_path: String,
    after: Option<String>,
    limit: u32,
) -> anyhow::Result<Vec<Artist>> {
    query::artists_page(&db::open(&db_path)?, after.as_deref(), limit)
}

pub fn list_albums(db_path: String, album_artist_mbid: String) -> anyhow::Result<Vec<Album>> {
    query::albums_for_artist(&db::open(&db_path)?, &album_artist_mbid)
}

pub fn list_tracks(db_path: String, release_mbid: String) -> anyhow::Result<Vec<Track>> {
    query::tracks_for_album(&db::open(&db_path)?, &release_mbid)
}

pub fn album_file_paths(db_path: String, release_mbid: String) -> anyhow::Result<Vec<String>> {
    query::file_paths_for_album(&db::open(&db_path)?, &release_mbid)
}

pub fn tracks_for_paths(db_path: String, paths: Vec<String>) -> anyhow::Result<Vec<QueueTrack>> {
    query::tracks_for_paths(&db::open(&db_path)?, &paths)
}

pub fn track_path(db_path: String, track_id: i64) -> anyhow::Result<Option<String>> {
    query::track_path(&db::open(&db_path)?, track_id)
}

pub fn record_play(db_path: String, track_id: i64, played_at: i64) -> anyhow::Result<()> {
    query::record_play(&db::open(&db_path)?, track_id, played_at)
}

pub fn add_root(db_path: String, path: String) -> anyhow::Result<()> {
    roots::add_root(&db::open(&db_path)?, &path)
}

pub fn remove_root(db_path: String, path: String) -> anyhow::Result<()> {
    roots::remove_root(&db::open(&db_path)?, &path)
}

pub fn list_roots(db_path: String) -> anyhow::Result<Vec<String>> {
    roots::list_roots(&db::open(&db_path)?)
}
