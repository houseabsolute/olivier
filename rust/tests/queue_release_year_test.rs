use rust_lib_olivier::catalog::query::tracks_for_paths;
use rust_lib_olivier::db::open;

fn seed(conn: &rusqlite::Connection) {
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('m-a','Artist','Artist')",
        [],
    )
    .unwrap();
    // Release WITH a release_group (original year) and its own reissue date.
    conn.execute(
        "INSERT INTO release_group(mbid,title,first_release_date) \
         VALUES ('rg','Album','1973-03-01')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title,date) \
         VALUES ('r','rg','m-a','Album','2011-09-26')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,title,length_ms) VALUES (1,'r','Song',1000)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at) VALUES ('/p.flac',0,0,1,0)",
        [],
    )
    .unwrap();

    // Release with NO release_group and NO date.
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('r2','m-a','NoYear')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,title) VALUES (2,'r2','Song2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at) VALUES ('/p2.flac',0,0,2,0)",
        [],
    )
    .unwrap();
}

#[test]
fn tracks_for_paths_carries_original_and_reissue_year() {
    let conn = open(":memory:").unwrap();
    seed(&conn);

    let got = tracks_for_paths(&conn, &["/p.flac".to_string()]).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].original_year.as_deref(), Some("1973"));
    assert_eq!(got[0].reissue_year.as_deref(), Some("2011"));
}

#[test]
fn tracks_for_paths_year_is_none_without_release_group_or_date() {
    let conn = open(":memory:").unwrap();
    seed(&conn);

    let got = tracks_for_paths(&conn, &["/p2.flac".to_string()]).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].original_year, None);
    assert_eq!(got[0].reissue_year, None);
}
