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
