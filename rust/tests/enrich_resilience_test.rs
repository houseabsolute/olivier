use rust_lib_olivier::db::open;
use rust_lib_olivier::decision_log::DecisionLog;
use rust_lib_olivier::enrich::client::MbClient;
use rust_lib_olivier::enrich::http::{MbHttp, MbResponse};
use rust_lib_olivier::enrich::run::{enrich, enrich_artist};

// ---- FakeHttp (mirrors the one in enrich_test.rs; records calls) ----
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

fn artist_url(mbid: &str) -> String {
    format!("https://musicbrainz.org/ws/2/artist/{mbid}?inc=aliases&fmt=json")
}

fn seed_artist(conn: &rusqlite::Connection, mbid: &str) {
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES (?1,?1,?1)",
        [mbid],
    )
    .unwrap();
    let rel = format!("rel-{mbid}");
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES (?1,?2,'T')",
        [&rel, &mbid.to_string()],
    )
    .unwrap();
}

#[tokio::test]
async fn one_bad_artist_is_logged_and_skipped_pass_succeeds() {
    let conn = open(":memory:").unwrap();
    let mbid = "00000000-0000-0000-0000-000000000001";
    seed_artist(&conn, mbid);
    let http = FakeHttp::new().with(&artist_url(mbid), 400, "{\"error\":\"Invalid mbid.\"}");
    let client = MbClient::new(http);

    let logdir = std::env::temp_dir().join(format!("olivier_enrich_res_{}", std::process::id()));
    std::fs::create_dir_all(&logdir).unwrap();
    let log = DecisionLog::to_path(Some(logdir.join("import-log.log")));

    let res = enrich(&conn, &client, true, &log, |_p| true).await;
    assert!(
        res.is_ok(),
        "one bad artist must not abort the pass: {res:?}"
    );

    let logged = std::fs::read_to_string(logdir.join("import-log.log")).unwrap();
    assert!(logged.contains("ERROR"), "error logged: {logged}");
    assert!(logged.contains(mbid), "names the bad artist: {logged}");
    assert!(
        logged.contains("Invalid mbid."),
        "includes MB's body: {logged}"
    );
    std::fs::remove_dir_all(&logdir).ok();
}

#[tokio::test]
async fn circuit_breaker_aborts_after_more_than_ten_errors() {
    let conn = open(":memory:").unwrap();
    let mut http = FakeHttp::new();
    for i in 1..=11 {
        let mbid = format!("00000000-0000-0000-0000-{i:012}");
        seed_artist(&conn, &mbid);
        http = http.with(&artist_url(&mbid), 400, "nope");
    }
    let client = MbClient::new(http);
    let log = DecisionLog::to_path(None);

    let res = enrich(&conn, &client, true, &log, |_p| true).await;
    assert!(res.is_err(), "should abort once >10 errors pile up");
    assert!(format!("{}", res.unwrap_err()).contains("aborted"));
}

#[tokio::test]
async fn already_enriched_data_is_not_refetched_on_resume() {
    let conn = open(":memory:").unwrap();
    let ambid = "00000000-0000-0000-0000-0000000000aa";
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name,name_original) VALUES (?1,'A','A','エー')",
        [ambid],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R',?1,'T')",
        [ambid],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,recording_mbid,disc,position,title) VALUES (1,'R','REC',1,1,'t')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(id,path,mtime,size,track_id,enriched,added_at) VALUES (1,'/m/a.flac',0,0,1,1,0)",
        [],
    )
    .unwrap();

    let http = FakeHttp::new(); // no canned responses — any fetch would error
    let client = MbClient::new(http);
    let res = enrich(&conn, &client, false, &DecisionLog::to_path(None), |_p| {
        true
    })
    .await;

    assert!(
        res.is_ok(),
        "resume over fully-enriched data is a clean no-op: {res:?}"
    );
    assert!(
        client.http().calls.borrow().is_empty(),
        "already-enriched artist+release must not be re-fetched: {:?}",
        client.http().calls.borrow()
    );
}

#[tokio::test]
async fn malformed_mbid_is_skipped_not_queried() {
    let conn = open(":memory:").unwrap();
    // A split-release album-artist stored as two NUL-joined MBIDs ("k. / Low")
    // that predates tag sanitization. \x00 is NUL (written as \x00 not \0 to
    // avoid clippy's octal_escapes lint when followed by digits).
    let garbage = "04816b1b-e203-4917-b4a1-8c31ced2eb82\x0042faad37-8aaa-42e4-a300-5a7dae79ed24";
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES (?1,'k. / Low','k. / Low')",
        [garbage],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R',?1,'Split')",
        [garbage],
    )
    .unwrap();

    let http = FakeHttp::new(); // records calls; no canned responses
    let client = MbClient::new(http);
    let logdir = std::env::temp_dir().join(format!("olivier_malformed_{}", std::process::id()));
    std::fs::create_dir_all(&logdir).unwrap();
    let log = DecisionLog::to_path(Some(logdir.join("import-log.log")));

    let res = enrich(&conn, &client, true, &log, |_p| true).await;

    assert!(
        res.is_ok(),
        "a malformed mbid must be skipped, not abort: {res:?}"
    );
    assert!(
        client.http().calls.borrow().is_empty(),
        "malformed mbid must NOT be queried: {:?}",
        client.http().calls.borrow()
    );
    let logged = std::fs::read_to_string(logdir.join("import-log.log")).unwrap();
    assert!(logged.contains("malformed MBID"), "logged: {logged}");
    std::fs::remove_dir_all(&logdir).ok();
}

#[tokio::test]
async fn single_entity_refetch_surfaces_its_failure() {
    // A deliberate right-click "Re-fetch" of one artist must return Err on
    // failure (so the global guard shows a snackbar) — not silently log+Ok the
    // way a bulk-library pass skips a bad entity.
    let conn = open(":memory:").unwrap();
    let mbid = "00000000-0000-0000-0000-0000000000bb";
    seed_artist(&conn, mbid);
    let http = FakeHttp::new().with(&artist_url(mbid), 400, "{\"error\":\"Invalid mbid.\"}");
    let client = MbClient::new(http);

    let res = enrich_artist(&conn, &client, mbid, &DecisionLog::to_path(None), |_p| true).await;
    assert!(
        res.is_err(),
        "a single-entity re-fetch failure must surface as Err: {res:?}"
    );
}
