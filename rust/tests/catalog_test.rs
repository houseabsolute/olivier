use rust_lib_olivier::catalog::ids::{album_artist_key, sort_name};
use rust_lib_olivier::catalog::query::{
    albums_for_artist, artists_page, file_paths_for_album, record_play, track_path,
    tracks_for_album, tracks_for_paths,
};
use rust_lib_olivier::catalog::roots::{add_root, list_roots, remove_root};
use rust_lib_olivier::catalog::scan::{reconcile_album_artists, scan_roots};
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
fn artists_page_sorts_case_insensitively() {
    let conn = open(":memory:").unwrap();
    // Lowercase 'abba' must sort before 'Beatles'. BINARY collation would put
    // uppercase 'B' (66) ahead of lowercase 'a' (97) and get this backwards.
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m-b', 'Beatles', 'Beatles')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m-a', 'abba', 'abba')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r-b', 'm-b', 'X')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r-a', 'm-a', 'Y')",
        [],
    )
    .unwrap();

    let page = artists_page(&conn, None, 50).unwrap();
    assert_eq!(page.len(), 2);
    assert_eq!(page[0].sort_name, "abba");
    assert_eq!(page[1].sort_name, "Beatles");

    // Keyset must stay consistent with the case-insensitive order.
    let page2 = artists_page(&conn, Some("abba"), 50).unwrap();
    assert_eq!(page2.len(), 1);
    assert_eq!(page2[0].sort_name, "Beatles");
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
fn artists_page_returns_transliteration() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name, transliteration)
         VALUES ('m-ringo', '椎名林檎', 'Sheena, Ringo', 'Ringo Sheena')",
        [],
    )
    .unwrap();
    // A Latin-only artist with no transliteration.
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m-beatles', 'The Beatles', 'Beatles, The')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r1', 'm-ringo', 'X')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r2', 'm-beatles', 'Y')",
        [],
    )
    .unwrap();

    let page = artists_page(&conn, None, 50).unwrap();
    assert_eq!(page.len(), 2);
    // Ordered by sort_name: "Beatles, The" then "Sheena, Ringo".
    assert_eq!(page[0].name, "The Beatles");
    assert_eq!(page[0].transliteration, None);
    assert_eq!(page[1].name, "椎名林檎");
    assert_eq!(page[1].transliteration, Some("Ringo Sheena".to_string()));
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
fn albums_for_artist_title_tiebreak_is_case_insensitive() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'Artist', 'Artist')",
        [],
    )
    .unwrap();
    // Same year, so the title decides the order: lowercase 'apple' must precede
    // 'Banana' (BINARY collation would order 'Banana' first).
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('r1', 'm', 'Banana', '2000')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('r2', 'm', 'apple', '2000')",
        [],
    )
    .unwrap();

    let albums = albums_for_artist(&conn, "m").unwrap();
    assert_eq!(albums.len(), 2);
    assert_eq!(albums[0].title, "apple");
    assert_eq!(albums[1].title, "Banana");
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
fn file_paths_for_album_is_one_per_track() {
    // A track with several files (e.g. the same album ripped to two formats)
    // must yield ONE path, so the play queue stays 1:1 with tracks_for_album —
    // the playback controller zips the two lists by index.
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1, 'rel', 1, 1, 'T1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2, 'rel', 1, 2, 'T2')",
        [],
    )
    .unwrap();
    // T1 has two files (flac + m4a copies), T2 has one.
    for (path, tid) in [("/m/a1.flac", 1), ("/m/a1.m4a", 1), ("/m/a2.flac", 2)] {
        conn.execute(
            "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES (?1, 0, 0, ?2, 0)",
            rusqlite::params![path, tid],
        )
        .unwrap();
    }

    let paths = file_paths_for_album(&conn, "rel").unwrap();
    let tracks = tracks_for_album(&conn, "rel").unwrap();
    assert_eq!(paths.len(), tracks.len(), "queue must be 1:1 with tracks");
    // MIN(path) picks the lexically-first file per track.
    assert_eq!(paths, vec!["/m/a1.flac", "/m/a2.flac"]);
}

#[test]
fn tracks_for_paths_preserves_order_with_placeholder() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title, artist, length_ms)
         VALUES (1, 'rel', 1, 1, 'Song', 'Art', 1000)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES ('/m/a.flac', 0, 0, 1, 0)",
        [],
    )
    .unwrap();

    // Query in a specific order, with a path that isn't in the catalog first.
    let paths = vec!["/m/missing.mp3".to_string(), "/m/a.flac".to_string()];
    let got = tracks_for_paths(&conn, &paths).unwrap();
    assert_eq!(got.len(), 2, "one entry per input path, in order");

    // Placeholder for the catalog-missing path: filename as title, no track id.
    assert_eq!(got[0].path, "/m/missing.mp3");
    assert_eq!(got[0].track_id, None);
    assert_eq!(got[0].title, "missing.mp3");

    // Real metadata for the catalogued path.
    assert_eq!(got[1].path, "/m/a.flac");
    assert_eq!(got[1].track_id, Some(1));
    assert_eq!(got[1].title, "Song");
    assert_eq!(got[1].artist.as_deref(), Some("Art"));
    assert_eq!(got[1].album, "Album");
    assert_eq!(got[1].length_ms, Some(1000));

    // Empty input → empty output.
    assert!(tracks_for_paths(&conn, &[]).unwrap().is_empty());
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

