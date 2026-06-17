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
    // boundary, so `Connection`/`RefCell`/`?Send` stay valid.
    let rt = enrich_runtime()?;
    rt.block_on(run::enrich(&conn, &client, force, |p| sink.add(p).is_ok()))
}

/// Build the current-thread runtime that drives enrichment. `enable_all()` turns
/// on BOTH IO (reqwest/hyper open a TCP connection to MusicBrainz) AND time (the
/// pacer calls `tokio::time::sleep`). `enable_time()` alone panics with "A Tokio
/// 1.x context was found, but IO is disabled" the instant reqwest tries to
/// connect — which the mocked-HTTP tests never exercise.
fn enrich_runtime() -> std::io::Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
}

/// Empty the MusicBrainz response cache so the next enrich refetches from the
/// network (spec §4: manual refresh only).
pub fn clear_mb_cache(db_path: String) -> anyhow::Result<()> {
    let conn = db::open(&db_path)?;
    conn.execute("DELETE FROM mb_cache", [])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::enrich::http::{MbHttp, ReqwestHttp};

    /// Regression: the enrichment runtime must enable IO, or `reqwest` panics with
    /// "A Tokio 1.x context was found, but IO is disabled" the first time it opens
    /// a connection — a bug the mocked-HTTP tests can't catch. Drive a real
    /// `reqwest` request through the runtime to a closed loopback port: with IO
    /// enabled it returns a connection error; with IO disabled it panics.
    #[test]
    fn enrich_runtime_enables_io_for_reqwest() {
        let rt = super::enrich_runtime().unwrap();
        let http = ReqwestHttp::new("test", "test@example.com").unwrap();
        let result = rt.block_on(http.get("http://127.0.0.1:1/"));
        assert!(result.is_err(), "expected a connection error, not success");
    }
}
