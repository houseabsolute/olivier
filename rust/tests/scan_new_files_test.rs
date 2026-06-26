use rust_lib_olivier::catalog::scan::{scan_roots, scan_roots_new_only};
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
fn new_only_imports_new_files_and_leaves_known_untouched() {
    let tmp = TempDir::new().unwrap();
    let music = tmp.path().join("music");
    fs::create_dir_all(&music).unwrap();
    let one = music.join("one.flac");
    let adel = music.join("adel.flac");
    fs::copy(fixture("sample.flac"), &one).unwrap();
    fs::copy(fixture("sample.flac"), &adel).unwrap();

    let mut conn = open(":memory:").unwrap();
    let log = DecisionLog::to_path(None);
    let roots = vec![music.to_string_lossy().to_string()];

    // Full scan imports both.
    scan_roots(&mut conn, &roots, &log, |_| {}).unwrap();
    let one_path = one.to_string_lossy().to_string();
    let epoch_before: i64 = conn
        .query_row(
            "SELECT scan_epoch FROM file WHERE path = ?1",
            [&one_path],
            |r| r.get(0),
        )
        .unwrap();

    // Add a NEW file; delete a KNOWN one on disk.
    let two = music.join("two.flac");
    fs::copy(fixture("sample.flac"), &two).unwrap();
    fs::remove_file(&adel).unwrap();

    scan_roots_new_only(&mut conn, &roots, &log, |_| {}).unwrap();

    // two.flac imported; adel.flac (deleted on disk) NOT pruned; one.flac kept.
    let mut paths: Vec<String> = {
        let mut s = conn.prepare("SELECT path FROM file").unwrap();
        s.query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    paths.sort();
    let mut want = vec![
        adel.to_string_lossy().to_string(),
        one_path.clone(),
        two.to_string_lossy().to_string(),
    ];
    want.sort();
    assert_eq!(
        paths, want,
        "new file imported; deleted-on-disk known file NOT pruned"
    );

    // The known file's row was not reprocessed (scan_epoch untouched).
    let epoch_after: i64 = conn
        .query_row(
            "SELECT scan_epoch FROM file WHERE path = ?1",
            [&one_path],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        epoch_after, epoch_before,
        "known file untouched by new-only"
    );
}
