use rusqlite::Connection;
use rust_lib_olivier::catalog::roots::{add_root, list_roots, rebase_root};
use rust_lib_olivier::db::open;

/// Seed one track/file under `path`, plus a queue entry and a playlist entry
/// pointing at it — the three tables that carry absolute paths alongside `root`.
fn seed_file(conn: &Connection, id: i64, path: &str) {
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
    conn.execute(
        "INSERT INTO queue_item(position,path) VALUES (?1,?2)",
        rusqlite::params![id, path],
    )
    .unwrap();
    conn.execute(
        "INSERT OR IGNORE INTO playlist(id,name,position,created_at) VALUES (1,'P',0,0)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO playlist_item(playlist_id,position,path) VALUES (1,?1,?2)",
        rusqlite::params![id, path],
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

#[test]
fn rewrites_file_queue_and_playlist_paths_together() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/home/me/Music").unwrap();
    seed_file(&conn, 1, "/home/me/Music/a/one.flac");
    seed_file(&conn, 2, "/home/me/Music/b/two.flac");

    let n = rebase_root(&conn, "/home/me/Music", "/storage/emulated/0/Music").unwrap();

    assert_eq!(n, 2, "returns the number of file rows rewritten");
    assert_eq!(
        paths(&conn, "file"),
        vec![
            "/storage/emulated/0/Music/a/one.flac",
            "/storage/emulated/0/Music/b/two.flac"
        ]
    );
    assert_eq!(
        paths(&conn, "queue_item"),
        vec![
            "/storage/emulated/0/Music/a/one.flac",
            "/storage/emulated/0/Music/b/two.flac"
        ]
    );
    assert_eq!(
        paths(&conn, "playlist_item"),
        vec![
            "/storage/emulated/0/Music/a/one.flac",
            "/storage/emulated/0/Music/b/two.flac"
        ]
    );
    assert_eq!(
        list_roots(&conn).unwrap(),
        vec!["/storage/emulated/0/Music"]
    );
}

#[test]
fn leaves_files_under_other_roots_untouched() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/home/me/Music").unwrap();
    add_root(&conn, "/mnt/archive").unwrap();
    seed_file(&conn, 1, "/home/me/Music/one.flac");
    seed_file(&conn, 2, "/mnt/archive/two.flac");

    rebase_root(&conn, "/home/me/Music", "/phone/Music").unwrap();

    assert_eq!(
        paths(&conn, "file"),
        vec!["/mnt/archive/two.flac", "/phone/Music/one.flac"]
    );
    // The other root's queue and playlist rows must be untouched too — a bad
    // prefix match would show up here first.
    assert_eq!(
        paths(&conn, "queue_item"),
        vec!["/mnt/archive/two.flac", "/phone/Music/one.flac"]
    );
    assert_eq!(
        paths(&conn, "playlist_item"),
        vec!["/mnt/archive/two.flac", "/phone/Music/one.flac"]
    );
    let mut roots = list_roots(&conn).unwrap();
    roots.sort();
    assert_eq!(roots, vec!["/mnt/archive", "/phone/Music"]);
}

#[test]
fn trailing_slashes_are_normalized() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/home/me/Music").unwrap();
    seed_file(&conn, 1, "/home/me/Music/one.flac");

    rebase_root(&conn, "/home/me/Music/", "/phone/Music/").unwrap();

    assert_eq!(paths(&conn, "file"), vec!["/phone/Music/one.flac"]);
    assert_eq!(list_roots(&conn).unwrap(), vec!["/phone/Music"]);
}

#[test]
fn rejects_an_unregistered_old_root() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/home/me/Music").unwrap();

    let err = rebase_root(&conn, "/not/a/root", "/phone/Music").unwrap_err();

    assert!(
        err.to_string().contains("not a registered root"),
        "unexpected error: {err}"
    );
}

#[test]
fn rejects_a_new_root_that_already_exists() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/home/me/Music").unwrap();
    add_root(&conn, "/mnt/archive").unwrap();

    let err = rebase_root(&conn, "/home/me/Music", "/mnt/archive").unwrap_err();

    assert!(
        err.to_string().contains("already a registered root"),
        "unexpected error: {err}"
    );
}

#[test]
fn a_failed_rebase_leaves_the_catalog_untouched() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/home/me/Music").unwrap();
    add_root(&conn, "/mnt/archive").unwrap();
    seed_file(&conn, 1, "/home/me/Music/one.flac");

    let _ = rebase_root(&conn, "/home/me/Music", "/mnt/archive").unwrap_err();

    assert_eq!(paths(&conn, "file"), vec!["/home/me/Music/one.flac"]);
    assert_eq!(paths(&conn, "queue_item"), vec!["/home/me/Music/one.flac"]);
}