#[test]
fn scoped_scan_preserves_other_roots() {
    // Regression: scanning one root must not delete files that live under a
    // different root. The deletion sweep used to be global, so scanning a second
    // folder wiped the first.
    let dir_a = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
        dir_a.path().join("sample.flac"),
    )
    .unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.mp3", env!("CARGO_MANIFEST_DIR")),
        dir_b.path().join("sample.mp3"),
    )
    .unwrap();
    let mut conn = open(":memory:").unwrap();
    let root_a = dir_a.path().to_string_lossy().to_string();
    let root_b = dir_b.path().to_string_lossy().to_string();

    // Scan A by itself.
    scan_roots(&mut conn, std::slice::from_ref(&root_a), |_| {}).unwrap();
    assert_eq!(
        conn.query_row("SELECT count(*) FROM file", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );

    // Scan B by itself — A's file must survive (old global sweep would delete it).
    scan_roots(&mut conn, std::slice::from_ref(&root_b), |_| {}).unwrap();
    assert_eq!(
        conn.query_row("SELECT count(*) FROM file", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        2,
        "scanning B wiped A"
    );
    let a_present: i64 = conn
        .query_row(
            "SELECT count(*) FROM file WHERE path = ?1",
            [format!("{root_a}/sample.flac")],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(a_present, 1, "A's file was deleted by scanning B");
}

#[test]
fn roots_add_list_remove() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/music/a").unwrap();
    add_root(&conn, "/music/b/").unwrap(); // trailing slash trimmed
    add_root(&conn, "/music/a").unwrap(); // idempotent — no duplicate
    assert_eq!(
        list_roots(&conn).unwrap(),
        vec!["/music/a".to_string(), "/music/b".to_string()]
    );
    remove_root(&conn, "/music/a").unwrap();
    assert_eq!(list_roots(&conn).unwrap(), vec!["/music/b".to_string()]);
}

#[test]
fn remove_root_prunes_files_beneath_it() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
        dir.path().join("sample.flac"),
    )
    .unwrap();
    let mut conn = open(":memory:").unwrap();
    let root = dir.path().to_string_lossy().to_string();
    add_root(&conn, &root).unwrap();
    scan_roots(&mut conn, std::slice::from_ref(&root), |_| {}).unwrap();
    assert_eq!(
        conn.query_row("SELECT count(*) FROM file", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );

    // Forgetting the root drops its files and every catalog row they anchored.
    remove_root(&conn, &root).unwrap();
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
        assert_eq!(n, 0, "{table} not pruned by remove_root");
    }
}

fn count(conn: &rusqlite::Connection, table: &str) -> i64 {
    conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}

#[test]
fn scoped_scan_preserves_shared_parent_rows() {
    // Two roots whose files resolve to the SAME artist/release (identical MBID
    // tags). Scanning one must not let the global orphan cascade drop the shared
    // artist/release that the other root's file still references.
    let dir_a = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();
    for d in [&dir_a, &dir_b] {
        std::fs::copy(
            format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
            d.path().join("sample.flac"),
        )
        .unwrap();
    }
    let mut conn = open(":memory:").unwrap();
    let root_a = dir_a.path().to_string_lossy().to_string();
    let root_b = dir_b.path().to_string_lossy().to_string();

    scan_roots(&mut conn, std::slice::from_ref(&root_a), |_| {}).unwrap();
    scan_roots(&mut conn, std::slice::from_ref(&root_b), |_| {}).unwrap();

    // Both files survive, and the shared catalog rows stay intact (1, not 0).
    assert_eq!(count(&conn, "file"), 2);
    assert_eq!(count(&conn, "artist"), 1);
    assert_eq!(count(&conn, "release"), 1);
    assert_eq!(count(&conn, "track"), 1);
}

