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
fn a_bad_file_logs_fail_and_the_scan_still_imports_the_good_one() {
    let tmp = TempDir::new().unwrap();
    let music = tmp.path().join("music");
    fs::create_dir_all(&music).unwrap();
    // One real audio file …
    fs::copy(fixture("sample.flac"), music.join("good.flac")).unwrap();
    // … and one file with an audio extension but garbage contents.
    fs::write(music.join("broken.flac"), b"not a real flac").unwrap();

    let mut conn = open(":memory:").unwrap();
    let log_path = tmp.path().join("import-log.log");
    let log = DecisionLog::to_path(Some(log_path.clone()));

    // Must NOT error despite the broken file.
    scan_roots(
        &mut conn,
        &[music.to_string_lossy().to_string()],
        &log,
        |_| {},
    )
    .unwrap();

    // The good file imported.
    let tracks: i64 = conn
        .query_row("SELECT COUNT(*) FROM track", [], |r| r.get(0))
        .unwrap();
    assert_eq!(tracks, 1, "the good file should have imported");

    // The bad file produced a FAIL line.
    let body = fs::read_to_string(&log_path).unwrap();
    assert!(body.contains("FAIL"), "expected a FAIL line, got: {body}");
    assert!(
        body.contains("broken.flac"),
        "FAIL should name the bad file: {body}"
    );
}
