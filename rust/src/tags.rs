use std::borrow::Cow;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;

use lofty::config::ParseOptions;
use lofty::file::TaggedFileExt;
use lofty::file::{AudioFile, FileType};
use lofty::picture::MimeType;
use lofty::prelude::{Accessor, ItemKey};
use lofty::probe::Probe;
use lofty::tag::Tag;

use crate::catalog::ids::is_mbid;

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
    pub artist_sort: Option<String>,
    pub album_artist_sort: Option<String>,
    pub codec: Option<String>,
}

fn fill_common(out: &mut TrackTags, tag: &Tag) {
    out.title = tag.title().map(|c| c.to_string());
    out.artist = tag.artist().map(|c| c.to_string());
    out.album = tag.album().map(|c| c.to_string());
    out.album_artist = tag.get_string(ItemKey::AlbumArtist).map(|s| s.to_string());
    out.track_no = tag.track();
    out.track_total = tag.track_total();
    out.disc_no = tag.disk();
    out.disc_total = tag.disk_total();
    out.has_cover = !tag.pictures().is_empty();
    out.reissue_date = tag
        .get_string(ItemKey::RecordingDate)
        .map(|s| s.to_string());
    out.original_date = tag
        .get_string(ItemKey::OriginalReleaseDate)
        .map(|s| s.to_string());
}

/// A MusicBrainz ID read from a tag may be multi-valued (several IDs joined by a
/// NUL on a split/collab release) or otherwise malformed; either is unusable as
/// a single MBID and would 400 MusicBrainz, so drop it (the scanner then falls
/// back to a synthetic credit key). A clean single UUID is kept (trimmed).
fn clean_mbid(raw: Option<String>) -> Option<String> {
    let v = raw?;
    if v.contains('\0') {
        return None;
    }
    let t = v.trim();
    is_mbid(t).then(|| t.to_string())
}

/// A credit *name* may also be NUL-joined for multi-artist releases; render it as
/// a single combined credit (e.g. "k. / Low") for display + synthetic keying.
fn clean_credit(raw: Option<String>) -> Option<String> {
    let v = raw?;
    if !v.contains('\0') {
        return Some(v);
    }
    let joined = v
        .split('\0')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" / ");
    (!joined.is_empty()).then_some(joined)
}

