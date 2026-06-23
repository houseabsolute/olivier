use crate::decision_log::DecisionLog;

/// Append one timestamped line to the shared activity/error log
/// (`import-log.log`, next to the DB), so Dart-side errors join the Rust-side
/// scan/enrich decisions in one log. `DecisionLog` swallows its own IO errors,
/// so this can never fail a caller.
pub fn log_activity(db_path: String, category: String, detail: String) {
    DecisionLog::for_db(&db_path).line(&category, &detail);
}
