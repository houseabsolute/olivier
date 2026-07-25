use rusqlite::Connection;
use rust_lib_olivier::catalog::roots::add_root;
use rust_lib_olivier::db::open;
use rust_lib_olivier::sync::export_snapshot;

fn seed(conn: &Connection, id: i64, path: &str) {
    conn.execute(
        "INSERT OR IGNORE INTO artist(mbid,name,sort_name) VALUES ('A','Artist','Artist')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT OR IGNORE INTO release(mbid,album_artist_mbid,title) VALUES ('R','A','Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,recording_mbid,disc,position,title)
         VALUES (?1,'R',?2,1,?1,'Track')",
        rusqlite::params![id, format!("REC{id}")],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at) VALUES (?1,0,0,?2,0)",
        rusqlite::params![path, id],
    )
    .unwrap();
}

fn paths(conn: &Connection, table: &str) -> Vec<String> {
    let mut stmt = conn
        .prepare(&format!("SELECT path FROM {table} ORDER BY path"))
        .unwrap();
    stmt.query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

/// A source catalog on disk with one root and two files, plus a queue and a
/// saved playback position — the device-local state the export must drop.
fn source_db(dir: &std::path::Path) -> String {
    let db = dir.join("olivier.db").to_string_lossy().into_owned();
    let conn = open(&db).unwrap();
    add_root(&conn, "/home/me/Music").unwrap();
    seed(&conn, 1, "/home/me/Music/a/one.flac");
    seed(&conn, 2, "/home/me/Music/b/two.flac");
    conn.execute(
        "INSERT INTO queue_item(position,path) VALUES (1,'/home/me/Music/a/one.flac')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO playback_state(id,current_index,position_ms,shuffle) VALUES (0,1,4200,0)",
        [],
    )
    .unwrap();
    db
}

#[test]
fn writes_a_rebased_snapshot_without_touching_the_source() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());

    let out = export_snapshot(
        &src,
        dest.path().to_str().unwrap(),
        None,
        &[(
            "/home/me/Music".to_string(),
            "/storage/emulated/0/Music".to_string(),
        )],
    )
    .unwrap();

    assert_eq!(out.files, 2);
    let snapshot = dest.path().join("olivier-sync.db");
    assert!(snapshot.exists(), "snapshot must be written");
    assert_eq!(out.db_path, snapshot.to_string_lossy());

    let copy = Connection::open(&snapshot).unwrap();
    assert_eq!(
        paths(&copy, "file"),
        vec![
            "/storage/emulated/0/Music/a/one.flac",
            "/storage/emulated/0/Music/b/two.flac"
        ]
    );

    // The source catalog is untouched.
    let orig = Connection::open(&src).unwrap();
    assert_eq!(
        paths(&orig, "file"),
        vec!["/home/me/Music/a/one.flac", "/home/me/Music/b/two.flac"]
    );
    assert_eq!(
        paths(&orig, "queue_item"),
        vec!["/home/me/Music/a/one.flac"]
    );
}

#[test]
fn drops_device_local_playback_state() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());

    export_snapshot(
        &src,
        dest.path().to_str().unwrap(),
        None,
        &[("/home/me/Music".to_string(), "/phone/Music".to_string())],
    )
    .unwrap();

    let copy = Connection::open(dest.path().join("olivier-sync.db")).unwrap();
    assert!(
        paths(&copy, "queue_item").is_empty(),
        "the phone starts with its own queue"
    );
    let rows: i64 = copy
        .query_row("SELECT count(*) FROM playback_state", [], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 0, "a desktop playhead is meaningless on the phone");
}