/// The bail above happens before any write. This forces a failure *inside* the
/// transaction — a UNIQUE collision on `file.path` at commit — to prove the
/// rollback, the pragma reset, and that the connection stays usable.
#[test]
fn a_mid_transaction_failure_rolls_back_and_leaves_the_connection_usable() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/music").unwrap();
    seed_file(&conn, 1, "/music/x.flac");
    // Same relative path under a second, unregistered location, so rebasing
    // /music onto it collides on file.path's UNIQUE index.
    seed_file(&conn, 2, "/archive/music/x.flac");

    let err = rebase_root(&conn, "/music", "/archive/music").unwrap_err();
    assert!(
        err.to_string().contains("UNIQUE constraint failed"),
        "expected a constraint failure, got: {err}"
    );

    assert_eq!(
        paths(&conn, "file"),
        vec!["/archive/music/x.flac", "/music/x.flac"]
    );
    assert_eq!(
        paths(&conn, "queue_item"),
        vec!["/archive/music/x.flac", "/music/x.flac"]
    );
    assert_eq!(
        paths(&conn, "playlist_item"),
        vec!["/archive/music/x.flac", "/music/x.flac"]
    );
    assert_eq!(list_roots(&conn).unwrap(), vec!["/music"]);

    assert!(conn.is_autocommit(), "transaction must not leak");
    let deferred: i64 = conn
        .query_row("PRAGMA defer_foreign_keys", [], |r| r.get(0))
        .unwrap();
    assert_eq!(deferred, 0, "defer_foreign_keys must reset on rollback");

    // The connection still works for a subsequent, valid rebase.
    rebase_root(&conn, "/music", "/phone/Music").unwrap();
    assert_eq!(
        paths(&conn, "file"),
        vec!["/archive/music/x.flac", "/phone/Music/x.flac"]
    );
}

#[test]
fn rejects_a_new_root_that_overlaps_an_existing_one() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/music").unwrap();
    add_root(&conn, "/archive").unwrap();

    let err = rebase_root(&conn, "/music", "/archive/music").unwrap_err();

    assert!(
        err.to_string().contains("overlaps the registered root"),
        "unexpected error: {err}"
    );
}

#[test]
fn rejects_a_new_root_that_is_not_an_absolute_path() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/music").unwrap();
    seed_file(&conn, 1, "/music/one.flac");

    for bad in ["", "/", "relative/path"] {
        let err = rebase_root(&conn, "/music", bad).unwrap_err();
        assert!(
            err.to_string().contains("is not an absolute path"),
            "{bad:?} should be rejected, got: {err}"
        );
    }
    assert_eq!(paths(&conn, "file"), vec!["/music/one.flac"]);
    assert_eq!(list_roots(&conn).unwrap(), vec!["/music"]);
}

#[test]
fn rebasing_a_root_onto_itself_is_a_no_op() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/music").unwrap();
    seed_file(&conn, 1, "/music/one.flac");

    let n = rebase_root(&conn, "/music", "/music").unwrap();

    assert_eq!(n, 1);
    assert_eq!(paths(&conn, "file"), vec!["/music/one.flac"]);
    assert_eq!(list_roots(&conn).unwrap(), vec!["/music"]);
}

#[test]
fn rebasing_into_the_old_root_rewrites_each_path_once() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/music").unwrap();
    seed_file(&conn, 1, "/music/one.flac");

    rebase_root(&conn, "/music", "/music/sub").unwrap();

    // Not "/music/sub/sub/one.flac" — the single UPDATE pass matches against
    // pre-update values.
    assert_eq!(paths(&conn, "file"), vec!["/music/sub/one.flac"]);
    assert_eq!(list_roots(&conn).unwrap(), vec!["/music/sub"]);
}

#[test]
fn a_path_equal_to_the_root_itself_is_left_alone() {
    let conn = open(":memory:").unwrap();
    add_root(&conn, "/music").unwrap();
    // Pathological: a file row whose path is the root with no child component,
    // so it lacks the trailing slash the prefix match requires.
    seed_file(&conn, 1, "/music");

    rebase_root(&conn, "/music", "/phone/Music").unwrap();

    assert_eq!(paths(&conn, "file"), vec!["/music"]);
}

#[test]
fn handles_non_ascii_paths() {
    let conn = open(":memory:").unwrap();
    // A root whose byte length differs from its char count, which is what the
    // prefix match must get right (SQLite's substr counts characters).
    add_root(&conn, "/home/me/音楽").unwrap();
    seed_file(&conn, 1, "/home/me/音楽/椎名林檎/曲.flac");

    rebase_root(&conn, "/home/me/音楽", "/phone/音楽").unwrap();

    assert_eq!(paths(&conn, "file"), vec!["/phone/音楽/椎名林檎/曲.flac"]);
    assert_eq!(
        paths(&conn, "playlist_item"),
        vec!["/phone/音楽/椎名林檎/曲.flac"]
    );
}

#[test]
fn a_root_that_is_a_prefix_of_another_does_not_capture_its_files() {
    let conn = open(":memory:").unwrap();
    // "/music" is a string prefix of "/music-archive", but not a path prefix.
    add_root(&conn, "/music").unwrap();
    add_root(&conn, "/music-archive").unwrap();
    seed_file(&conn, 1, "/music/one.flac");
    seed_file(&conn, 2, "/music-archive/two.flac");

    rebase_root(&conn, "/music", "/phone/Music").unwrap();

    assert_eq!(
        paths(&conn, "file"),
        vec!["/music-archive/two.flac", "/phone/Music/one.flac"]
    );
}
