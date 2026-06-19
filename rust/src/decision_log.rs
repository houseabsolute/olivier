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
        self.write_line(&format!("=== {text} @ {} ===", fmt_utc(now_secs())));
    }

    /// Record one decision (timestamp + padded category + detail).
    pub fn record(&self, d: &Decision) {
        self.write_line(&format!(
            "{}  {:<7} {}",
            fmt_utc(now_secs()),
            d.category(),
            d.detail()
        ));
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

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Format a unix-seconds instant as UTC `YYYY-MM-DD HH:MM:SS` (no deps;
/// Howard Hinnant's civil-from-days algorithm).
fn fmt_utc(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (h, mi, s) = (sod / 3600, (sod % 3600) / 60, sod % 60);

    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };

    format!("{year:04}-{m:02}-{d:02} {h:02}:{mi:02}:{s:02}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn fmt_utc_formats_known_epochs() {
        assert_eq!(fmt_utc(0), "1970-01-01 00:00:00");
        assert_eq!(fmt_utc(86400), "1970-01-02 00:00:00");
        assert_eq!(fmt_utc(1_700_000_000), "2023-11-14 22:13:20");
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