pub fn read_tags(path: &Path) -> anyhow::Result<TrackTags> {
    // Detect file type without a full parse — Probe::open() infers from the
    // extension, so no extra I/O is needed here.
    let ft = Probe::open(path)?
        .file_type()
        .ok_or_else(|| anyhow::anyhow!("unknown file type for {:?}", path))?;

    let mut out = TrackTags::default();
    let mut f = std::fs::File::open(path)?;

    out.codec = Some(
        match ft {
            FileType::Mpeg => "mp3",
            FileType::Flac => "flac",
            FileType::Vorbis => "vorbis",
            FileType::Opus => "opus",
            FileType::Mp4 => "m4a",
            _ => "unknown",
        }
        .to_string(),
    );

    match ft {
        FileType::Mpeg => {
            use lofty::id3::v2::{Frame, FrameId};
            use lofty::mpeg::MpegFile;

            let file = MpegFile::read_from(&mut f, ParseOptions::new())?;
            out.length_ms = file.properties().duration().as_millis() as u64;

            if let Some(id3) = file.id3v2() {
                // Sort names
                out.artist_sort = id3
                    .get_text(&FrameId::Valid(Cow::Borrowed("TSOP")))
                    .map(str::to_owned);
                out.album_artist_sort = id3
                    .get_text(&FrameId::Valid(Cow::Borrowed("TSO2")))
                    .map(str::to_owned);

                // MBIDs
                out.release_mbid = id3.get_user_text("MusicBrainz Album Id").map(str::to_owned);
                out.release_group_mbid = id3
                    .get_user_text("MusicBrainz Release Group Id")
                    .map(str::to_owned);
                out.artist_mbid = id3
                    .get_user_text("MusicBrainz Artist Id")
                    .map(str::to_owned);
                out.album_artist_mbid = id3
                    .get_user_text("MusicBrainz Album Artist Id")
                    .map(str::to_owned);
                out.release_track_mbid = id3
                    .get_user_text("MusicBrainz Release Track Id")
                    .map(str::to_owned);
                out.recording_mbid = id3.into_iter().find_map(|frame| match frame {
                    Frame::UniqueFileIdentifier(u) if u.owner == "http://musicbrainz.org" => {
                        String::from_utf8(u.identifier.to_vec()).ok()
                    }
                    _ => None,
                });

                // Common fields — convert native tag to unified Tag
                let unified: Tag = id3.clone().into();
                fill_common(&mut out, &unified);
            }
        }
        FileType::Flac => {
            use lofty::flac::FlacFile;

            let file = FlacFile::read_from(&mut f, ParseOptions::new())?;
            out.length_ms = file.properties().duration().as_millis() as u64;

            if let Some(vc) = file.vorbis_comments() {
                let g = |k: &str| vc.get(k).map(str::to_owned);

                out.artist_sort = g("ARTISTSORT");
                out.album_artist_sort = g("ALBUMARTISTSORT");

                out.recording_mbid = g("MUSICBRAINZ_TRACKID");
                out.release_mbid = g("MUSICBRAINZ_ALBUMID");
                out.release_group_mbid = g("MUSICBRAINZ_RELEASEGROUPID");
                out.artist_mbid = g("MUSICBRAINZ_ARTISTID");
                out.album_artist_mbid = g("MUSICBRAINZ_ALBUMARTISTID");
                out.release_track_mbid = g("MUSICBRAINZ_RELEASETRACKID");

                let unified: Tag = vc.clone().into();
                fill_common(&mut out, &unified);
            }
        }
        FileType::Vorbis => {
            use lofty::ogg::VorbisFile;

            let file = VorbisFile::read_from(&mut f, ParseOptions::new())?;
            out.length_ms = file.properties().duration().as_millis() as u64;

            let vc = file.vorbis_comments();
            let g = |k: &str| vc.get(k).map(str::to_owned);

            out.artist_sort = g("ARTISTSORT");
            out.album_artist_sort = g("ALBUMARTISTSORT");

            out.recording_mbid = g("MUSICBRAINZ_TRACKID");
            out.release_mbid = g("MUSICBRAINZ_ALBUMID");
            out.release_group_mbid = g("MUSICBRAINZ_RELEASEGROUPID");
            out.artist_mbid = g("MUSICBRAINZ_ARTISTID");
            out.album_artist_mbid = g("MUSICBRAINZ_ALBUMARTISTID");
            out.release_track_mbid = g("MUSICBRAINZ_RELEASETRACKID");

            let unified: Tag = vc.clone().into();
            fill_common(&mut out, &unified);
        }
        FileType::Opus => {
            use lofty::ogg::OpusFile;

            let file = OpusFile::read_from(&mut f, ParseOptions::new())?;
            out.length_ms = file.properties().duration().as_millis() as u64;

            let vc = file.vorbis_comments();
            let g = |k: &str| vc.get(k).map(str::to_owned);

            out.artist_sort = g("ARTISTSORT");
            out.album_artist_sort = g("ALBUMARTISTSORT");

            out.recording_mbid = g("MUSICBRAINZ_TRACKID");
            out.release_mbid = g("MUSICBRAINZ_ALBUMID");
            out.release_group_mbid = g("MUSICBRAINZ_RELEASEGROUPID");
            out.artist_mbid = g("MUSICBRAINZ_ARTISTID");
            out.album_artist_mbid = g("MUSICBRAINZ_ALBUMARTISTID");
            out.release_track_mbid = g("MUSICBRAINZ_RELEASETRACKID");

            let unified: Tag = vc.clone().into();
            fill_common(&mut out, &unified);
        }
        FileType::Mp4 => {
            use lofty::mp4::{AtomData, AtomIdent, Mp4File};

            let file = Mp4File::read_from(&mut f, ParseOptions::new())?;
            out.length_ms = file.properties().duration().as_millis() as u64;

            if let Some(ilst) = file.ilst() {
                // Helper for Freeform (----:com.apple.iTunes:*) atoms
                let ff = |name: &str| -> Option<String> {
                    let ident = AtomIdent::Freeform {
                        mean: Cow::Borrowed("com.apple.iTunes"),
                        name: Cow::Borrowed(name),
                    };
                    ilst.get(&ident)
                        .and_then(|a| a.data().next())
                        .and_then(|d| match d {
                            AtomData::UTF8(s) => Some(s.clone()),
                            _ => None,
                        })
                };

                // Helper for Fourcc atoms returning UTF8
                let fc = |fourcc: [u8; 4]| -> Option<String> {
                    ilst.get(&AtomIdent::Fourcc(fourcc))
                        .and_then(|a| a.data().next())
                        .and_then(|d| match d {
                            AtomData::UTF8(s) => Some(s.clone()),
                            _ => None,
                        })
                };

                out.artist_sort = fc(*b"soar");
                out.album_artist_sort = fc(*b"soaa");

                out.recording_mbid = ff("MusicBrainz Track Id");
                out.release_mbid = ff("MusicBrainz Album Id");
                out.release_group_mbid = ff("MusicBrainz Release Group Id");
                out.artist_mbid = ff("MusicBrainz Artist Id");
                out.album_artist_mbid = ff("MusicBrainz Album Artist Id");
                out.release_track_mbid = ff("MusicBrainz Release Track Id");

                let unified: Tag = ilst.clone().into();
                fill_common(&mut out, &unified);
            }
        }
        _ => {}
    }

    // Sanitize tag-derived MB IDs + credit names: a multi-valued (NUL-joined)
    // split/collab tag must not yield a malformed MBID (which would 400 MB and
    // risk an IP block) or a NUL-bearing display name. A dropped album-artist
    // MBID becomes a synthetic combined credit via ids::album_artist_key.
    out.recording_mbid = clean_mbid(out.recording_mbid.take());
    out.release_mbid = clean_mbid(out.release_mbid.take());
    out.release_group_mbid = clean_mbid(out.release_group_mbid.take());
    out.artist_mbid = clean_mbid(out.artist_mbid.take());
    out.album_artist_mbid = clean_mbid(out.album_artist_mbid.take());
    out.release_track_mbid = clean_mbid(out.release_track_mbid.take());
    out.artist = clean_credit(out.artist.take());
    out.album_artist = clean_credit(out.album_artist.take());
    // Sort names come from the same multi-value sources (ID3 TSOP/TSO2,
    // ARTISTSORT/ALBUMARTISTSORT) and can be NUL-joined too — clean them so a
    // split album doesn't store a NUL-bearing sort key.
    out.artist_sort = clean_credit(out.artist_sort.take());
    out.album_artist_sort = clean_credit(out.album_artist_sort.take());

    Ok(out)
}

