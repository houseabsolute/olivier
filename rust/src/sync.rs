//! Export a phone-ready copy of the catalog.
//!
//! The phone is a read-only player over a library Syncthing already replicates
//! to it (see `docs/superpowers/specs/2026-07-25-android-synced-player-design.md`).
//! It never scans, so it needs a catalog built here — with every absolute path
//! rewritten to where the files live on the device.
//!
//! **The metadata sidecar is the commit marker.** It is written last, after the
//! database and covers are already in place under their final names, so a
//! consumer that finds `olivier-sync.json` knows everything it describes is
//! complete. Anything that fails earlier leaves no sidecar, and the importer
//! ignores the export. The live catalog is never modified: all rewriting happens
//! on a `VACUUM INTO` copy.

use rusqlite::Connection;
use std::path::{Path, PathBuf};

/// Basename of the exported catalog, and of its metadata sidecar.
pub const SNAPSHOT_NAME: &str = "olivier-sync.db";
pub const METADATA_NAME: &str = "olivier-sync.json";

#[derive(Debug)]
pub struct SnapshotExport {
    /// Absolute path of the snapshot that was written.
    pub db_path: String,
    /// Number of `file` rows in the snapshot.
    pub files: usize,
    /// Number of cover images copied.
    pub covers_copied: usize,
}

/// Deletes its path on drop unless disarmed — so every early return cleans up
/// the partial file, not just the ones we remembered to handle.
struct TempFile(PathBuf);

