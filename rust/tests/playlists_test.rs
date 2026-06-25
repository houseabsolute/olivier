use rusqlite::params;
use rust_lib_olivier::catalog::playlists::*;
use rust_lib_olivier::db::open;

/// One artist/release with three tracks + files (so playlist_item's FK to
/// file(path) is satisfiable). open(":memory:") runs the migrations.
fn seed() -> rusqlite::Connection {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('A1','A','A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R1','A1','Alb')",
        [],
    )
    .unwrap();
    for (id, pos) in [(1, 1), (2, 2), (3, 3)] {
        conn.execute(
            "INSERT INTO track(id,release_mbid,disc,position,title) VALUES (?1,'R1',1,?2,'T')",
            params![id, pos],
        )
        .unwrap();
    }
    for (id, path, tid) in [(1, "/m/a.flac", 1), (2, "/m/b.flac", 2), (3, "/m/c.flac", 3)] {
        conn.execute(
            "INSERT INTO file(id,path,mtime,size,track_id,added_at) VALUES (?1,?2,0,0,?3,0)",
            params![id, path, tid],
        )
        .unwrap();
    }
    conn
}

fn s(x: &str) -> String {
    x.to_string()
}

#[test]
fn create_list_and_count() {
    let conn = seed();
    let p1 = create_playlist(&conn, "First").unwrap();
    let _p2 = create_playlist(&conn, "Second").unwrap();
    add_to_playlist(&conn, p1, &[s("/m/a.flac"), s("/m/b.flac")]).unwrap();

    let lists = list_playlists(&conn).unwrap();
    assert_eq!(lists.len(), 2);
    assert_eq!(lists[0].name, "First"); // ordered by position (creation order)
    assert_eq!(lists[0].count, 2);
    assert_eq!(lists[1].name, "Second");
    assert_eq!(lists[1].count, 0);
}

#[test]
fn add_preserves_order_and_duplicates() {
    let conn = seed();
    let p = create_playlist(&conn, "P").unwrap();
    add_to_playlist(&conn, p, &[s("/m/c.flac"), s("/m/a.flac"), s("/m/a.flac")]).unwrap();

    let paths: Vec<String> = playlist_tracks(&conn, p).unwrap().into_iter().map(|t| t.path).collect();
    assert_eq!(paths, vec![s("/m/c.flac"), s("/m/a.flac"), s("/m/a.flac")]);
}

#[test]
fn set_items_rewrites_order_and_removes() {
    let conn = seed();
    let p = create_playlist(&conn, "P").unwrap();
    add_to_playlist(&conn, p, &[s("/m/a.flac"), s("/m/b.flac"), s("/m/c.flac")]).unwrap();
    set_playlist_items(&conn, p, &[s("/m/c.flac"), s("/m/a.flac")]).unwrap();

    let paths: Vec<String> = playlist_tracks(&conn, p).unwrap().into_iter().map(|t| t.path).collect();
    assert_eq!(paths, vec![s("/m/c.flac"), s("/m/a.flac")]);
}

#[test]
fn rename_and_delete_cascade() {
    let conn = seed();
    let p = create_playlist(&conn, "Old").unwrap();
    add_to_playlist(&conn, p, &[s("/m/a.flac")]).unwrap();
    rename_playlist(&conn, p, "New").unwrap();
    assert_eq!(list_playlists(&conn).unwrap()[0].name, "New");

    delete_playlist(&conn, p).unwrap();
    assert!(list_playlists(&conn).unwrap().is_empty());
    let items: i64 = conn
        .query_row("SELECT COUNT(*) FROM playlist_item", [], |r| r.get(0))
        .unwrap();
    assert_eq!(items, 0, "deleting a playlist cascades its items");
}

#[test]
fn reorder_playlists_changes_listing_order() {
    let conn = seed();
    let a = create_playlist(&conn, "A").unwrap();
    let b = create_playlist(&conn, "B").unwrap();
    let c = create_playlist(&conn, "C").unwrap();
    reorder_playlists(&conn, &[c, a, b]).unwrap();

    let names: Vec<String> = list_playlists(&conn).unwrap().into_iter().map(|p| p.name).collect();
    assert_eq!(names, vec![s("C"), s("A"), s("B")]);
}
