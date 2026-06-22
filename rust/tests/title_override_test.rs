use rust_lib_olivier::catalog::query::{
    albums_for_artist, release_title_override, set_release_title_override,
    set_track_title_override, track_title_override, tracks_for_album, tracks_for_paths,
};
use rust_lib_olivier::db::open;

fn seed(conn: &rusqlite::Connection) {
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('A','Artist','Artist')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R','A','Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,recording_mbid,disc,position,title) VALUES (1,'R','REC',1,1,'曲')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track_title_alt(recording_mbid,kind,title) VALUES ('REC','translit','Kyoku')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release_title_alt(release_mbid,kind,title) VALUES ('R','translit','Arubamu')",
        [],
    )
    .unwrap();
}

#[test]
fn track_override_round_trips_and_clears() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    let t = track_title_override(&conn, "REC").unwrap();
    assert_eq!(t.translit.as_deref(), Some("Kyoku"));
    assert_eq!(t.translit_override, None);

    set_track_title_override(&conn, "REC", Some("Kyoku!".into()), Some("".into())).unwrap();
    let t = track_title_override(&conn, "REC").unwrap();
    assert_eq!(t.translit_override.as_deref(), Some("Kyoku!"));
    assert_eq!(t.translate_override.as_deref(), Some(""));

    set_track_title_override(&conn, "REC", None, None).unwrap();
    let t = track_title_override(&conn, "REC").unwrap();
    assert_eq!(t.translit_override, None);
    assert_eq!(t.translate_override, None);
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM track_title_override WHERE recording_mbid='REC'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 0);
}

#[test]
fn release_override_round_trips() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    set_release_title_override(&conn, "R", None, Some("Album (EN)".into())).unwrap();
    let r = release_title_override(&conn, "R").unwrap();
    assert_eq!(r.translit.as_deref(), Some("Arubamu"));
    assert_eq!(r.translit_override, None);
    assert_eq!(r.translate_override.as_deref(), Some("Album (EN)"));
}

#[test]
fn override_beats_enriched_in_displays() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    // A file row so tracks_for_paths returns the track.
    conn.execute(
        "INSERT INTO file(id,path,mtime,size,track_id,enriched,added_at) VALUES (1,'/m/x.flac',0,0,1,1,0)",
        [],
    )
    .unwrap();
    set_track_title_override(&conn, "REC", Some("MyReading".into()), Some("".into())).unwrap();
    set_release_title_override(&conn, "R", Some("MyAlbumReading".into()), None).unwrap();

    let tracks = tracks_for_album(&conn, "R").unwrap();
    assert_eq!(tracks[0].title_translit.as_deref(), Some("MyReading")); // override beats "Kyoku"
    assert_eq!(tracks[0].title_translate, None); // '' suppress -> None

    let albums = albums_for_artist(&conn, "A").unwrap();
    assert_eq!(albums[0].title_translit.as_deref(), Some("MyAlbumReading"));

    let q = tracks_for_paths(&conn, &["/m/x.flac".to_string()]).unwrap();
    assert_eq!(q[0].title_translit.as_deref(), Some("MyReading"));
}

/// Gate ↔ override cross-feature: when the gate left a track with NO enriched
/// `track_title_alt` row at all (e.g. an English-original track in a mixed
/// album), a user-supplied reading override still surfaces — the COALESCE in
/// `tracks_for_album`/`tracks_for_paths` falls through to the override even
/// though no alt row backs it. Uses a SECOND recording (`REC2`) that the seed
/// never gives a translit alt.
#[test]
fn override_surfaces_with_no_enriched_alt() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    // A second track/recording on the same release with NO track_title_alt row.
    conn.execute(
        "INSERT INTO track(id,release_mbid,recording_mbid,disc,position,title) VALUES (2,'R','REC2',1,2,'Lukewarm')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(id,path,mtime,size,track_id,enriched,added_at) VALUES (2,'/m/y.flac',0,0,2,1,0)",
        [],
    )
    .unwrap();
    // Sanity: REC2 really has no enriched alt to fall back on.
    let alt_rows: i64 = conn
        .query_row(
            "SELECT count(*) FROM track_title_alt WHERE recording_mbid='REC2'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(alt_rows, 0);

    set_track_title_override(&conn, "REC2", Some("Manual".into()), None).unwrap();

    // tracks_for_album: the override fell through despite no alt row.
    let tracks = tracks_for_album(&conn, "R").unwrap();
    let row = tracks
        .iter()
        .find(|t| t.recording_mbid.as_deref() == Some("REC2"))
        .expect("REC2 track present");
    assert_eq!(row.title_translit.as_deref(), Some("Manual"));

    // tracks_for_paths: same fall-through via the file path.
    let q = tracks_for_paths(&conn, &["/m/y.flac".to_string()]).unwrap();
    assert_eq!(q[0].title_translit.as_deref(), Some("Manual"));
}
