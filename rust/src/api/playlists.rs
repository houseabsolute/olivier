use crate::catalog::playlists::{self, Playlist};
use crate::catalog::schema::QueueTrack;
use crate::db;

pub fn create_playlist(db_path: String, name: String) -> anyhow::Result<i64> {
    playlists::create_playlist(&db::open(&db_path)?, &name)
}

pub fn rename_playlist(db_path: String, id: i64, name: String) -> anyhow::Result<()> {
    playlists::rename_playlist(&db::open(&db_path)?, id, &name)
}

pub fn delete_playlist(db_path: String, id: i64) -> anyhow::Result<()> {
    playlists::delete_playlist(&db::open(&db_path)?, id)
}

pub fn reorder_playlists(db_path: String, ids: Vec<i64>) -> anyhow::Result<()> {
    playlists::reorder_playlists(&db::open(&db_path)?, &ids)
}

pub fn list_playlists(db_path: String) -> anyhow::Result<Vec<Playlist>> {
    playlists::list_playlists(&db::open(&db_path)?)
}

pub fn playlist_tracks(db_path: String, id: i64) -> anyhow::Result<Vec<QueueTrack>> {
    playlists::playlist_tracks(&db::open(&db_path)?, id)
}

pub fn add_to_playlist(db_path: String, id: i64, paths: Vec<String>) -> anyhow::Result<()> {
    playlists::add_to_playlist(&db::open(&db_path)?, id, &paths)
}

pub fn set_playlist_items(db_path: String, id: i64, paths: Vec<String>) -> anyhow::Result<()> {
    playlists::set_playlist_items(&db::open(&db_path)?, id, &paths)
}