/// Extract the first embedded cover picture from `path` and write it to a
/// stable cache file under `cache_dir`.  Returns the path of the cached file,
/// or `None` if the audio file contains no embedded pictures.
///
/// The cache key is a per-build hex hash of the source file path, so repeated
/// calls for the same file are cheap (a quick `Path::exists` check and
/// return).  `DefaultHasher` is not guaranteed stable across Rust toolchain
/// versions, but a cache miss after an upgrade is harmless — the file is just
/// re-extracted (any stale cache file is simply left behind).
pub fn extract_cover_to(path: &str, cache_dir: &str) -> anyhow::Result<Option<String>> {
    // ------------------------------------------------------------------
    // 1. Open the file and read all tags (pictures included).
    // ------------------------------------------------------------------
    let audio_path = Path::new(path);
    let tagged_file = Probe::open(audio_path)
        .map_err(|e| anyhow::anyhow!("failed to open {:?}: {}", audio_path, e))?
        .read()
        .map_err(|e| anyhow::anyhow!("failed to read tags from {:?}: {}", audio_path, e))?;

    // Get the primary tag (first tag in the file, whichever type it is).
    let tag = match tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
    {
        Some(t) => t,
        None => return Ok(None),
    };

    let picture = match tag.pictures().first() {
        Some(p) => p,
        None => return Ok(None),
    };

    // A zero-byte PICTURE block would otherwise be written as an empty file and
    // then returned forever as a cache hit, handing MPRIS a broken file:// URI.
    if picture.data().is_empty() {
        return Ok(None);
    }

    // ------------------------------------------------------------------
    // 2. Determine file extension from MIME type.
    // ------------------------------------------------------------------
    let ext = match picture.mime_type() {
        Some(MimeType::Png) => "png",
        Some(MimeType::Jpeg) => "jpg",
        _ => "jpg", // sensible default for unknown / missing MIME
    };

    // ------------------------------------------------------------------
    // 3. Build a stable cache path.
    // ------------------------------------------------------------------
    let mut hasher = DefaultHasher::new();
    path.hash(&mut hasher);
    let hash = hasher.finish();

    let cache_path = Path::new(cache_dir).join(format!("olivier-cover-{:016x}.{}", hash, ext));

    // ------------------------------------------------------------------
    // 4. Return cached file if it already exists (cache hit).
    // ------------------------------------------------------------------
    if cache_path.exists() {
        return Ok(Some(
            cache_path
                .to_str()
                .ok_or_else(|| anyhow::anyhow!("cache path is not valid UTF-8"))?
                .to_owned(),
        ));
    }

    // ------------------------------------------------------------------
    // 5. Write bytes to cache file (create dir if needed).
    // ------------------------------------------------------------------
    std::fs::create_dir_all(cache_dir)
        .map_err(|e| anyhow::anyhow!("failed to create cache dir {:?}: {}", cache_dir, e))?;

    std::fs::write(&cache_path, picture.data())
        .map_err(|e| anyhow::anyhow!("failed to write cover to {:?}: {}", cache_path, e))?;

    Ok(Some(
        cache_path
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("cache path is not valid UTF-8"))?
            .to_owned(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_mbid_keeps_single_uuid_drops_multi_and_garbage() {
        assert_eq!(
            clean_mbid(Some("9e414497-23b7-4ab7-9ec6-8ea9864c9e87".into())).as_deref(),
            Some("9e414497-23b7-4ab7-9ec6-8ea9864c9e87")
        );
        assert_eq!(
            clean_mbid(Some(" 9e414497-23b7-4ab7-9ec6-8ea9864c9e87 ".into())).as_deref(),
            Some("9e414497-23b7-4ab7-9ec6-8ea9864c9e87")
        );
        assert_eq!(
            clean_mbid(Some(
                "04816b1b-e203-4917-b4a1-8c31ced2eb82\x0042faad37-8aaa-42e4-a300-5a7dae79ed24"
                    .into()
            )),
            None
        );
        assert_eq!(clean_mbid(Some("garbage".into())), None);
        assert_eq!(clean_mbid(None), None);
    }

    #[test]
    fn clean_credit_joins_nul_values() {
        assert_eq!(
            clean_credit(Some("k.\0Low".into())).as_deref(),
            Some("k. / Low")
        );
        assert_eq!(
            clean_credit(Some("k. / Low".into())).as_deref(),
            Some("k. / Low")
        );
        assert_eq!(clean_credit(None), None);
    }
}
