use rust_lib_olivier::catalog::ids::{album_artist_key, sort_name};
use rust_lib_olivier::catalog::query::{
    albums_for_artist, artists_page, file_paths_for_album, record_play, tracks_for_album,
};
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

// ── catalog query tests ────────────────────────────────────────────────────

fn seed_artists_page_db(conn: &rusqlite::Connection) {
    // Two album-artists; sort_names chosen so ordering is non-trivial.
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('mbid-beatles', 'The Beatles', 'Beatles, The')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('mbid-ringo', 'Ringo Sheena', 'Sheena, Ringo')",
        [],
    )
    .unwrap();
    // Each artist needs at least one release so artists_page includes them.
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('rel-beatles', 'mbid-beatles', 'Abbey Road', '1969-09-26')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('rel-ringo', 'mbid-ringo', 'Ringo', '1973-11-02')",
        [],
    )
    .unwrap();
}

#[test]
fn artists_page_ordered_and_keyset() {
    let conn = open(":memory:").unwrap();
    seed_artists_page_db(&conn);

    // First page: both artists, in sort_name order.
    let page1 = artists_page(&conn, None, 50).unwrap();
    assert_eq!(page1.len(), 2);
    assert_eq!(page1[0].sort_name, "Beatles, The");
    assert_eq!(page1[1].sort_name, "Sheena, Ringo");

    // Keyset: after "Beatles, The" → only Ringo.
    let page2 = artists_page(&conn, Some("Beatles, The"), 50).unwrap();
    assert_eq!(page2.len(), 1);
    assert_eq!(page2[0].sort_name, "Sheena, Ringo");

    // Keyset: after the last entry → empty.
    let page3 = artists_page(&conn, Some("Sheena, Ringo"), 50).unwrap();
    assert!(page3.is_empty());
}

#[test]
fn artists_page_limit() {
    let conn = open(":memory:").unwrap();
    seed_artists_page_db(&conn);

    // Limit of 1 should return only the first artist.
    let page = artists_page(&conn, None, 1).unwrap();
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].sort_name, "Beatles, The");
}

#[test]
fn albums_for_artist_ordered_by_year() {
    let conn = open(":memory:").unwrap();

    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('mbid-artist', 'Test Artist', 'Artist, Test')",
        [],
    )
    .unwrap();
    // release_group for the older album (1999)
    conn.execute(
        "INSERT INTO release_group(mbid, title, first_release_date) VALUES ('rg-1999', 'Old Album', '1999-02-24')",
        [],
    )
    .unwrap();
    // release_group for the newer album (2000)
    conn.execute(
        "INSERT INTO release_group(mbid, title, first_release_date) VALUES ('rg-2000', 'New Album', '2000-05-01')",
        [],
    )
    .unwrap();
    // Insert the newer release first so ordering is actually exercised.
    conn.execute(
        "INSERT INTO release(mbid, release_group_mbid, album_artist_mbid, title, date)
         VALUES ('rel-2000', 'rg-2000', 'mbid-artist', 'New Album', '2000-05-01')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, release_group_mbid, album_artist_mbid, title, date)
         VALUES ('rel-1999', 'rg-1999', 'mbid-artist', 'Old Album', '1999-02-24')",
        [],
    )
    .unwrap();

    let albums = albums_for_artist(&conn, "mbid-artist").unwrap();
    assert_eq!(albums.len(), 2);
    // 1999 album must come first.
    assert_eq!(albums[0].release_mbid, "rel-1999");
    assert_eq!(albums[1].release_mbid, "rel-2000");
    // Years must be 4-char strings, not full dates.
    assert_eq!(albums[0].original_year, Some("1999".to_string()));
    assert_eq!(albums[1].original_year, Some("2000".to_string()));
}

