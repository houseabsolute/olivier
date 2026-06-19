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
fn deleting_a_file_then_rescanning_logs_remove_and_prune() {
    let tmp = TempDir::new().unwrap();
    let music = tmp.path().join("music");
    fs::create_dir_all(&music).unwrap();
    let track = music.join("one.flac");
    fs::copy(fixture("sample.flac"), &track).unwrap();

    let mut conn = open(":memory:").unwrap();
    let log_path = tmp.path().join("import-log.log");
    let log = DecisionLog::to_path(Some(log_path.clone()));
    let roots = vec![music.to_string_lossy().to_string()];

    // First scan imports the file.
    scan_roots(&mut conn, &roots, &log, |_| {}).unwrap();
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM file", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );

    // Delete the file on disk and re-scan.
    fs::remove_file(&track).unwrap();
    scan_roots(&mut conn, &roots, &log, |_| {}).unwrap();

    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM file", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0,
        "the deleted file should be swept"
    );
    let body = fs::read_to_string(&log_path).unwrap();
    assert!(
        body.contains("REMOVE") && body.contains("one.flac"),
        "expected REMOVE: {body}"
    );
    assert!(
        body.contains("PRUNE"),
        "expected PRUNE of the now-orphaned track/album: {body}"
    );
    // The track, its album, AND its artist all become orphaned by the removal —
    // each must be logged (the prune cascade must not silently drop the album
    // and artist that vanish with the track).
    assert!(
        body.matches("(no files remain)").count() >= 3,
        "expected the orphaned track, album, AND artist to each be pruned-and-logged: {body}"
    );
}
