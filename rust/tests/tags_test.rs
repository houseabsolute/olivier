use rust_lib_olivier::tags::read_tags;
use std::path::Path;

const FILES: &[&str] = &[
    "sample.mp3", "sample.flac", "sample.ogg",
    "sample.opus", "sample.m4a", "sample.alac.m4a",
];

fn fixture(name: &str) -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
}

#[test]
fn reads_common_fields_for_all_formats() {
    for name in FILES {
        let t = read_tags(&fixture(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(t.title.as_deref(), Some("正しい街"), "{name} title");
        assert_eq!(t.artist.as_deref(), Some("椎名林檎"), "{name} artist");
        assert_eq!(t.album.as_deref(), Some("無罪モラトリアム"), "{name} album");
        assert_eq!(t.album_artist.as_deref(), Some("椎名林檎"), "{name} album_artist");
        assert_eq!(t.track_no, Some(1), "{name} track_no");
        assert_eq!(t.disc_no, Some(1), "{name} disc_no");
        assert!(t.length_ms >= 900 && t.length_ms <= 1200, "{name} length {}", t.length_ms);
    }
}

#[test]
fn reads_musicbrainz_ids_for_all_formats() {
    for name in FILES {
        let t = read_tags(&fixture(name)).unwrap();
        assert_eq!(t.recording_mbid.as_deref(),
                   Some("aaaaaaaa-0000-0000-0000-000000000001"), "{name} recording");
        assert_eq!(t.release_mbid.as_deref(),
                   Some("bbbbbbbb-0000-0000-0000-000000000001"), "{name} release");
        assert_eq!(t.release_group_mbid.as_deref(),
                   Some("cccccccc-0000-0000-0000-000000000001"), "{name} rg");
        assert_eq!(t.artist_mbid.as_deref(),
                   Some("dddddddd-0000-0000-0000-000000000001"), "{name} artist");
        assert_eq!(t.album_artist_mbid.as_deref(),
                   Some("dddddddd-0000-0000-0000-000000000001"), "{name} albumartist");
        assert_eq!(t.release_track_mbid.as_deref(),
                   Some("eeeeeeee-0000-0000-0000-000000000001"), "{name} releasetrack");
    }
}

const MP4_FILES: &[&str] = &["sample.m4a", "sample.alac.m4a"];

#[test]
fn reads_original_and_reissue_dates() {
    for name in FILES {
        let t = read_tags(&fixture(name)).unwrap();
        // Reissue date (TDRC / DATE / ©day) is present in all six formats.
        assert!(t.reissue_date.as_deref().unwrap_or("").starts_with("2008"),
                "{name} reissue_date = {:?}", t.reissue_date);
        if MP4_FILES.contains(name) {
            // MP4/ALAC carry no standard original-date atom (Picard writes none);
            // original year arrives via MusicBrainz enrichment in Phase 2.
            assert_eq!(t.original_date, None, "{name} original_date should be None for MP4");
        } else {
            assert!(t.original_date.as_deref().unwrap_or("").starts_with("1999"),
                    "{name} original_date = {:?}", t.original_date);
        }
    }
}
