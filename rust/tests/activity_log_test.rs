use rust_lib_olivier::api::activity::log_activity;
use std::fs;

#[test]
fn log_activity_appends_a_categorized_line() {
    let dir = std::env::temp_dir().join(format!("olivier_activity_{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let db = dir.join("library.db");
    log_activity(
        db.to_string_lossy().to_string(),
        "ERROR".into(),
        "boom happened".into(),
    );
    let logged = fs::read_to_string(dir.join("import-log.log")).unwrap();
    assert!(logged.contains("ERROR"), "category present: {logged}");
    assert!(logged.contains("boom happened"), "detail present: {logged}");
    fs::remove_dir_all(&dir).ok();
}
