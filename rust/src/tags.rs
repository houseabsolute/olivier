use std::borrow::Cow;
use std::path::Path;

use lofty::config::ParseOptions;
use lofty::file::{AudioFile, FileType};
use lofty::prelude::{Accessor, ItemKey};
use lofty::probe::Probe;
use lofty::tag::Tag;

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

    Ok(out)
}