impl TempFile {
    fn disarm(self) -> PathBuf {
        let path = self.0.clone();
        std::mem::forget(self);
        path
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn utf8(path: &Path, what: &str) -> anyhow::Result<String> {
    path.to_str()
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("{what} is not valid UTF-8: {path:?}"))
}

/// Write a rebased copy of `src_db` into `dest_dir`.
///
/// `mappings` pairs each desktop root with its location on the device. Every
/// registered root must appear: an unmapped root would export files still
/// carrying desktop paths, which are dead links on the phone. Each pair is
/// applied with [`crate::catalog::roots::rebase_root`], so an unregistered or
/// overlapping root is rejected there.
///
/// `cache_dir`, when given, is scanned for cover images to copy alongside. Only
/// the `olivier-caa-{mbid}` files are portable — the `olivier-cover-{hash}`
/// ones are keyed by a hash of the absolute audio path and mean nothing once
/// the paths are rebased.
pub fn export_snapshot(
    src_db: &str,
    dest_dir: &str,
    cache_dir: Option<&str>,
    mappings: &[(String, String)],
) -> anyhow::Result<SnapshotExport> {
    if mappings.is_empty() {
        anyhow::bail!("no root mappings given — nothing to rebase");
    }
    // db::open would happily CREATE an empty catalog here, run every migration
    // on it, and export a valid-looking snapshot of nothing — which the phone
    // would then import over its good copy.
    if !Path::new(src_db).is_file() {
        anyhow::bail!("source catalog does not exist: {src_db}");
    }
    let dest = Path::new(dest_dir);
    std::fs::create_dir_all(dest)?;

    // Dot-prefixed and pid-suffixed: Syncthing ignores dotfiles, and two
    // concurrent exports to one folder can't scribble over each other.
    let tmp = TempFile(dest.join(format!(".{SNAPSHOT_NAME}.{}.tmp", std::process::id())));
    let built = build_snapshot(src_db, &tmp.0, mappings)?;

    // From here the snapshot is complete; publish it under its final name, then
    // the covers, and only then the sidecar that says all of it is ready.
    let snapshot = dest.join(SNAPSHOT_NAME);
    std::fs::rename(tmp.disarm(), &snapshot)?;

    let covers_copied = match cache_dir {
        Some(cache) => copy_covers(Path::new(cache), &dest.join("covers"))?,
        None => 0,
    };

    write_metadata(dest, built.schema_version, built.files)?;
    sync_dir(dest);

    Ok(SnapshotExport {
        db_path: utf8(&snapshot, "destination")?,
        files: built.files,
        covers_copied,
    })
}

struct Built {
    files: usize,
    schema_version: i64,
}

/// Copy, rebase and strip. The copy is left at `tmp`.
fn build_snapshot(
    src_db: &str,
    tmp: &Path,
    mappings: &[(String, String)],
) -> anyhow::Result<Built> {
    let src = crate::db::open(src_db)?;
    // VACUUM INTO writes a consistent copy without blocking the live catalog,
    // and (unlike a file copy) never picks up a torn WAL. It refuses to
    // overwrite, so the target must not exist — our temp name is unique per
    // process, but a previous run of *this* pid may have died mid-export.
    let _ = std::fs::remove_file(tmp);
    src.execute(
        "VACUUM INTO ?1",
        rusqlite::params![utf8(tmp, "destination")?],
    )?;
    drop(src);

    // Plain open, not db::open: the snapshot needs no migrations and must not
    // be switched to WAL, which would leave -wal/-shm siblings for the
    // destination to sync. Foreign keys are on regardless — the bundled SQLite
    // is compiled with SQLITE_DEFAULT_FOREIGN_KEYS=1.
    let copy = Connection::open(tmp)?;

    let unmapped: Vec<String> = crate::catalog::roots::list_roots(&copy)?
        .into_iter()
        .filter(|r| {
            !mappings
                .iter()
                .any(|(old, _)| old.trim_end_matches('/') == r)
        })
        .collect();
    if !unmapped.is_empty() {
        anyhow::bail!(
            "no phone location given for registered root(s): {}",
            unmapped.join(", ")
        );
    }
    for (old, new) in mappings {
        crate::catalog::roots::rebase_root(&copy, old, new)?;
    }

    // Device-local state: the phone keeps its own queue and playhead, and a
    // desktop position would otherwise resume mid-track on the phone.
    copy.execute("DELETE FROM queue_item", [])?;
    copy.execute("DELETE FROM playback_state", [])?;
    // Raw MusicBrainz responses, cached to avoid re-fetching during enrichment.
    // The phone never enriches, and this is typically the bulk of the file.
    copy.execute("DELETE FROM mb_cache", [])?;
    // Machine-specific settings. `mb_contact_email` identifies this desktop to
    // MusicBrainz; `sync_*` keys are this export's own configuration (desktop
    // absolute paths). Display preferences like `language_leads` are kept
    // deliberately — they should carry over.
    copy.execute(
        "DELETE FROM setting WHERE key = 'mb_contact_email' OR key LIKE 'sync\\_%' ESCAPE '\\'",
        [],
    )?;
    // `track_stats` (play counts, last-played) is kept on purpose: the phone
    // shows them read-only. Plays made on the phone are not synced back.

    let files: i64 = copy.query_row("SELECT count(*) FROM file", [], |r| r.get(0))?;
    let schema_version: i64 = copy.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    Ok(Built {
        files: files as usize,
        schema_version,
    })
}

/// Copy the MBID-keyed cover images. Returns how many were copied.
fn copy_covers(cache: &Path, dest: &Path) -> anyhow::Result<usize> {
    if !cache.is_dir() {
        return Ok(0);
    }
    std::fs::create_dir_all(dest)?;
    let mut copied = 0;
    for entry in std::fs::read_dir(cache)? {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let is_image = name.ends_with(".jpg") || name.ends_with(".png");
        // `.miss` sentinels are deliberately skipped: a negative result cached
        // on a desktop that happened to be offline shouldn't suppress the
        // phone's own lookup forever.
        if !(name.starts_with("olivier-caa-") && is_image) {
            continue;
        }
        // Copy-then-rename so a reader never sees a truncated image.
        let tmp = TempFile(dest.join(format!(".{name}.{}.tmp", std::process::id())));
        std::fs::copy(&path, &tmp.0)?;
        std::fs::rename(tmp.disarm(), dest.join(name))?;
        copied += 1;
    }
    Ok(copied)
}

/// Write the commit marker, itself atomically — `fs::write` truncates in place
/// and is observable half-written.
fn write_metadata(dest: &Path, schema_version: i64, files: usize) -> anyhow::Result<()> {
    let meta = serde_json::json!({
        "schema_version": schema_version,
        "exported_at": jiff::Timestamp::now().to_string(),
        "files": files,
    });
    let tmp = TempFile(dest.join(format!(".{METADATA_NAME}.{}.tmp", std::process::id())));
    std::fs::write(&tmp.0, serde_json::to_string_pretty(&meta)?)?;
    std::fs::rename(tmp.disarm(), dest.join(METADATA_NAME))?;
    Ok(())
}

/// Best-effort durability for the renames above. Failure here doesn't
/// invalidate the export, so it is not propagated.
fn sync_dir(dir: &Path) {
    if let Ok(handle) = std::fs::File::open(dir) {
        let _ = handle.sync_all();
    }
}

/// Setting key recording which snapshot a catalog was imported from, stored
/// *inside* the imported catalog so the marker travels with it — a separate
/// marker file could be deleted or restored out of step with the database.
const IMPORTED_AT_KEY: &str = "sync_imported_at";

#[derive(Debug)]
pub struct SnapshotImport {
    /// Whether the catalog was replaced.
    pub imported: bool,
    /// Why not, when it wasn't. Empty on success.
    pub reason: String,
    pub files: usize,
    pub covers_copied: usize,
}

fn skipped(reason: &str) -> SnapshotImport {
    SnapshotImport {
        imported: false,
        reason: reason.to_string(),
        files: 0,
        covers_copied: 0,
    }
}

/// Adopt a snapshot from `src_dir` as the catalog at `db_path`.
///
/// The phone is a read-only player: it never scans, so its catalog is whatever
/// the desktop last published. This replaces the whole database rather than
/// merging, which is why device-local rows are stripped at export time — see
/// [`export_snapshot`].
///
/// Returns without importing (rather than failing) for the ordinary cases: no
/// snapshot present, or the same one already imported. A snapshot that is
/// present but unusable *is* an error, so it can be surfaced.
pub fn import_snapshot(
    src_dir: &str,
    db_path: &str,
    cache_dir: Option<&str>,
) -> anyhow::Result<SnapshotImport> {
    let (snapshot, sidecar) = snapshot_paths(src_dir);
    // The sidecar is the export's commit marker; without it the export either
    // never finished or never happened.
    let Ok(meta_raw) = std::fs::read_to_string(&sidecar) else {
        return Ok(skipped("no snapshot in the sync folder"));
    };
    let meta: serde_json::Value = serde_json::from_str(&meta_raw)?;
    let exported_at = meta["exported_at"].as_str().unwrap_or_default().to_string();
    if exported_at.is_empty() {
        anyhow::bail!("snapshot metadata has no exported_at");
    }
    let schema_version = meta["schema_version"].as_i64().unwrap_or(-1);
    if schema_version > crate::db::current_schema_version() {
        return Ok(skipped(&format!(
            "snapshot is newer than this app (schema {schema_version} > {})",
            crate::db::current_schema_version()
        )));
    }
    if !snapshot.is_file() {
        anyhow::bail!("{} is missing beside its metadata", SNAPSHOT_NAME);
    }
    if already_imported(db_path, &exported_at)? {
        return Ok(skipped("already imported"));
    }

    // Stage beside the destination — same filesystem, so the swap is a rename —
    // and validate before anything touches the live catalog.
    let dest = Path::new(db_path);
    let parent = dest
        .parent()
        .ok_or_else(|| anyhow::anyhow!("db path has no parent: {db_path}"))?;
    std::fs::create_dir_all(parent)?;
    let staged = TempFile(parent.join(format!(".olivier-import.{}.tmp", std::process::id())));
    std::fs::copy(&snapshot, &staged.0)?;
    let files = validate_and_stamp(&staged.0, &exported_at)?;

    std::fs::rename(staged.disarm(), dest)?;
    // The replaced catalog's sidecars describe a database that no longer
    // exists; leaving them risks SQLite reading a stale journal.
    for suffix in ["-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{db_path}{suffix}"));
    }

    let covers_copied = match cache_dir {
        Some(cache) => copy_covers(&Path::new(src_dir).join("covers"), Path::new(cache))?,
        None => 0,
    };
    sync_dir(parent);

    Ok(SnapshotImport {
        imported: true,
        reason: String::new(),
        files,
        covers_copied,
    })
}

