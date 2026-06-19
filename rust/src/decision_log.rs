//! A best-effort, human-readable decision log written to a plain text file
//! beside the DB. Every write is best-effort: any IO error is swallowed so
//! logging can never break or fail a scan/enrich.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

/// File name of the decision log, kept beside the SQLite DB.
pub const LOG_FILENAME: &str = "import-log.log";

/// One import/enrichment decision worth recording. The scanner emits the first
/// six variants; enrich (Phase 2) reuses this log with its own lines.
pub enum Decision {
    AddArtist {
        name: String,
    },
    AddAlbum {
        title: String,
        artist: String,
    },
    AddTrack {
        title: String,
        artist: String,
        album: String,
        path: String,
    },
    Dedup {
        path: String,
        track_title: String,
        album: String,
        disc: i64,
        position: i64,
        existing_path: String,
    },
    Remove {
        path: String,
    },
    PruneTrack {
        title: String,
        album: String,
    },
    PruneAlbum {
        title: String,
        artist: String,
    },
    PruneArtist {
        name: String,
    },
    Merge {
        synth_name: String,
        real_name: String,
        real_mbid: String,
    },
    Fail {
        path: String,
        error: String,
    },
}

impl Decision {
    pub fn category(&self) -> &'static str {
        match self {
            Decision::AddArtist { .. } | Decision::AddAlbum { .. } | Decision::AddTrack { .. } => {
                "ADD"
            }
            Decision::Dedup { .. } => "DEDUP",
            Decision::Remove { .. } => "REMOVE",
            Decision::PruneTrack { .. }
            | Decision::PruneAlbum { .. }
            | Decision::PruneArtist { .. } => "PRUNE",
            Decision::Merge { .. } => "MERGE",
            Decision::Fail { .. } => "FAIL",
        }
    }

    pub fn detail(&self) -> String {
        match self {
            Decision::AddArtist { name } => format!("artist \"{name}\""),
            Decision::AddAlbum { title, artist } => format!("album \"{title}\" — {artist}"),
            Decision::AddTrack {
                title,
                artist,
                album,
                path,
            } => {
                format!("track \"{title}\" — {artist} [{album}]  [{path}]")
            }
            Decision::Dedup {
                path,
                track_title,
                album,
                disc,
                position,
                existing_path,
            } => {
                format!(
                    "{path} → existing track \"{track_title}\" [{album}] (disc {disc}, pos {position}; also {existing_path})"
                )
            }
            Decision::Remove { path } => format!("file {path} (gone from disk)"),
            Decision::PruneTrack { title, album } => {
                format!("track \"{title}\" [{album}] (no files remain)")
            }
            Decision::PruneAlbum { title, artist } => {
                format!("album \"{title}\" — {artist} (no files remain)")
            }
            Decision::PruneArtist { name } => format!("artist \"{name}\" (no files remain)"),
            Decision::Merge {
                synth_name,
                real_name,
                real_mbid,
            } => {
                format!("synth artist \"{synth_name}\" → {real_name} (mbid {real_mbid})")
            }
            Decision::Fail { path, error } => format!("{path}: {error}"),
        }
    }
}

/// Append-only decision log. `None` path = disabled (all writes no-op).
pub struct DecisionLog {
    path: Option<PathBuf>,
}

impl DecisionLog {
    /// Log beside the DB: `<dir of db_path>/import-log.log`. A `:memory:` or
    /// parent-less db_path yields a relative file name (fine — production
    /// db_path is always an absolute file path).
    pub fn for_db(db_path: &str) -> Self {
        let dir = Path::new(db_path)
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        Self {
            path: Some(dir.join(LOG_FILENAME)),
        }
    }

    /// Explicit path (tests) or `None` to disable.
    pub fn to_path(path: Option<PathBuf>) -> Self {
        Self { path }
    }

    /// Write a run-delimiter header line.
    pub fn header(&self, text: &str) {
        self.write_line(&format!("=== {text} @ {} ===", now_local()));
    }

    /// Record one decision (timestamp + padded category + detail).
    pub fn record(&self, d: &Decision) {
        self.write_line(&format!(
            "{}  {:<7} {}",
            now_local(),
            d.category(),
            d.detail()
        ));
    }

    /// Record a free-form line (timestamp + padded category + detail). Used by
    /// the enrich pipeline, whose decisions don't map onto the scan `Decision`.
    pub fn line(&self, category: &str, detail: &str) {
        self.write_line(&format!("{}  {:<7} {}", now_local(), category, detail));
    }

    fn write_line(&self, line: &str) {
        let Some(path) = &self.path else { return };
        // Best-effort: ignore every IO error.
        let _ = (|| -> std::io::Result<()> {
            let mut f = OpenOptions::new().create(true).append(true).open(path)?;
            writeln!(f, "{line}")
        })();
    }
}

/// Current local wall-clock time formatted `YYYY-MM-DD HH:MM:SS`. jiff reads the
/// system time zone, falling back to UTC if it can't be determined — it never
/// panics, so the best-effort logging guarantee holds.
fn now_local() -> String {
    jiff::Zoned::now().strftime("%Y-%m-%d %H:%M:%S").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn now_local_has_the_expected_shape() {
        // Local time depends on the machine's tz, so assert the FORMAT shape
        // (YYYY-MM-DD HH:MM:SS), not a specific value.
        let ts = now_local();
        assert_eq!(ts.len(), 19, "got: {ts}");
        let b = ts.as_bytes();
        assert_eq!(b[4], b'-');
        assert_eq!(b[7], b'-');
        assert_eq!(b[10], b' ');
        assert_eq!(b[13], b':');
        assert_eq!(b[16], b':');
    }

    #[test]
    fn appends_header_and_decisions() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("import-log.log");
        let log = DecisionLog::to_path(Some(path.clone()));
        log.header("Scan /m/Music");
        log.record(&Decision::AddTrack {
            title: "T".into(),
            artist: "A".into(),
            album: "Al".into(),
            path: "/m/x.flac".into(),
        });
        log.record(&Decision::Dedup {
            path: "/m/y.flac".into(),
            track_title: "T".into(),
            album: "Al".into(),
            disc: 1,
            position: 2,
            existing_path: "/m/x.flac".into(),
        });

        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("=== Scan /m/Music @ "), "got: {body}");
        assert!(body.contains("ADD"), "got: {body}");
        assert!(body.contains("track \"T\" — A [Al]"), "got: {body}");
        assert!(body.contains("DEDUP"), "got: {body}");
        assert!(
            body.contains("/m/y.flac → existing track \"T\""),
            "got: {body}"
        );
    }

    #[test]
    fn disabled_and_bad_path_never_panic() {
        DecisionLog::to_path(None).record(&Decision::Remove { path: "/x".into() });
        let bad = std::path::PathBuf::from("/nonexistent-dir-xyz/import-log.log");
        DecisionLog::to_path(Some(bad)).record(&Decision::Remove { path: "/x".into() });
    }
}
