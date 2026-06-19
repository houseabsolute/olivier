use rust_lib_olivier::catalog::scan::scan_roots;
use rust_lib_olivier::db::open;
use rust_lib_olivier::decision_log::DecisionLog;
use std::fs;
use tempfile::TempDir;

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

#[test]
fn first_copy_adds_and_a_second_same_track_copy_dedups() {
    let tmp = TempDir::new().unwrap();
    let music = tmp.path().join("music");
    fs::create_dir_all(&music).unwrap();
    // Two copies of one file => identical tags => same (release, disc, position).
    fs::copy(fixture("sample.flac"), music.join("a.flac")).unwrap();
    fs::copy(fixture("sample.flac"), music.join("b.flac")).unwrap();

    let mut conn = open(":memory:").unwrap();
    let log_path = tmp.path().join("import-log.log");
    let log = DecisionLog::to_path(Some(log_path.clone()));
    scan_roots(
        &mut conn,
        &[music.to_string_lossy().to_string()],
        &log,
        |_| {},
    )
    .unwrap();

    // Both files import but collapse to a single track.
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM file", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        2
    );
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM track", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );

    let body = fs::read_to_string(&log_path).unwrap();
    assert!(body.contains("ADD"), "expected an ADD line: {body}");
    assert!(body.contains("DEDUP"), "expected a DEDUP line: {body}");
}
