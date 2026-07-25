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