#[test]
fn tracks_for_album_ordered_by_disc_position() {
    let conn = open(":memory:").unwrap();

    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('mbid-a', 'Artist', 'Artist')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel-a', 'mbid-a', 'Album')",
        [],
    )
    .unwrap();
    // Insert in scrambled order: positions 3, 1, 2.
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (3, 'rel-a', 1, 3, 'Track Three')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1, 'rel-a', 1, 1, 'Track One')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2, 'rel-a', 1, 2, 'Track Two')",
        [],
    )
    .unwrap();

    let tracks = tracks_for_album(&conn, "rel-a").unwrap();
    assert_eq!(tracks.len(), 3);
    assert_eq!(tracks[0].position, 1);
    assert_eq!(tracks[0].title, "Track One");
    assert_eq!(tracks[1].position, 2);
    assert_eq!(tracks[1].title, "Track Two");
    assert_eq!(tracks[2].position, 3);
    assert_eq!(tracks[2].title, "Track Three");
}

#[test]
fn file_paths_for_album_ordered_by_disc_position() {
    let conn = open(":memory:").unwrap();

    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('mbid-b', 'Artist B', 'Artist B')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel-b', 'mbid-b', 'Album B')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (10, 'rel-b', 1, 2, 'T2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (11, 'rel-b', 1, 1, 'T1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES ('/music/t2.flac', 0, 0, 10, 1000)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES ('/music/t1.flac', 0, 0, 11, 1000)",
        [],
    )
    .unwrap();

    let paths = file_paths_for_album(&conn, "rel-b").unwrap();
    assert_eq!(paths, vec!["/music/t1.flac", "/music/t2.flac"]);
}

#[test]
fn scan_stores_embedded_sort_name() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
        dir.path().join("sample.flac"),
    )
    .unwrap();
    let mut conn = open(":memory:").unwrap();
    let root = dir.path().to_string_lossy().to_string();
    scan_roots(&mut conn, std::slice::from_ref(&root), |_| {}).unwrap();
    let sort: String = conn
        .query_row("SELECT sort_name FROM artist LIMIT 1", [], |r| r.get(0))
        .unwrap();
    assert_eq!(sort, "Shiina, Ringo");
}

#[test]
fn record_play_accumulates_stats() {
    let conn = open(":memory:").unwrap();

    // Seed parent rows required by FK constraints (bundled SQLite has them enabled).
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('a', 'Artist', 'Artist')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r', 'a', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position) VALUES (1, 'r', 1, 1)",
        [],
    )
    .unwrap();

    record_play(&conn, 1, 1000).unwrap();
    record_play(&conn, 1, 2000).unwrap();

    let (play_count, last_played, first_played): (i64, i64, i64) = conn
        .query_row(
            "SELECT play_count, last_played, first_played FROM track_stats WHERE track_id = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();

    assert_eq!(play_count, 2);
    assert_eq!(last_played, 2000);
    assert_eq!(first_played, 1000);
}

#[test]
fn rescan_removes_orphaned_rows() {
    // Exercises the deletion sweep with FK enforcement on: a removed file must
    // cascade-prune its track_stats, track, release, release_group, and artist.
    let dir = tempfile::tempdir().unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
        dir.path().join("sample.flac"),
    )
    .unwrap();
    let mut conn = open(":memory:").unwrap();
    let root = dir.path().to_string_lossy().to_string();
    scan_roots(&mut conn, std::slice::from_ref(&root), |_| {}).unwrap();
    assert_eq!(
        conn.query_row("SELECT count(*) FROM file", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );

    // Remove the file, then re-scan the now-empty dir: the sweep must not hit a
    // FOREIGN KEY constraint and must drop every catalog row to zero.
    std::fs::remove_file(dir.path().join("sample.flac")).unwrap();
    scan_roots(&mut conn, std::slice::from_ref(&root), |_| {}).unwrap();
    for table in [
        "file",
        "track_stats",
        "track",
        "release",
        "release_group",
        "artist",
    ] {
        let n: i64 = conn
            .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0, "{table} not pruned");
    }
}
