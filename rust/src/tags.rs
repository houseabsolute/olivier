use std::path::Path;

use lofty::file::{AudioFile, FileType, TaggedFileExt};
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

#[derive(Default)]
struct Ids {
    recording_mbid: Option<String>,
    release_mbid: Option<String>,
    release_group_mbid: Option<String>,
    artist_mbid: Option<String>,
    album_artist_mbid: Option<String>,
    release_track_mbid: Option<String>,
}

fn read_ids(path: &Path, ft: FileType) -> anyhow::Result<Ids> {
    use lofty::config::ParseOptions;
    let mut f = std::fs::File::open(path)?;
    let mut ids = Ids::default();

    match ft {
        FileType::Mpeg => {
            use lofty::id3::v2::Frame;
            use lofty::mpeg::MpegFile;
            let file = MpegFile::read_from(&mut f, ParseOptions::new())?;
            if let Some(tag) = file.id3v2() {
                ids.release_mbid = tag.get_user_text("MusicBrainz Album Id").map(str::to_owned);
                ids.release_group_mbid = tag
                    .get_user_text("MusicBrainz Release Group Id")
                    .map(str::to_owned);
                ids.artist_mbid = tag
                    .get_user_text("MusicBrainz Artist Id")
                    .map(str::to_owned);
                ids.album_artist_mbid = tag
                    .get_user_text("MusicBrainz Album Artist Id")
                    .map(str::to_owned);
                ids.release_track_mbid = tag
                    .get_user_text("MusicBrainz Release Track Id")
                    .map(str::to_owned);
                // from_utf8(...).ok() (not from_utf8_lossy) so a corrupt UFID yields
                // None rather than a U+FFFD-mangled, lookup-breaking MBID string.
                ids.recording_mbid = tag.into_iter().find_map(|frame| match frame {
                    Frame::UniqueFileIdentifier(u) if u.owner == "http://musicbrainz.org" => {
                        String::from_utf8(u.identifier.to_vec()).ok()
                    }
                    _ => None,
                });
            }
        }
        FileType::Flac | FileType::Vorbis | FileType::Opus => {
            use lofty::ogg::VorbisComments;
            // Read the six MBID keys out of a VorbisComments into `ids`.
            fn from_vc(vc: &VorbisComments, ids: &mut Ids) {
                let g = |k: &str| vc.get(k).map(str::to_owned);
                ids.recording_mbid = g("MUSICBRAINZ_TRACKID");
                ids.release_mbid = g("MUSICBRAINZ_ALBUMID");
                ids.release_group_mbid = g("MUSICBRAINZ_RELEASEGROUPID");
                ids.artist_mbid = g("MUSICBRAINZ_ARTISTID");
                ids.album_artist_mbid = g("MUSICBRAINZ_ALBUMARTISTID");
                ids.release_track_mbid = g("MUSICBRAINZ_RELEASETRACKID");
            }
            match ft {
                FileType::Flac => {
                    let file = lofty::flac::FlacFile::read_from(&mut f, ParseOptions::new())?;
                    if let Some(vc) = file.vorbis_comments() {
                        from_vc(vc, &mut ids);
                    }
                }
                FileType::Vorbis => {
                    let file = lofty::ogg::VorbisFile::read_from(&mut f, ParseOptions::new())?;
                    from_vc(file.vorbis_comments(), &mut ids);
                }
                FileType::Opus => {
                    let file = lofty::ogg::OpusFile::read_from(&mut f, ParseOptions::new())?;
                    from_vc(file.vorbis_comments(), &mut ids);
                }
                _ => unreachable!(),
            }
        }
        FileType::Mp4 => {
            use lofty::mp4::{AtomData, AtomIdent, Mp4File};
            use std::borrow::Cow;
            let file = Mp4File::read_from(&mut f, ParseOptions::new())?;
            if let Some(ilst) = file.ilst() {
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
                ids.recording_mbid = ff("MusicBrainz Track Id");
                ids.release_mbid = ff("MusicBrainz Album Id");
                ids.release_group_mbid = ff("MusicBrainz Release Group Id");
                ids.artist_mbid = ff("MusicBrainz Artist Id");
                ids.album_artist_mbid = ff("MusicBrainz Album Artist Id");
                ids.release_track_mbid = ff("MusicBrainz Release Track Id");
            }
        }
        _ => {}
    }
    Ok(ids)
}

pub fn read_tags(path: &Path) -> anyhow::Result<TrackTags> {
    let tagged = Probe::open(path)?.read()?;
    let length_ms = tagged.properties().duration().as_millis() as u64;
    let ft = tagged.file_type();

    let mut out = TrackTags {
        length_ms,
        ..Default::default()
    };
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
        out.reissue_date = tag
            .get_string(ItemKey::RecordingDate)
            .map(|s| s.to_string());
        out.original_date = tag
            .get_string(ItemKey::OriginalReleaseDate)
            .map(|s| s.to_string());
    }

    let ids = read_ids(path, ft)?;
    out.recording_mbid = ids.recording_mbid;
    out.release_mbid = ids.release_mbid;
    out.release_group_mbid = ids.release_group_mbid;
    out.artist_mbid = ids.artist_mbid;
    out.album_artist_mbid = ids.album_artist_mbid;
    out.release_track_mbid = ids.release_track_mbid;

    Ok(out)
}
