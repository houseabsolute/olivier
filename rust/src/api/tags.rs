use crate::tags::{self, TrackTags};

/// FFI-facing tag read. Returns the typed DTO straight to Dart.
pub fn read_track_tags(path: String) -> anyhow::Result<TrackTags> {
    tags::read_tags(std::path::Path::new(&path))
}

/// Extract the first embedded cover picture from `file_path` and cache it
/// under `cache_dir`.  Returns the path of the cached image file, or `None`
/// if the audio file has no embedded art.
pub fn extract_cover(file_path: String, cache_dir: String) -> anyhow::Result<Option<String>> {
    tags::extract_cover_to(&file_path, &cache_dir)
}
