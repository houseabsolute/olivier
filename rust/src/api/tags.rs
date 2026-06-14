use crate::tags::{self, TrackTags};

/// FFI-facing tag read. Returns the typed DTO straight to Dart.
pub fn read_track_tags(path: String) -> anyhow::Result<TrackTags> {
    tags::read_tags(std::path::Path::new(&path))
}
