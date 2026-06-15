// ── Recorded MB fixture MBIDs (captured Task 5) ──────────────────────────
// artist (Shiina Ringo):     9e414497-23b7-4ab7-9ec6-8ea9864c9e87
//   NOTE: the plan text listed MBID 9e414497-1f44-4f0c-b031-f01923a3c5d2 which
//   does not exist on MusicBrainz; the correct MBID was looked up via the
//   search API and verified to be 9e414497-23b7-4ab7-9ec6-8ea9864c9e87.
// release (無罪モラトリアム): 5588dfca-c011-4f66-9899-dcaa5f4efed5
// release-group:             923db16c-6620-3e44-ba00-a20745c6a957
// pseudo translit (romaji):  3e88897d-8c4f-4895-a28b-ccb933336c1b  text-representation: script=Latn language=jpn
// pseudo translate (en):     9cda9af0-f295-4f20-a470-8b7d2ce0c4b8  text-representation: script=Latn language=eng
// pseudo discovery path:     DIRECT transl-tracklisting rel on the main release
//                            (NOT the release-group browse fallback)
// ─────────────────────────────────────────────────────────────────────────

use rust_lib_olivier::db::open;
use rust_lib_olivier::enrich::http::{MbHttp, MbResponse};

/// Test double: serves canned bodies by URL, records the calls made.
struct FakeHttp {
    responses: std::collections::HashMap<String, MbResponse>,
    calls: std::cell::RefCell<Vec<String>>,
}
impl FakeHttp {
    fn new() -> Self {
        Self {
            responses: Default::default(),
            calls: Default::default(),
        }
    }
    fn with(mut self, url: &str, status: u16, body: &str) -> Self {
        self.responses.insert(
            url.to_string(),
            MbResponse {
                status,
                body: body.to_string(),
            },
        );
        self
    }
}
#[async_trait::async_trait(?Send)]
impl MbHttp for FakeHttp {
    async fn get(&self, url: &str) -> anyhow::Result<MbResponse> {
        self.calls.borrow_mut().push(url.to_string());
        self.responses
            .get(url)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("no canned response for {url}"))
    }
}

#[tokio::test]
async fn fake_http_serves_canned_body() {
    let http = FakeHttp::new().with("http://x/a", 200, "{\"ok\":true}");
    let resp = http.get("http://x/a").await.unwrap();
    assert_eq!(resp.status, 200);
    assert_eq!(resp.body, "{\"ok\":true}");
    assert_eq!(http.calls.borrow().as_slice(), ["http://x/a"]);
}

#[test]
fn migration_creates_enrichment_tables() {
    let conn = open(":memory:").unwrap();
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table'
             AND name IN ('setting','mb_cache','release_title_alt','track_title_alt')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 4);

    // artist.transliteration + artist.sort_name_embedded columns added.
    let cols: i64 = conn
        .query_row(
            "SELECT count(*) FROM pragma_table_info('artist')
             WHERE name IN ('transliteration','sort_name_embedded')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(cols, 2);
}
