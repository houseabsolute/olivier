use crate::sync;

/// One library root paired with where its files live on the phone.
pub struct RootMapping {
    pub desktop: String,
    pub phone: String,
}

/// What an export produced, for the confirmation the UI shows.
pub struct SnapshotResult {
    pub db_path: String,
    pub files: i64,
    pub covers_copied: i64,
}

/// What an import did, for the startup log and the Settings summary.
pub struct ImportResult {
    pub imported: bool,
    pub reason: String,
    pub files: i64,
    pub covers_copied: i64,
}

/// Adopt a snapshot from `src_dir` as the catalog at `db_path`, if there is a
/// newer one there. See [`crate::sync::import_snapshot`].
pub fn import_sync_snapshot(
    src_dir: String,
    db_path: String,
    cache_dir: Option<String>,
) -> anyhow::Result<ImportResult> {
    let out = sync::import_snapshot(&src_dir, &db_path, cache_dir.as_deref())?;
    Ok(ImportResult {
        imported: out.imported,
        reason: out.reason,
        files: out.files as i64,
        covers_copied: out.covers_copied as i64,
    })
}

/// Write a phone-ready snapshot of the catalog into `dest_dir` (a folder
/// Syncthing replicates to the device). See [`crate::sync::export_snapshot`].
pub fn export_sync_snapshot(
    db_path: String,
    dest_dir: String,
    cache_dir: Option<String>,
    mappings: Vec<RootMapping>,
) -> anyhow::Result<SnapshotResult> {
    let pairs: Vec<(String, String)> = mappings.into_iter().map(|m| (m.desktop, m.phone)).collect();
    let out = sync::export_snapshot(&db_path, &dest_dir, cache_dir.as_deref(), &pairs)?;
    Ok(SnapshotResult {
        db_path: out.db_path,
        files: out.files as i64,
        covers_copied: out.covers_copied as i64,
    })
}
