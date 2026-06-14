use std::path::Path;

use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::{Accessor, ItemKey};
use lofty::probe::Probe;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TrackTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_no: Option<u32>,
    pub track_total: Option<u32>,
    pub disc_no: Option<u32>,
    pub disc_total: Option<u32>,
    pub length_ms: u64,
    pub recording_mbid: Option<String>,
    pub release_mbid: Option<String>,
    pub release_group_mbid: Option<String>,
    pub artist_mbid: Option<String>,
    pub album_artist_mbid: Option<String>,
    pub release_track_mbid: Option<String>,
    pub original_date: Option<String>,
    pub reissue_date: Option<String>,
    pub has_cover: bool,
}

pub fn read_tags(path: &Path) -> anyhow::Result<TrackTags> {
    let tagged = Probe::open(path)?.read()?;
    let length_ms = tagged.properties().duration().as_millis() as u64;

    let mut out = TrackTags { length_ms, ..Default::default() };
    if let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) {
        out.title = tag.title().map(|c| c.to_string());
        out.artist = tag.artist().map(|c| c.to_string());
        out.album = tag.album().map(|c| c.to_string());
        out.album_artist = tag.get_string(ItemKey::AlbumArtist).map(|s| s.to_string());
        out.track_no = tag.track();
        out.track_total = tag.track_total();
        out.disc_no = tag.disk();
        out.disc_total = tag.disk_total();
        out.has_cover = !tag.pictures().is_empty();
    }
    Ok(out)
}
