use crate::enrich::http::MbHttp;
use rusqlite::{Connection, OptionalExtension};
use std::path::Path;

/// Sniff an image extension from magic bytes; default to jpg.
fn sniff_ext(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "jpg"
    } else if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        "png"
    } else {
        "jpg"
    }
}

/// Resolve an album cover: embedded art (from `rep_file`) -> Cover Art Archive
/// (release front, then release-group front) -> a `.miss` sentinel. Returns a
/// path to a cached image, or None. Extraction and network failures degrade to
/// None (only a failed cache write surfaces as Err).
pub async fn resolve_cover(
    http: &impl MbHttp,
    rep_file: Option<&str>,
    release_mbid: &str,
    rg_mbid: Option<&str>,
    cache_dir: &str,
) -> anyhow::Result<Option<String>> {
    // 1. Embedded art (extraction errors are swallowed -> fall through to CAA).
    if let Some(path) = rep_file {
        if let Ok(Some(cover)) = crate::tags::extract_cover_to(path, cache_dir) {
            return Ok(Some(cover));
        }
    }

    // 2. CAA disk cache (we wrote either .jpg or .png).
    for ext in ["jpg", "png"] {
        let cached = Path::new(cache_dir).join(format!("olivier-caa-{release_mbid}.{ext}"));
        if cached.exists() {
            return Ok(Some(cached.to_string_lossy().into_owned()));
        }
    }

    // 3. Negative cache.
    let miss = Path::new(cache_dir).join(format!("olivier-caa-{release_mbid}.miss"));
    if miss.exists() {
        return Ok(None);
    }

    // 4. CAA network: release first, then release-group.
    let mut urls = vec![format!(
        "https://coverartarchive.org/release/{release_mbid}/front-500"
    )];
    if let Some(rg) = rg_mbid {
        urls.push(format!(
            "https://coverartarchive.org/release-group/{rg}/front-500"
        ));
    }
    for url in urls {
        if let Ok((200, bytes)) = http.get_bytes(&url).await {
            if !bytes.is_empty() {
                let ext = sniff_ext(&bytes);
                std::fs::create_dir_all(cache_dir)?;
                let out =
                    Path::new(cache_dir).join(format!("olivier-caa-{release_mbid}.{ext}"));
                std::fs::write(&out, &bytes)?;
                return Ok(Some(out.to_string_lossy().into_owned()));
            }
        }
    }

    // 5. Record the miss so art-less releases aren't re-fetched on every scroll.
    std::fs::create_dir_all(cache_dir)?;
    std::fs::write(&miss, b"")?;
    Ok(None)
}

/// The lexically-first file backing any track of the release — the source for
/// embedded cover extraction. None when the release has no files.
pub fn representative_file(
    conn: &Connection,
    release_mbid: &str,
) -> anyhow::Result<Option<String>> {
    let path: Option<String> = conn.query_row(
        "SELECT MIN(f.path) FROM track t JOIN file f ON f.track_id = t.id \
         WHERE t.release_mbid = ?1",
        [release_mbid],
        |r| r.get(0),
    )?;
    Ok(path)
}

/// The release-group MBID for a release (for the CAA release-group fallback).
pub fn release_group_mbid(
    conn: &Connection,
    release_mbid: &str,
) -> anyhow::Result<Option<String>> {
    let rg: Option<Option<String>> = conn
        .query_row(
            "SELECT release_group_mbid FROM release WHERE mbid = ?1",
            [release_mbid],
            |r| r.get(0),
        )
        .optional()?;
    Ok(rg.flatten())
}

/// The (release_mbid, release_group_mbid) backing a file path. None when the
/// path is not in the catalog.
pub fn release_and_group_for_path(
    conn: &Connection,
    file_path: &str,
) -> anyhow::Result<Option<(String, Option<String>)>> {
    let row = conn
        .query_row(
            "SELECT t.release_mbid, r.release_group_mbid \
             FROM file f \
             JOIN track t ON t.id = f.track_id \
             JOIN release r ON r.mbid = t.release_mbid \
             WHERE f.path = ?1 LIMIT 1",
            [file_path],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    Ok(row)
}
