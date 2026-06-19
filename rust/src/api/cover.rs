use crate::db;
use crate::enrich::http::ReqwestHttp;
use crate::settings;

/// Current-thread runtime that drives a cover fetch. `enable_all()` turns on IO
/// (reqwest opens a TCP connection to the Cover Art Archive) and time. Mirrors
/// the enrichment runtime; the non-`Send` `Connection` can't cross frb's
/// executor, so the async resolver is driven via `block_on`.
fn cover_runtime() -> std::io::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
}

/// Resolve the cover for an album (release): embedded art from a representative
/// file -> Cover Art Archive -> None. Returns a cached image path or None.
pub fn cover_for_release(
    db_path: String,
    release_mbid: String,
    cache_dir: String,
) -> anyhow::Result<Option<String>> {
    let conn = db::open(&db_path)?;
    let email = settings::get_setting_or_default(&conn, "mb_contact_email")?;
    let http = ReqwestHttp::new(env!("CARGO_PKG_VERSION"), &email)?;
    let rep = crate::cover::representative_file(&conn, &release_mbid)?;
    let rg = crate::cover::release_group_mbid(&conn, &release_mbid)?;
    let rt = cover_runtime()?;
    rt.block_on(crate::cover::resolve_cover(
        &http,
        rep.as_deref(),
        &release_mbid,
        rg.as_deref(),
        &cache_dir,
    ))
}

/// Resolve the cover for the album a given file belongs to (the now-playing
/// track). Falls back to the file's own embedded art if the path is not in the
/// catalog.
pub fn cover_for_path(
    db_path: String,
    file_path: String,
    cache_dir: String,
) -> anyhow::Result<Option<String>> {
    let conn = db::open(&db_path)?;
    let email = settings::get_setting_or_default(&conn, "mb_contact_email")?;
    let http = ReqwestHttp::new(env!("CARGO_PKG_VERSION"), &email)?;
    match crate::cover::release_and_group_for_path(&conn, &file_path)? {
        Some((release_mbid, rg)) => {
            let rt = cover_runtime()?;
            rt.block_on(crate::cover::resolve_cover(
                &http,
                Some(&file_path),
                &release_mbid,
                rg.as_deref(),
                &cache_dir,
            ))
        }
        None => Ok(crate::tags::extract_cover_to(&file_path, &cache_dir).unwrap_or(None)),
    }
}