#[test]
fn writes_metadata_alongside_the_snapshot() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());

    export_snapshot(
        &src,
        dest.path().to_str().unwrap(),
        None,
        &[("/home/me/Music".to_string(), "/phone/Music".to_string())],
    )
    .unwrap();

    let meta = std::fs::read_to_string(dest.path().join("olivier-sync.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&meta).unwrap();
    assert_eq!(v["files"], 2);
    assert!(
        v["schema_version"].as_i64().unwrap() > 0,
        "the importer checks this before swapping the DB in"
    );
    assert!(v["exported_at"].as_str().unwrap().contains('T'));
}

#[test]
fn copies_only_the_portable_mbid_keyed_covers() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let cache = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());

    std::fs::write(cache.path().join("olivier-caa-R.jpg"), b"jpeg").unwrap();
    std::fs::write(cache.path().join("olivier-caa-R2.png"), b"png").unwrap();
    std::fs::write(cache.path().join("olivier-caa-R3.miss"), b"").unwrap();
    // Keyed by a hash of the absolute file path, so it means nothing once the
    // paths are rebased — must not be copied.
    std::fs::write(cache.path().join("olivier-cover-deadbeef.jpg"), b"jpeg").unwrap();
    std::fs::write(cache.path().join("unrelated.txt"), b"x").unwrap();

    let out = export_snapshot(
        &src,
        dest.path().to_str().unwrap(),
        Some(cache.path().to_str().unwrap()),
        &[("/home/me/Music".to_string(), "/phone/Music".to_string())],
    )
    .unwrap();

    assert_eq!(
        out.covers_copied, 2,
        "the two images, not the .miss sentinel"
    );
    let covers = dest.path().join("covers");
    assert!(covers.join("olivier-caa-R.jpg").exists());
    assert!(covers.join("olivier-caa-R2.png").exists());
    assert!(!covers.join("olivier-caa-R3.miss").exists());
    assert!(!covers.join("olivier-cover-deadbeef.jpg").exists());
    assert!(!covers.join("unrelated.txt").exists());
}

#[test]
fn rejects_a_source_catalog_that_does_not_exist() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let missing = tmp.path().join("nope.db");

    let err = export_snapshot(
        missing.to_str().unwrap(),
        dest.path().to_str().unwrap(),
        None,
        &[("/home/me/Music".to_string(), "/phone/Music".to_string())],
    )
    .unwrap_err();

    assert!(
        err.to_string().contains("does not exist"),
        "unexpected error: {err}"
    );
    // The danger is the opposite: silently creating an empty catalog and
    // exporting a valid-looking snapshot of nothing.
    assert!(!missing.exists(), "must not create the source it was given");
    assert!(!dest.path().join("olivier-sync.db").exists());
}

#[test]
fn rejects_a_catalog_with_an_unmapped_root() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());
    let conn = open(&src).unwrap();
    add_root(&conn, "/mnt/archive").unwrap();
    seed(&conn, 3, "/mnt/archive/three.flac");
    drop(conn);

    let err = export_snapshot(
        &src,
        dest.path().to_str().unwrap(),
        None,
        &[("/home/me/Music".to_string(), "/phone/Music".to_string())],
    )
    .unwrap_err();

    assert!(
        err.to_string().contains("/mnt/archive"),
        "the unmapped root must be named: {err}"
    );
    assert!(
        std::fs::read_dir(dest.path()).unwrap().next().is_none(),
        "no partial export left behind"
    );
}