/// Whether `db_path` already holds this exact snapshot. A catalog that doesn't
/// exist, can't be opened, or predates the marker counts as "not imported".
fn already_imported(db_path: &str, exported_at: &str) -> anyhow::Result<bool> {
    if !Path::new(db_path).is_file() {
        return Ok(false);
    }
    let Ok(conn) = Connection::open(db_path) else {
        return Ok(false);
    };
    let stamped: Option<String> = conn
        .query_row(
            "SELECT value FROM setting WHERE key = ?1",
            rusqlite::params![IMPORTED_AT_KEY],
            |r| r.get(0),
        )
        .ok();
    Ok(stamped.as_deref() == Some(exported_at))
}

/// Confirm the staged copy really is a catalog, and stamp it with the snapshot
/// it came from. Returns its file count.
fn validate_and_stamp(staged: &Path, exported_at: &str) -> anyhow::Result<usize> {
    let conn = Connection::open(staged)?;
    let files: i64 = conn
        .query_row("SELECT count(*) FROM file", [], |r| r.get(0))
        .map_err(|e| anyhow::anyhow!("snapshot is not a usable catalog: {e}"))?;
    conn.execute(
        "INSERT INTO setting(key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![IMPORTED_AT_KEY, exported_at],
    )?;
    Ok(files as usize)
}

/// Where a snapshot and its sidecar live inside `dir`.
pub fn snapshot_paths(dir: &str) -> (PathBuf, PathBuf) {
    let d = Path::new(dir);
    (d.join(SNAPSHOT_NAME), d.join(METADATA_NAME))
}
