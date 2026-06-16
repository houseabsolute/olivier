use crate::db;
use crate::enrich::client::{MbClient, WallClockPacer};
use crate::enrich::http::ReqwestHttp;
use crate::enrich::progress::EnrichProgress;
use crate::enrich::run;
use crate::frb_generated::StreamSink;
use crate::settings;

/// Stream enrichment progress to Dart. `force=false` is the resumable auto path
/// (skips already-enriched files + cached entities); `force=true` re-runs the
/// logic over everything, still reading entity JSON from the cache.
///
/// SYNC fn (like `scan_library`): dispatched on frb's worker-thread path. The
/// async enrichment core is driven by a private current-thread tokio runtime
/// via `block_on` — NOT frb's async executor, which would reject the non-`Send`
/// `Connection`/`RefCell`/`?Send` types this design holds across `.await`.
pub fn enrich_library(
    db_path: String,
    force: bool,
    sink: StreamSink<EnrichProgress>,
) -> anyhow::Result<()> {
    let conn = db::open(&db_path)?;
    let email = settings::get_setting_or_default(&conn, "mb_contact_email")?;
    let http = ReqwestHttp::new(env!("CARGO_PKG_VERSION"), &email)?;
    let client = MbClient::with_pacer(http, WallClockPacer::default());

    // Private current-thread runtime: single thread, never crosses an executor
    // boundary, so `Connection`/`RefCell`/`?Send` stay valid. `enable_time()`
    // is required because the pacer calls `tokio::time::sleep`. `run::enrich`
    // takes `&Connection` (its per-release transactions use the
    // `conn.unchecked_transaction()` pattern, which works on `&self`).
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()?;
    rt.block_on(run::enrich(&conn, &client, force, |p| sink.add(p).is_ok()))
}

/// Empty the MusicBrainz response cache so the next enrich refetches from the
/// network (spec §4: manual refresh only).
pub fn clear_mb_cache(db_path: String) -> anyhow::Result<()> {
    let conn = db::open(&db_path)?;
    conn.execute("DELETE FROM mb_cache", [])?;
    Ok(())
}
