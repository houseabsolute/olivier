use rust_lib_olivier::catalog::ids::{album_artist_key, sort_name};
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
