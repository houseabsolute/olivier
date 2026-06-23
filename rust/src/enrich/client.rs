use std::time::Duration;

use rusqlite::{Connection, OptionalExtension};

use crate::enrich::http::MbHttp;
use crate::enrich::model::{MbArtist, MbRelease, MbReleaseBrowse};

const BASE: &str = "https://musicbrainz.org/ws/2";
const ARTIST_INC: &str = "aliases";
const RELEASE_INC: &str = "recordings+release-groups+artist-credits";
/// The release-group browse pulls every edition's full tracklist (each track's
/// `recording.id`) so sibling editions can be classified and their titles joined
/// to our tracks by recording MBID.
const BROWSE_INC: &str = "recordings";
/// MusicBrainz rate limit is 1 req/s; space ≥1.05 s (Appendix B).
const MIN_SPACING: Duration = Duration::from_millis(1050);
const MAX_503_RETRIES: u32 = 5;

/// Abstracts "wait until it's safe to make the next request" and "sleep for a
/// backoff" so tests run instantly. Production uses real wall-clock sleeps.
#[async_trait::async_trait(?Send)]
pub trait Pacer {
    async fn pace(&self);
    async fn backoff(&self, attempt: u32);
}

/// Real pacer: enforces MIN_SPACING between calls + exponential backoff.
pub struct WallClockPacer {
    last: std::cell::RefCell<Option<std::time::Instant>>,
}
impl Default for WallClockPacer {
    fn default() -> Self {
        Self {
            last: std::cell::RefCell::new(None),
        }
    }
}
#[async_trait::async_trait(?Send)]
impl Pacer for WallClockPacer {
    async fn pace(&self) {
        let wait = {
            let last = self.last.borrow();
            last.map(|t| MIN_SPACING.saturating_sub(t.elapsed()))
        };
        if let Some(w) = wait {
            if !w.is_zero() {
                tokio::time::sleep(w).await;
            }
        }
        *self.last.borrow_mut() = Some(std::time::Instant::now());
    }
    async fn backoff(&self, attempt: u32) {
        // 1s, 2s, 4s, 8s, 16s.
        let secs = 1u64 << attempt.min(4);
        tokio::time::sleep(Duration::from_secs(secs)).await;
    }
}

/// No-op pacer for tests.
pub struct NoopPacer;
#[async_trait::async_trait(?Send)]
impl Pacer for NoopPacer {
    async fn pace(&self) {}
    async fn backoff(&self, _attempt: u32) {}
}

pub struct MbClient<H: MbHttp, P: Pacer = WallClockPacer> {
    http: H,
    pacer: P,
}

impl<H: MbHttp> MbClient<H, NoopPacer> {
    /// Test constructor: no real sleeping.
    pub fn new(http: H) -> Self {
        Self {
            http,
            pacer: NoopPacer,
        }
    }
}

impl<H: MbHttp, P: Pacer> MbClient<H, P> {
    pub fn with_pacer(http: H, pacer: P) -> Self {
        Self { http, pacer }
    }
    pub fn http(&self) -> &H {
        &self.http
    }

    pub async fn fetch_artist(&self, conn: &Connection, mbid: &str) -> anyhow::Result<MbArtist> {
        let url = format!("{BASE}/artist/{mbid}?inc={ARTIST_INC}&fmt=json");
        let body = self
            .get_cached(conn, "artist", mbid, ARTIST_INC, &url)
            .await?;
        Ok(serde_json::from_str(&body)?)
    }

    pub async fn fetch_release(&self, conn: &Connection, mbid: &str) -> anyhow::Result<MbRelease> {
        let url = format!("{BASE}/release/{mbid}?inc={RELEASE_INC}&fmt=json");
        let body = self
            .get_cached(conn, "release", mbid, RELEASE_INC, &url)
            .await?;
        Ok(serde_json::from_str(&body)?)
    }

    /// Browse every edition in a release group (one page of ≤100), each carrying
    /// its full tracklist with per-track `recording.id` and the edition's
    /// `text-representation`. The `inc_set` cache key embeds the `inc` + offset so
    /// each page of the browse is cached independently.
    pub async fn browse_release_group(
        &self,
        conn: &Connection,
        rg_mbid: &str,
        offset: u32,
    ) -> anyhow::Result<MbReleaseBrowse> {
        let inc = format!("{BROWSE_INC}:offset={offset}");
        let url = format!(
            "{BASE}/release?release-group={rg_mbid}&inc={BROWSE_INC}&limit=100&offset={offset}&fmt=json"
        );
        let body = self
            .get_cached(conn, "release-browse", rg_mbid, &inc, &url)
            .await?;
        Ok(serde_json::from_str(&body)?)
    }

    /// Whether this artist's response is already in `mb_cache` (so the next
    /// enrich serves it without a network fetch). For FETCH/CACHE logging.
    pub fn is_cached_artist(&self, conn: &Connection, mbid: &str) -> bool {
        self.cache_get(conn, "artist", mbid, ARTIST_INC)
            .map(|o| o.is_some())
            .unwrap_or(false)
    }

    /// Whether this release's response is already in `mb_cache`.
    pub fn is_cached_release(&self, conn: &Connection, mbid: &str) -> bool {
        self.cache_get(conn, "release", mbid, RELEASE_INC)
            .map(|o| o.is_some())
            .unwrap_or(false)
    }

    /// Cache read-through. On miss: pace, fetch (retrying 503), store, return.
    async fn get_cached(
        &self,
        conn: &Connection,
        entity_type: &str,
        mbid: &str,
        inc_set: &str,
        url: &str,
    ) -> anyhow::Result<String> {
        if let Some(body) = self.cache_get(conn, entity_type, mbid, inc_set)? {
            return Ok(body);
        }
        let body = self.fetch_with_backoff(url).await?;
        self.cache_put(conn, entity_type, mbid, inc_set, &body)?;
        Ok(body)
    }

    async fn fetch_with_backoff(&self, url: &str) -> anyhow::Result<String> {
        let mut attempt = 0;
        loop {
            self.pacer.pace().await;
            let resp = self.http.get(url).await?;
            match resp.status {
                200 => return Ok(resp.body),
                503 if attempt < MAX_503_RETRIES => {
                    self.pacer.backoff(attempt).await;
                    attempt += 1;
                }
                s => {
                    let snippet: String = resp.body.chars().take(200).collect();
                    return Err(anyhow::anyhow!("MB returned HTTP {s} for {url}: {snippet}"));
                }
            }
        }
    }

    fn cache_get(
        &self,
        conn: &Connection,
        entity_type: &str,
        mbid: &str,
        inc_set: &str,
    ) -> anyhow::Result<Option<String>> {
        let body = conn
            .query_row(
                "SELECT json FROM mb_cache WHERE entity_type=?1 AND mbid=?2 AND inc_set=?3",
                rusqlite::params![entity_type, mbid, inc_set],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(body)
    }

    fn cache_put(
        &self,
        conn: &Connection,
        entity_type: &str,
        mbid: &str,
        inc_set: &str,
        json: &str,
    ) -> anyhow::Result<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs() as i64;
        conn.execute(
            "INSERT INTO mb_cache(entity_type, mbid, inc_set, json, fetched_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(entity_type, mbid, inc_set)
               DO UPDATE SET json=excluded.json, fetched_at=excluded.fetched_at",
            rusqlite::params![entity_type, mbid, inc_set, json, now],
        )?;
        Ok(())
    }
}