#[test]
fn scoped_sweep_handles_multibyte_root_paths() {
    // The sweep computes a char-counted prefix; exercise it with a non-ASCII
    // (Japanese) directory component so a regression in the substr() code-point
    // math would surface as a missed prune.
    let base = tempfile::tempdir().unwrap();
    let music = base.path().join("音楽");
    std::fs::create_dir(&music).unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
        music.join("sample.flac"),
    )
    .unwrap();
    let mut conn = open(":memory:").unwrap();
    let root = music.to_string_lossy().to_string();
    scan_roots(&mut conn, std::slice::from_ref(&root), |_| {}).unwrap();
    assert_eq!(count(&conn, "file"), 1);

    // Remove the file and rescan: the multibyte-prefixed sweep must prune it.
    std::fs::remove_file(music.join("sample.flac")).unwrap();
    scan_roots(&mut conn, std::slice::from_ref(&root), |_| {}).unwrap();
    assert_eq!(count(&conn, "file"), 0);
}

#[test]
fn remove_root_keeps_files_under_nested_root() {
    // Roots A=<base> and B=<base>/inner are both registered. Removing A must not
    // delete B's files even though they sit under A's prefix.
    let base = tempfile::tempdir().unwrap();
    let inner = base.path().join("inner");
    std::fs::create_dir(&inner).unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
        base.path().join("outer.flac"),
    )
    .unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
        inner.join("nested.flac"),
    )
    .unwrap();
    let mut conn = open(":memory:").unwrap();
    let root_a = base.path().to_string_lossy().to_string();
    let root_b = inner.to_string_lossy().to_string();
    add_root(&conn, &root_a).unwrap();
    add_root(&conn, &root_b).unwrap();
    // Scanning A covers both files, since B is nested under A.
    scan_roots(&mut conn, std::slice::from_ref(&root_a), |_| {}).unwrap();
    assert_eq!(count(&conn, "file"), 2);

    remove_root(&conn, &root_a).unwrap();
    let nested_present: i64 = conn
        .query_row(
            "SELECT count(*) FROM file WHERE path = ?1",
            [format!("{root_b}/nested.flac")],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        nested_present, 1,
        "nested root B's file was wrongly deleted"
    );
    let outer_present: i64 = conn
        .query_row(
            "SELECT count(*) FROM file WHERE path = ?1",
            [format!("{root_a}/outer.flac")],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(outer_present, 0, "A's own file should be gone");
}

#[test]
fn remove_root_keeps_files_still_covered_by_another_root() {
    // The reverse of the test above: removing the NESTED root B while the parent
    // root A is still registered must NOT delete the file, because A still covers
    // it. Removal only evicts music no longer under any registered root.
    let base = tempfile::tempdir().unwrap();
    let inner = base.path().join("inner");
    std::fs::create_dir(&inner).unwrap();
    std::fs::copy(
        format!("{}/tests/fixtures/sample.flac", env!("CARGO_MANIFEST_DIR")),
        inner.join("nested.flac"),
    )
    .unwrap();
    let mut conn = open(":memory:").unwrap();
    let root_a = base.path().to_string_lossy().to_string();
    let root_b = inner.to_string_lossy().to_string();
    add_root(&conn, &root_a).unwrap();
    add_root(&conn, &root_b).unwrap();
    scan_roots(&mut conn, std::slice::from_ref(&root_a), |_| {}).unwrap();
    assert_eq!(count(&conn, "file"), 1);

    remove_root(&conn, &root_b).unwrap();
    assert_eq!(
        count(&conn, "file"),
        1,
        "file still covered by parent root A must survive removing nested root B"
    );
}

#[test]
fn reconcile_merges_synth_album_artist_into_real() {
    let conn = open(":memory:").unwrap();
    // Same artist two ways: one album tagged with the real MBID (sort-cased
    // "Anohni"), one album missing the album-artist MBID so it got a synth key
    // (upper-cased "ANOHNI"). The names match case-insensitively.
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('real-anohni', 'Anohni', 'Anohni')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('synth:aa:anohni', 'ANOHNI', 'ANOHNI')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel-real', 'real-anohni', 'HOPELESSNESS')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('synth:rel:x', 'synth:aa:anohni', 'paradise')",
        [],
    )
    .unwrap();

    reconcile_album_artists(&conn).unwrap();

    // artists_page filters to artists referenced by a release, so re-pointing the
    // release is enough for the synth row to vanish from the browse list here
    // (the dead row is later removed by prune_orphans during a real scan).
    let page = artists_page(&conn, None, 50).unwrap();
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].mbid, "real-anohni");
    // ...and both albums now belong to the real artist.
    let albums = albums_for_artist(&conn, "real-anohni").unwrap();
    assert_eq!(albums.len(), 2);
}

