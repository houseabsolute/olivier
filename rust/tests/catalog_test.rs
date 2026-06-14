use rust_lib_olivier::catalog::ids::{album_artist_key, sort_name};
use rust_lib_olivier::catalog::scan::scan_roots;
use rust_lib_olivier::db::open;

#[test]
fn migration_creates_catalog_tables() {
    let conn = open(":memory:").unwrap();
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table'
             AND name IN ('artist','release_group','release','track','file','track_stats')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 6);
}

#[test]
fn synthetic_keys_and_sort_names() {
    assert_eq!(album_artist_key(Some("abc"), "X"), "abc");
    assert_eq!(
        album_artist_key(None, "The Beatles"),
        "synth:aa:the beatles"
    );
    assert_eq!(
        sort_name("The Beatles", Some("Beatles, The")),
        "Beatles, The"
    );
    assert_eq!(sort_name("The Beatles", None), "Beatles");
    assert_eq!(sort_name("A Perfect Circle", None), "Perfect Circle");
}

#[test]
fn scan_populates_catalog_and_is_incremental() {
    let dir = tempfile::tempdir().unwrap();
    for f in ["sample.mp3", "sample.flac"] {
        std::fs::copy(
            format!("{}/tests/fixtures/{f}", env!("CARGO_MANIFEST_DIR")),
            dir.path().join(f),
        )
        .unwrap();
    }
    let mut conn = open(":memory:").unwrap();
    let root = dir.path().to_string_lossy().to_string();
    let mut changed = 0u64;
    scan_roots(&mut conn, std::slice::from_ref(&root), |p| {
        if p.done {
            changed = p.files_changed
        }
    })
    .unwrap();
    assert!(changed >= 2, "changed={changed}");
    let artists: i64 = conn
        .query_row("SELECT count(*) FROM artist", [], |r| r.get(0))
        .unwrap();
    assert_eq!(artists, 1);
    let albums: i64 = conn
        .query_row("SELECT count(*) FROM release", [], |r| r.get(0))
        .unwrap();
    assert_eq!(albums, 1);
    // re-scan: nothing changed
    let mut changed2 = u64::MAX;
    scan_roots(&mut conn, &[root], |p| {
        if p.done {
            changed2 = p.files_changed
        }
    })
    .unwrap();
    assert_eq!(changed2, 0);
}
