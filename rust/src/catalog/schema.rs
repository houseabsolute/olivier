#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Artist {
    pub mbid: String,
    pub name: String,
    pub sort_name: String,
    pub transliteration: Option<String>,
    /// Original-script name from MusicBrainz (e.g. 椎名林檎) — present once
    /// enriched; the tag-derived `name` may itself be a romanization.
    pub name_original: Option<String>,
}

/// Raw (non-coalesced) reading/sort fields for one artist — populates the
/// "Set reading" edit dialog so it can show the current override alongside the
/// MusicBrainz value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtistReading {
    pub name: String,
    pub name_original: Option<String>,
    pub mb_transliteration: Option<String>,
    pub transliteration_override: Option<String>,
    pub mb_sort_name: String,
    pub sort_name_override: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Album {
    pub release_mbid: String,
    pub title: String,
    pub album_artist: String,
    pub original_year: Option<String>, // 4-char year (queries project substr(date,1,4))
    pub reissue_year: Option<String>, // 4-char year; MP4 originals are absent so this is the only year
    pub title_translit: Option<String>,
    pub title_translate: Option<String>,
    /// earliest file added_at across the album's tracks, unix seconds; 0 if unknown
    pub added_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Track {
    pub id: i64,
    pub disc: u32,
    pub position: u32,
    pub title: String,
    pub artist: Option<String>,
    pub length_ms: Option<u64>,
    pub last_played: Option<i64>,
    pub added_at: i64,
    pub title_translit: Option<String>,
    pub title_translate: Option<String>,
}

/// A queue entry paired with its catalog metadata, keyed by file path — used to
/// rebuild the now-playing items for a restored session. `track_id` is None when
/// the path is no longer in the catalog (then `title` falls back to the filename).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueTrack {
    pub path: String,
    pub track_id: Option<i64>,
    pub title: String,
    pub artist: Option<String>,
    pub album: String,
    pub length_ms: Option<u64>,
    pub added_at: i64,
    pub last_played: Option<i64>,
    pub title_translit: Option<String>,
    pub title_translate: Option<String>,
}