#[test]
fn strips_the_musicbrainz_cache_and_machine_specific_settings() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());
    let conn = open(&src).unwrap();
    conn.execute(
        "INSERT INTO mb_cache(entity_type,mbid,inc_set,json,fetched_at)
         VALUES ('artist','A','',' {}',0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO setting(key,value) VALUES ('mb_contact_email','me@example.com'),
         ('sync_dest_dir','/home/me/Sync'), ('language_leads','original')",
        [],
    )
    .unwrap();
    drop(conn);

    export_snapshot(
        &src,
        dest.path().to_str().unwrap(),
        None,
        &[("/home/me/Music".to_string(), "/phone/Music".to_string())],
    )
    .unwrap();

    let copy = Connection::open(dest.path().join("olivier-sync.db")).unwrap();
    let n: i64 = copy
        .query_row("SELECT count(*) FROM mb_cache", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 0, "the phone never enriches");
    let keys: Vec<String> = {
        let mut s = copy
            .prepare("SELECT key FROM setting ORDER BY key")
            .unwrap();
        s.query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(
        keys,
        vec!["language_leads"],
        "display preferences carry over; machine-specific keys do not"
    );
}

#[test]
fn rebases_playlists_and_non_ascii_paths_through_the_export() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let db = tmp.path().join("olivier.db").to_string_lossy().into_owned();
    let conn = open(&db).unwrap();
    add_root(&conn, "/home/me/音楽").unwrap();
    seed(&conn, 1, "/home/me/音楽/椎名林檎/曲.flac");
    conn.execute(
        "INSERT INTO playlist(id,name,position,created_at) VALUES (1,'P',0,0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO playlist_item(playlist_id,position,path)
         VALUES (1,0,'/home/me/音楽/椎名林檎/曲.flac')",
        [],
    )
    .unwrap();
    drop(conn);

    export_snapshot(
        &db,
        dest.path().to_str().unwrap(),
        None,
        &[("/home/me/音楽".to_string(), "/storage/音楽".to_string())],
    )
    .unwrap();

    let copy = Connection::open(dest.path().join("olivier-sync.db")).unwrap();
    assert_eq!(paths(&copy, "file"), vec!["/storage/音楽/椎名林檎/曲.flac"]);
    assert_eq!(
        paths(&copy, "playlist_item"),
        vec!["/storage/音楽/椎名林檎/曲.flac"],
        "playlists must survive the foreign-key-sensitive rewrite"
    );
}

#[test]
fn leaves_no_wal_siblings_in_the_destination() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());

    export_snapshot(
        &src,
        dest.path().to_str().unwrap(),
        None,
        &[("/home/me/Music".to_string(), "/phone/Music".to_string())],
    )
    .unwrap();

    let mut names: Vec<String> = std::fs::read_dir(dest.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(
        names,
        vec!["olivier-sync.db", "olivier-sync.json"],
        "no -wal/-shm siblings and no leftover temp files"
    );
}

#[test]
fn rejects_an_empty_mapping() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());

    let err = export_snapshot(&src, dest.path().to_str().unwrap(), None, &[]).unwrap_err();

    assert!(
        err.to_string().contains("no root mappings"),
        "unexpected error: {err}"
    );
}

#[test]
fn a_failed_rebase_leaves_no_snapshot_behind() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());

    let err = export_snapshot(
        &src,
        dest.path().to_str().unwrap(),
        None,
        // A destination rebase_root rejects, so the failure lands *after* the
        // VACUUM INTO has already written the temp file.
        &[("/home/me/Music".to_string(), "relative/path".to_string())],
    )
    .unwrap_err();
    assert!(
        err.to_string().contains("is not an absolute path"),
        "unexpected error: {err}"
    );

    assert!(
        !dest.path().join("olivier-sync.db").exists(),
        "a half-built snapshot must not be left where the importer would find it"
    );
    assert!(
        std::fs::read_dir(dest.path()).unwrap().next().is_none(),
        "no temp files left behind either"
    );
}

#[test]
fn overwrites_a_previous_snapshot() {
    let tmp = tempfile::tempdir().unwrap();
    let dest = tempfile::tempdir().unwrap();
    let src = source_db(tmp.path());
    let mapping = [("/home/me/Music".to_string(), "/phone/Music".to_string())];

    export_snapshot(&src, dest.path().to_str().unwrap(), None, &mapping).unwrap();
    // A second export over the top must succeed and reflect the newer catalog.
    let conn = open(&src).unwrap();
    seed(&conn, 3, "/home/me/Music/c/three.flac");
    drop(conn);
    let out = export_snapshot(&src, dest.path().to_str().unwrap(), None, &mapping).unwrap();

    assert_eq!(out.files, 3);
    let copy = Connection::open(dest.path().join("olivier-sync.db")).unwrap();
    assert_eq!(paths(&copy, "file").len(), 3);
    // The sidecar is the commit marker, so it must describe the DB beside it —
    // not the previous export's.
    let meta = std::fs::read_to_string(dest.path().join("olivier-sync.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&meta).unwrap();
    assert_eq!(v["files"], 3);
}
