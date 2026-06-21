use rusqlite::params;
use rust_lib_olivier::catalog::deletes::{remove_album, remove_track};
use rust_lib_olivier::db::open;

/// One artist (A1) with two albums: R1 has tracks T1,T2 (files F1,F2); R2 has
/// track T3 (file F3). Seeded with direct SQL (no fixtures) so the delete logic
/// is tested in isolation. `open(":memory:")` runs the migrations that create
/// the tables.
fn seed() -> rusqlite::Connection {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('A1','Artist One','Artist One')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('R1','A1','Album One')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('R2','A1','Album Two')",
        [],
    )
    .unwrap();
    // UNIQUE(release_mbid, disc, position): give each track in a release a distinct position.
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1,'R1',1,1,'T1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (2,'R1',1,2,'T2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (3,'R2',1,1,'T3')",
        [],
    )
    .unwrap();
    for (id, path, tid) in [
        (1, "/m/a1.flac", 1),
        (2, "/m/a2.flac", 2),
        (3, "/m/b1.flac", 3),
    ] {
        conn.execute(
            "INSERT INTO file(id, path, mtime, size, track_id, added_at) VALUES (?1,?2,0,0,?3,0)",
            params![id, path, tid],
        )
        .unwrap();
    }
    conn
}

fn count(conn: &rusqlite::Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |r| r.get(0)).unwrap()
}

#[test]
fn remove_track_drops_the_track_and_its_file_but_keeps_siblings() {
    let conn = seed();
    remove_track(&conn, 2).unwrap(); // forget T2 from album R1

    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE id = 2"), 0);
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM file WHERE track_id = 2"),
        0
    );
    // Sibling T1, both releases, and the artist remain.
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE id = 1"), 1);
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R1'"),
        1
    );
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R2'"),
        1
    );
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"),
        1
    );
}

#[test]
fn remove_track_that_is_the_albums_last_track_prunes_the_album() {
    let conn = seed();
    remove_track(&conn, 3).unwrap(); // T3 is R2's only track

    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE id = 3"), 0);
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R2'"),
        0
    );
    // A1 still has R1, so artist + R1 stay.
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"),
        1
    );
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R1'"),
        1
    );
}

#[test]
fn remove_album_drops_the_release_and_its_tracks_keeps_other_album() {
    let conn = seed();
    remove_album(&conn, "R1").unwrap();

    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R1'"),
        0
    );
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM track WHERE release_mbid = 'R1'"
        ),
        0
    );
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM file WHERE track_id IN (1,2)"),
        0
    );
    // R2 + its track + the shared artist remain.
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R2'"),
        1
    );
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track WHERE id = 3"), 1);
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"),
        1
    );
}

#[test]
fn remove_albums_last_one_also_prunes_the_artist() {
    let conn = seed();
    remove_album(&conn, "R1").unwrap();
    remove_album(&conn, "R2").unwrap(); // artist now has no releases

    assert_eq!(count(&conn, "SELECT COUNT(*) FROM release"), 0);
    assert_eq!(count(&conn, "SELECT COUNT(*) FROM track"), 0);
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"),
        0
    );
}

#[test]
fn remove_album_cleans_up_alt_title_rows_for_an_enriched_album() {
    let conn = seed();
    // Enrich R1 like a real CJK album: a transliterated release title, and a
    // track_title_alt for T1's recording. release_title_alt has an enforced FK to
    // release(mbid), so before the prune_orphans fix remove_album failed here with
    // a FOREIGN KEY constraint error and removed nothing.
    conn.execute(
        "INSERT INTO release_title_alt(release_mbid, kind, title) \
         VALUES ('R1','translit','Arubamu Wan')",
        [],
    )
    .unwrap();
    conn.execute("UPDATE track SET recording_mbid = 'REC1' WHERE id = 1", [])
        .unwrap();
    conn.execute(
        "INSERT INTO track_title_alt(recording_mbid, kind, title) \
         VALUES ('REC1','translit','Tee Wan')",
        [],
    )
    .unwrap();

    remove_album(&conn, "R1").unwrap();

    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R1'"),
        0
    );
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM release_title_alt WHERE release_mbid = 'R1'"
        ),
        0,
        "orphaned release_title_alt must be pruned"
    );
    assert_eq!(
        count(
            &conn,
            "SELECT COUNT(*) FROM track_title_alt WHERE recording_mbid = 'REC1'"
        ),
        0,
        "orphaned track_title_alt must be pruned"
    );
    // The sibling album and the shared artist are untouched.
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM release WHERE mbid = 'R2'"),
        1
    );
    assert_eq!(
        count(&conn, "SELECT COUNT(*) FROM artist WHERE mbid = 'A1'"),
        1
    );
}
