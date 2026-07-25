use rusqlite::Connection;
use rust_lib_olivier::catalog::roots::add_root;
use rust_lib_olivier::db::open;
use rust_lib_olivier::sync::{export_snapshot, import_snapshot};
use std::path::Path;

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

/// A desktop catalog exported into `sync_dir`, as the phone would receive it.
fn published(desktop: &Path, sync_dir: &Path, tracks: usize) -> String {
    let db = desktop.join("olivier.db").to_string_lossy().into_owned();
    let conn = open(&db).unwrap();
    add_root(&conn, "/home/me/Music").unwrap();
    for i in 1..=tracks {
        seed(&conn, i as i64, &format!("/home/me/Music/{i}.flac"));
    }
    drop(conn);
    export_snapshot(
        &db,
        sync_dir.to_str().unwrap(),
        None,
        &[(
            "/home/me/Music".to_string(),
            "/storage/emulated/0/Music".to_string(),
        )],
    )
    .unwrap();
    db
}

fn file_count(db: &str) -> i64 {
    Connection::open(db)
        .unwrap()
        .query_row("SELECT count(*) FROM file", [], |r| r.get(0))
        .unwrap()
}

#[test]
fn imports_a_snapshot_into_an_empty_app_db() {
    let desktop = tempfile::tempdir().unwrap();
    let sync = tempfile::tempdir().unwrap();
    let phone = tempfile::tempdir().unwrap();
    published(desktop.path(), sync.path(), 3);
    let app_db = phone
        .path()
        .join("olivier.db")
        .to_string_lossy()
        .into_owned();

    let out = import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap();

    assert!(out.imported, "reason: {}", out.reason);
    assert_eq!(out.files, 3);
    assert_eq!(file_count(&app_db), 3);
    // Paths arrive already rebased for the device.
    let first: String = Connection::open(&app_db)
        .unwrap()
        .query_row("SELECT path FROM file ORDER BY path LIMIT 1", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert!(
        first.starts_with("/storage/emulated/0/Music/"),
        "got {first}"
    );
}

#[test]
fn a_second_import_of_the_same_snapshot_is_skipped() {
    let desktop = tempfile::tempdir().unwrap();
    let sync = tempfile::tempdir().unwrap();
    let phone = tempfile::tempdir().unwrap();
    published(desktop.path(), sync.path(), 2);
    let app_db = phone
        .path()
        .join("olivier.db")
        .to_string_lossy()
        .into_owned();

    assert!(
        import_snapshot(sync.path().to_str().unwrap(), &app_db, None)
            .unwrap()
            .imported
    );
    // Something the phone did after importing, which a needless re-import
    // would silently throw away.
    Connection::open(&app_db)
        .unwrap()
        .execute(
            "INSERT INTO queue_item(position,path) VALUES (1,'/x.flac')",
            [],
        )
        .unwrap();

    let second = import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap();

    assert!(!second.imported);
    assert!(
        second.reason.contains("already"),
        "reason: {}",
        second.reason
    );
    let queued: i64 = Connection::open(&app_db)
        .unwrap()
        .query_row("SELECT count(*) FROM queue_item", [], |r| r.get(0))
        .unwrap();
    assert_eq!(queued, 1, "the phone's own state must survive");
}

#[test]
fn a_newer_snapshot_replaces_the_previous_import() {
    let desktop = tempfile::tempdir().unwrap();
    let sync = tempfile::tempdir().unwrap();
    let phone = tempfile::tempdir().unwrap();
    let db = published(desktop.path(), sync.path(), 2);
    let app_db = phone
        .path()
        .join("olivier.db")
        .to_string_lossy()
        .into_owned();
    import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap();

    // The desktop gains a track and re-exports.
    let conn = open(&db).unwrap();
    seed(&conn, 3, "/home/me/Music/3.flac");
    drop(conn);
    export_snapshot(
        &db,
        sync.path().to_str().unwrap(),
        None,
        &[(
            "/home/me/Music".to_string(),
            "/storage/emulated/0/Music".to_string(),
        )],
    )
    .unwrap();

    let out = import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap();

    assert!(out.imported, "reason: {}", out.reason);
    assert_eq!(file_count(&app_db), 3);
}

#[test]
fn no_snapshot_is_reported_not_thrown() {
    let sync = tempfile::tempdir().unwrap();
    let phone = tempfile::tempdir().unwrap();
    let app_db = phone
        .path()
        .join("olivier.db")
        .to_string_lossy()
        .into_owned();

    let out = import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap();

    assert!(!out.imported);
    assert!(out.reason.contains("no snapshot"), "reason: {}", out.reason);
    assert!(
        !Path::new(&app_db).exists(),
        "a missing snapshot must not create a catalog"
    );
}

#[test]
fn a_sidecar_without_its_database_is_refused() {
    let sync = tempfile::tempdir().unwrap();
    let phone = tempfile::tempdir().unwrap();
    let app_db = phone
        .path()
        .join("olivier.db")
        .to_string_lossy()
        .into_owned();
    // The sidecar is the export's commit marker, but a truncated sync could
    // still deliver it alone.
    std::fs::write(
        sync.path().join("olivier-sync.json"),
        r#"{"schema_version":9,"exported_at":"2026-07-25T00:00:00Z","files":1}"#,
    )
    .unwrap();

    let err = import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap_err();

    assert!(err.to_string().contains("olivier-sync.db"), "got: {err}");
}

#[test]
fn a_snapshot_from_a_newer_app_is_refused() {
    let desktop = tempfile::tempdir().unwrap();
    let sync = tempfile::tempdir().unwrap();
    let phone = tempfile::tempdir().unwrap();
    published(desktop.path(), sync.path(), 1);
    let app_db = phone
        .path()
        .join("olivier.db")
        .to_string_lossy()
        .into_owned();
    // Rewrite the sidecar as if exported by a desktop that had run further
    // migrations than this build knows about.
    std::fs::write(
        sync.path().join("olivier-sync.json"),
        r#"{"schema_version":9999,"exported_at":"2026-07-25T00:00:00Z","files":1}"#,
    )
    .unwrap();

    let out = import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap();

    assert!(!out.imported);
    assert!(out.reason.contains("newer"), "reason: {}", out.reason);
    assert!(!Path::new(&app_db).exists(), "must not import it anyway");
}

#[test]
fn a_corrupt_snapshot_leaves_the_existing_catalog_alone() {
    let desktop = tempfile::tempdir().unwrap();
    let sync = tempfile::tempdir().unwrap();
    let phone = tempfile::tempdir().unwrap();
    published(desktop.path(), sync.path(), 2);
    let app_db = phone
        .path()
        .join("olivier.db")
        .to_string_lossy()
        .into_owned();
    import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap();

    // A newer sidecar pointing at a database that is not one.
    std::fs::write(
        sync.path().join("olivier-sync.db"),
        b"this is not a sqlite file",
    )
    .unwrap();
    std::fs::write(
        sync.path().join("olivier-sync.json"),
        format!(
            r#"{{"schema_version":{},"exported_at":"2099-01-01T00:00:00Z","files":2}}"#,
            rust_lib_olivier::db::current_schema_version()
        ),
    )
    .unwrap();

    let err = import_snapshot(sync.path().to_str().unwrap(), &app_db, None).unwrap_err();
    assert!(!err.to_string().is_empty());

    assert_eq!(
        file_count(&app_db),
        2,
        "the good catalog must survive a bad import"
    );
}

#[test]
fn copies_the_covers_alongside() {
    let desktop = tempfile::tempdir().unwrap();
    let sync = tempfile::tempdir().unwrap();
    let phone = tempfile::tempdir().unwrap();
    let cache = tempfile::tempdir().unwrap();
    published(desktop.path(), sync.path(), 1);
    std::fs::create_dir_all(sync.path().join("covers")).unwrap();
    std::fs::write(sync.path().join("covers/olivier-caa-R.jpg"), b"jpeg").unwrap();
    let app_db = phone
        .path()
        .join("olivier.db")
        .to_string_lossy()
        .into_owned();

    let out = import_snapshot(
        sync.path().to_str().unwrap(),
        &app_db,
        Some(cache.path().to_str().unwrap()),
    )
    .unwrap();

    assert_eq!(out.covers_copied, 1);
    assert!(cache.path().join("olivier-caa-R.jpg").exists());
}