#[test]
fn albums_for_artist_returns_title_alts() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'Shiina', 'Shiina')",
        [],
    )
    .unwrap();
    // Album with both a romaji translit and an English translate.
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('rel-jp', 'm', '無罪モラトリアム', '1999')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release_title_alt(release_mbid, kind, title) VALUES ('rel-jp', 'translit', 'Muzai Moratorium')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release_title_alt(release_mbid, kind, title) VALUES ('rel-jp', 'translate', 'Innocence Moratorium')",
        [],
    )
    .unwrap();
    // A Latin-only album, no alts, later year so it sorts second.
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('rel-en', 'm', 'Sport', '2014')",
        [],
    )
    .unwrap();

    let albums = albums_for_artist(&conn, "m").unwrap();
    assert_eq!(albums.len(), 2);
    // 1999 album first (ordering unchanged), with both alts.
    assert_eq!(albums[0].title, "無罪モラトリアム");
    assert_eq!(
        albums[0].title_translit,
        Some("Muzai Moratorium".to_string())
    );
    assert_eq!(
        albums[0].title_translate,
        Some("Innocence Moratorium".to_string())
    );
    // Latin-only album: both alts null.
    assert_eq!(albums[1].title, "Sport");
    assert_eq!(albums[1].title_translit, None);
    assert_eq!(albums[1].title_translate, None);
}

#[test]
fn tracks_for_album_returns_title_alts_one_row_per_track() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
        [],
    )
    .unwrap();
    // Track 1: Japanese with both alts (two track_title_alt rows).
    conn.execute(
        "INSERT INTO track(id, release_mbid, recording_mbid, disc, position, title)
         VALUES (1, 'rel', 'rec-1', 1, 1, '正しい街')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track_title_alt(recording_mbid, kind, title) VALUES ('rec-1', 'translit', 'Tadashii Machi')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track_title_alt(recording_mbid, kind, title) VALUES ('rec-1', 'translate', 'The Right Town')",
        [],
    )
    .unwrap();
    // Track 2: Latin-only, no recording_mbid, no alts.
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2, 'rel', 1, 2, 'Sport')",
        [],
    )
    .unwrap();

    let tracks = tracks_for_album(&conn, "rel").unwrap();
    assert_eq!(tracks.len(), 2, "two alt rows must not duplicate the track");
    assert_eq!(tracks[0].position, 1);
    assert_eq!(tracks[0].title, "正しい街");
    assert_eq!(tracks[0].title_translit, Some("Tadashii Machi".to_string()));
    assert_eq!(
        tracks[0].title_translate,
        Some("The Right Town".to_string())
    );
    assert_eq!(tracks[1].position, 2);
    assert_eq!(tracks[1].title_translit, None);
    assert_eq!(tracks[1].title_translate, None);
}

#[test]
fn tracks_for_paths_returns_title_alts() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, recording_mbid, disc, position, title)
         VALUES (1, 'rel', 'rec-1', 1, 1, '正しい街')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track_title_alt(recording_mbid, kind, title) VALUES ('rec-1', 'translit', 'Tadashii Machi')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES ('/m/a.flac', 0, 0, 1, 0)",
        [],
    )
    .unwrap();

    let paths = vec!["/m/a.flac".to_string(), "/m/missing.mp3".to_string()];
    let got = tracks_for_paths(&conn, &paths).unwrap();
    assert_eq!(got[0].title_translit, Some("Tadashii Machi".to_string()));
    assert_eq!(got[0].title_translate, None);
    // Placeholder has no alts.
    assert_eq!(got[1].title_translit, None);
    assert_eq!(got[1].title_translate, None);
}

#[test]
fn reconcile_leaves_synth_only_artist_untouched() {
    let conn = open(":memory:").unwrap();
    // An album-artist with NO real-MBID counterpart must keep its synth key
    // (the EXISTS guard must not null out its album_artist_mbid).
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('synth:aa:nobody', 'Nobody', 'Nobody')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('synth:rel:n', 'synth:aa:nobody', 'Demo')",
        [],
    )
    .unwrap();

    reconcile_album_artists(&conn).unwrap();

    let aa: Option<String> = conn
        .query_row(
            "SELECT album_artist_mbid FROM release WHERE mbid = 'synth:rel:n'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(aa.as_deref(), Some("synth:aa:nobody"));
}

#[test]
fn track_path_returns_min_path_or_none() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1, 'rel', 1, 1, 'T1')",
        [],
    )
    .unwrap();
    // Track 1 has two files (e.g. the same rip in two formats); track_path must
    // return exactly ONE path — the lexically-first (MIN) — so a double-click
    // enqueues a single entry, consistent with file_paths_for_album.
    for path in ["/m/a1.m4a", "/m/a1.flac"] {
        conn.execute(
            "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES (?1, 0, 0, 1, 0)",
            rusqlite::params![path],
        )
        .unwrap();
    }
    // A track with no files at all.
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2, 'rel', 1, 2, 'T2')",
        [],
    )
    .unwrap();

    assert_eq!(
        track_path(&conn, 1).unwrap(),
        Some("/m/a1.flac".to_string())
    );
    // No files → None (caller appends nothing).
    assert_eq!(track_path(&conn, 2).unwrap(), None);
    // Unknown track id → None.
    assert_eq!(track_path(&conn, 999).unwrap(), None);
}
