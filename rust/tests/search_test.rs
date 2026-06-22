use rust_lib_olivier::catalog::query::search_catalog;
use rust_lib_olivier::db::open;

fn seed(conn: &rusqlite::Connection) {
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name,transliteration,name_original)
         VALUES ('A','Shiina Ringo','Shiina, Ringo','Shiina Ringo','椎名林檎')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R','A','無罪モラトリアム')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release_title_alt(release_mbid,kind,title) VALUES ('R','translit','Muzai Moratorium')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,recording_mbid,disc,position,title)
         VALUES (1,'R','REC1',1,1,'歌舞伎町の女王')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track_title_alt(recording_mbid,kind,title) VALUES ('REC1','translit','Kabukicho no Joo')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,recording_mbid,disc,position,title)
         VALUES (2,'R','REC2',1,2,'50% off')",
        [],
    )
    .unwrap();
}

#[test]
fn artist_matches_reading_and_original_only() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    let r = search_catalog(&conn, "shiina", 8).unwrap();
    assert_eq!(r.artists.len(), 1);
    assert_eq!(r.artists[0].mbid, "A");
    assert!(
        r.tracks.is_empty(),
        "artist match must not surface its tracks"
    );
    assert!(
        r.albums.is_empty(),
        "artist match must not surface its albums"
    );
    let r2 = search_catalog(&conn, "椎名", 8).unwrap();
    assert_eq!(r2.artists.len(), 1);
    let r3 = search_catalog(&conn, "SHIINA", 8).unwrap();
    assert_eq!(r3.artists.len(), 1);
}

#[test]
fn album_matches_translit() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    let r = search_catalog(&conn, "moratorium", 8).unwrap();
    assert_eq!(r.albums.len(), 1);
    assert_eq!(r.albums[0].release_mbid, "R");
    assert_eq!(r.albums[0].album_artist_mbid.as_deref(), Some("A"));
}

#[test]
fn track_matches_translit_and_carries_nav_keys() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    let r = search_catalog(&conn, "kabukicho", 8).unwrap();
    assert_eq!(r.tracks.len(), 1);
    let t = &r.tracks[0];
    assert_eq!(t.id, 1);
    assert_eq!(t.release_mbid, "R");
    assert_eq!(t.album_artist_mbid.as_deref(), Some("A"));
    assert_eq!(t.title_translit.as_deref(), Some("Kabukicho no Joo"));
}

#[test]
fn like_wildcards_are_escaped() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    let r = search_catalog(&conn, "50%", 8).unwrap();
    assert_eq!(r.tracks.len(), 1);
    assert_eq!(r.tracks[0].id, 2);
}

#[test]
fn blank_and_caps() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    let r = search_catalog(&conn, "ringo", 1).unwrap();
    assert!(r.artists.len() <= 1);
}
