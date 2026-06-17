// ── Recorded MB fixture MBIDs (captured Task 5) ──────────────────────────
// artist (Shiina Ringo):     9e414497-23b7-4ab7-9ec6-8ea9864c9e87
//   NOTE: the plan text listed MBID 9e414497-1f44-4f0c-b031-f01923a3c5d2 which
//   does not exist on MusicBrainz; the correct MBID was looked up via the
//   search API and verified to be 9e414497-23b7-4ab7-9ec6-8ea9864c9e87.
// release (無罪モラトリアム): 5588dfca-c011-4f66-9899-dcaa5f4efed5
// release-group:             923db16c-6620-3e44-ba00-a20745c6a957
// sibling translit (romaji): 3e88897d-8c4f-4895-a28b-ccb933336c1b  text-representation: script=Latn language=jpn
// sibling translate (en):    9cda9af0-f295-4f20-a470-8b7d2ce0c4b8  text-representation: script=Latn language=eng
// alt discovery path:        release-group BROWSE (inc=recordings). Title alts
//                            come from sibling editions in the group (a
//                            Pseudo-Release IS one such Latin-script sibling),
//                            joined to our tracks by recording MBID.
// ─────────────────────────────────────────────────────────────────────────

use rust_lib_olivier::db::open;
use rust_lib_olivier::enrich::http::{MbHttp, MbResponse};
use rust_lib_olivier::enrich::model::{MbAlias, MbArtist, MbRelease, MbTextRepresentation};
use rust_lib_olivier::enrich::run::enrich;
use rust_lib_olivier::enrich::select::{
    classify_alt, classify_from_text_representation, classify_pseudo, select_transliteration,
    AltKind,
};
use rust_lib_olivier::enrich::store;

fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!(
        "{}/tests/fixtures/mb/{name}",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

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
fn parses_artist_aliases_fixture() {
    let a: MbArtist = serde_json::from_str(&fixture("artist_9e414497_aliases.json")).unwrap();
    assert!(!a.aliases.is_empty());
    assert!(a
        .aliases
        .iter()
        .any(|al| al.alias_type.as_deref() == Some("Artist name")));
}

#[test]
fn parses_release_fixture_with_recordings_and_rels() {
    let r: MbRelease = serde_json::from_str(&fixture("release_muzai.json")).unwrap();
    // release-group first-release-date is present (original year source).
    assert!(r
        .release_group
        .as_ref()
        .and_then(|g| g.first_release_date.as_deref())
        .is_some());
    // recordings present on media tracks.
    assert!(r
        .media
        .iter()
        .flat_map(|m| &m.tracks)
        .any(|t| t.recording.is_some()));
    // at least one relation carrying a target release.
    assert!(r.relations.iter().any(|rel| rel.release.is_some()));
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

// ── §5.1 artist-alias selection tests ────────────────────────────────────

fn alias(name: &str, sort: &str, locale: Option<&str>, primary: bool, ty: &str) -> MbAlias {
    MbAlias {
        name: name.into(),
        sort_name: Some(sort.into()),
        locale: locale.map(str::to_string),
        primary: Some(primary),
        alias_type: Some(ty.into()),
    }
}

fn artist_with(sort: &str, aliases: Vec<MbAlias>) -> MbArtist {
    MbArtist {
        id: "x".into(),
        name: "椎名林檎".into(),
        sort_name: sort.into(),
        aliases,
    }
}

#[test]
fn prefers_en_primary_artist_name() {
    let a = artist_with(
        "Sheena, Ringo",
        vec![
            alias(
                "Sheena Ringo",
                "Sheena, Ringo",
                Some("en"),
                false,
                "Artist name",
            ),
            alias(
                "Ringo Sheena",
                "Sheena, Ringo",
                Some("en"),
                true,
                "Artist name",
            ),
            alias("椎名林檎", "椎名林檎", Some("ja"), true, "Artist name"),
        ],
    );
    let chosen = select_transliteration(&a).unwrap();
    assert_eq!(chosen.name, "Ringo Sheena");
    assert_eq!(chosen.sort_name, "Sheena, Ringo");
}

#[test]
fn skips_legal_name_and_search_hint() {
    let a = artist_with(
        "Sheena, Ringo",
        vec![
            alias(
                "Yumiko Shiina",
                "Shiina, Yumiko",
                Some("en"),
                true,
                "Legal name",
            ),
            alias("Ringo", "Ringo", Some("en"), false, "Search hint"),
            alias(
                "Ringo Sheena",
                "Sheena, Ringo",
                Some("en"),
                false,
                "Artist name",
            ),
        ],
    );
    assert_eq!(select_transliteration(&a).unwrap().name, "Ringo Sheena");
}

#[test]
fn tie_break_by_name_ascending() {
    // Two en+primary "Artist name" candidates -> name asc picks "Ringo Sheena".
    let a = artist_with(
        "Sheena, Ringo",
        vec![
            alias(
                "Sheena Ringo",
                "Sheena, Ringo",
                Some("en"),
                true,
                "Artist name",
            ),
            alias(
                "Ringo Sheena",
                "Sheena, Ringo",
                Some("en"),
                true,
                "Artist name",
            ),
        ],
    );
    assert_eq!(select_transliteration(&a).unwrap().name, "Ringo Sheena");
}

#[test]
fn falls_back_to_any_en_then_entity_sort_name() {
    // No primary -> any en "Artist name".
    let a1 = artist_with(
        "Sheena, Ringo",
        vec![alias(
            "Ringo Sheena",
            "Sheena, Ringo",
            Some("en"),
            false,
            "Artist name",
        )],
    );
    assert_eq!(select_transliteration(&a1).unwrap().name, "Ringo Sheena");

    // No en alias at all -> entity sort-name, name == sort-name.
    let a2 = artist_with(
        "Sheena, Ringo",
        vec![alias(
            "椎名林檎",
            "椎名林檎",
            Some("ja"),
            true,
            "Artist name",
        )],
    );
    let chosen = select_transliteration(&a2).unwrap();
    assert_eq!(chosen.name, "Sheena, Ringo");
    assert_eq!(chosen.sort_name, "Sheena, Ringo");
    assert!(chosen.from_entity_sort_name);
}

#[test]
fn selection_is_deterministic_and_order_independent() {
    // Property: reversing alias order doesn't change the chosen name.
    let aliases = vec![
        alias(
            "Sheena Ringo",
            "Sheena, Ringo",
            Some("en"),
            true,
            "Artist name",
        ),
        alias(
            "Ringo Sheena",
            "Sheena, Ringo",
            Some("en"),
            true,
            "Artist name",
        ),
        alias("椎名林檎", "椎名林檎", Some("ja"), true, "Artist name"),
    ];
    let a_forward = artist_with("Sheena, Ringo", aliases.clone());
    let mut reversed = aliases;
    reversed.reverse();
    let a_reversed = artist_with("Sheena, Ringo", reversed);

    let chosen_forward = select_transliteration(&a_forward).unwrap();
    let chosen_reversed = select_transliteration(&a_reversed).unwrap();

    assert_eq!(chosen_forward.name, chosen_reversed.name);
    assert_eq!(chosen_forward.sort_name, chosen_reversed.sort_name);
    // Calling twice on same artist is also consistent.
    assert_eq!(
        select_transliteration(&a_forward).unwrap().name,
        chosen_forward.name
    );
}

// ── MbClient tests (Task 10) ─────────────────────────────────────────────

/// Variant of FakeHttp that returns 503 for the first N calls to a URL,
/// then 200 with the provided body.
struct FlakyHttp {
    url: String,
    fail_count: u32,
    success_body: String,
    calls: std::cell::RefCell<u32>,
}
impl FlakyHttp {
    fn new(url: &str, fail_count: u32, body: &str) -> Self {
        Self {
            url: url.to_string(),
            fail_count,
            success_body: body.to_string(),
            calls: std::cell::RefCell::new(0),
        }
    }
    fn call_count(&self) -> u32 {
        *self.calls.borrow()
    }
}
#[async_trait::async_trait(?Send)]
impl MbHttp for FlakyHttp {
    async fn get(&self, url: &str) -> anyhow::Result<MbResponse> {
        assert_eq!(url, self.url);
        let count = {
            let mut c = self.calls.borrow_mut();
            *c += 1;
            *c
        };
        if count <= self.fail_count {
            Ok(MbResponse {
                status: 503,
                body: "Service Unavailable".to_string(),
            })
        } else {
            Ok(MbResponse {
                status: 200,
                body: self.success_body.clone(),
            })
        }
    }
}

#[tokio::test]
async fn fetch_reads_through_and_writes_cache() {
    let conn = open(":memory:").unwrap();
    let body = fixture("artist_9e414497_aliases.json");
    let mbid = "9e414497-23b7-4ab7-9ec6-8ea9864c9e87";
    let url = format!("https://musicbrainz.org/ws/2/artist/{mbid}?inc=aliases&fmt=json");
    let http = FakeHttp::new().with(&url, 200, &body);

    let client = rust_lib_olivier::enrich::client::MbClient::new(http);
    let a = client.fetch_artist(&conn, mbid).await.unwrap();
    assert!(!a.aliases.is_empty());

    // Cached: a SECOND fetch makes no new HTTP call.
    let _ = client.fetch_artist(&conn, mbid).await.unwrap();
    assert_eq!(
        client.http().calls.borrow().len(),
        1,
        "second fetch must hit cache"
    );

    // mb_cache row exists.
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM mb_cache WHERE entity_type='artist'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 1);
}

#[tokio::test]
async fn retries_on_503_then_succeeds() {
    let conn = open(":memory:").unwrap();
    let url = "https://musicbrainz.org/ws/2/artist/abc?inc=aliases&fmt=json";
    // FlakyHttp returns 503 the first 2 calls, then 200.
    let http = FlakyHttp::new(url, 2, &fixture("artist_9e414497_aliases.json"));
    let client = rust_lib_olivier::enrich::client::MbClient::new(http);
    let a = client.fetch_artist(&conn, "abc").await.unwrap();
    assert!(!a.aliases.is_empty());
    assert_eq!(client.http().call_count(), 3); // 2 failures + 1 success
}

#[tokio::test]
async fn url_contains_expected_inc_params() {
    let artist_mbid = "9e414497-23b7-4ab7-9ec6-8ea9864c9e87";
    let release_mbid = "5588dfca-c011-4f66-9899-dcaa5f4efed5";

    // Check artist URL contains inc=aliases&fmt=json.
    let conn = open(":memory:").unwrap();
    let artist_url =
        format!("https://musicbrainz.org/ws/2/artist/{artist_mbid}?inc=aliases&fmt=json");
    let http = FakeHttp::new().with(&artist_url, 200, &fixture("artist_9e414497_aliases.json"));
    let client = rust_lib_olivier::enrich::client::MbClient::new(http);
    let _ = client.fetch_artist(&conn, artist_mbid).await.unwrap();
    // Clone the URL string out of the borrow before any later await.
    let artist_call = client.http().calls.borrow()[0].clone();
    assert!(
        artist_call.contains("inc=aliases"),
        "artist URL must contain inc=aliases"
    );
    assert!(
        artist_call.contains("fmt=json"),
        "artist URL must contain fmt=json"
    );

    // Check release URL contains recordings+release-rels bundle.
    let conn2 = open(":memory:").unwrap();
    let release_url = format!(
        "https://musicbrainz.org/ws/2/release/{release_mbid}?inc=recordings+release-rels+release-groups+artist-credits&fmt=json"
    );
    let http2 = FakeHttp::new().with(&release_url, 200, &fixture("release_muzai.json"));
    let client2 = rust_lib_olivier::enrich::client::MbClient::new(http2);
    let _ = client2.fetch_release(&conn2, release_mbid).await.unwrap();
    let release_call = client2.http().calls.borrow()[0].clone();
    assert!(
        release_call.contains("recordings"),
        "release URL must contain recordings"
    );
    assert!(
        release_call.contains("release-rels"),
        "release URL must contain release-rels"
    );
}

// ── Edition classification primitive (sibling-edition path) ───────────────

#[test]
fn classify_from_text_representation_is_the_edition_primitive() {
    // Latin script ⇒ transliteration.
    assert_eq!(
        classify_from_text_representation(Some(&MbTextRepresentation {
            script: Some("Latn".into()),
            language: Some("jpn".into()),
        })),
        Some(AltKind::Translit)
    );
    // English language ⇒ translation (an international edition / English pseudo).
    assert_eq!(
        classify_from_text_representation(Some(&MbTextRepresentation {
            script: Some("Latn".into()),
            language: Some("eng".into()),
        })),
        Some(AltKind::Translate)
    );
    // A non-Latn, non-eng edition (e.g. Jpan/jpn) classifies as Translate; the
    // classifier does NOT skip it. Skipping a same-script sibling is the job of
    // the `apply_edition_alts` guard, not this classifier.
    assert_eq!(
        classify_from_text_representation(Some(&MbTextRepresentation {
            script: Some("Jpan".into()),
            language: Some("jpn".into()),
        })),
        Some(AltKind::Translate)
    );
    // No script + non-eng language ⇒ None (caller skips the edition).
    assert_eq!(
        classify_from_text_representation(Some(&MbTextRepresentation {
            script: None,
            language: Some("jpn".into()),
        })),
        None
    );
    assert_eq!(classify_from_text_representation(None), None);
}

// ── Alt-kind classification tests (Task 9) ────────────────────────────────

fn pseudo_with_text_rep(title: &str, script: Option<&str>, language: Option<&str>) -> MbRelease {
    MbRelease {
        id: "p".into(),
        title: title.into(),
        date: None,
        text_representation: Some(MbTextRepresentation {
            script: script.map(str::to_string),
            language: language.map(str::to_string),
        }),
        release_group: None,
        media: vec![],
        relations: vec![],
    }
}

#[test]
fn classify_uses_text_representation_when_present() {
    // Latn script (romaji) => translit.
    assert_eq!(
        classify_pseudo(
            "無罪モラトリアム",
            &pseudo_with_text_rep("Muzai Moratorium", Some("Latn"), Some("jpn"))
        ),
        AltKind::Translit
    );
    // English language => translate even though script is Latn.
    assert_eq!(
        classify_pseudo(
            "無罪モラトリアム",
            &pseudo_with_text_rep("Innocence Moratorium", Some("Latn"), Some("eng"))
        ),
        AltKind::Translate
    );
    // Non-Latn script => translate.
    assert_eq!(
        classify_pseudo(
            "無罪モラトリアム",
            &pseudo_with_text_rep("무죄 모라토리엄", Some("Hang"), Some("kor"))
        ),
        AltKind::Translate
    );
}

#[test]
fn classify_falls_back_to_title_heuristic_without_text_representation() {
    // text-representation absent (None) => deterministic title-pair fallback.
    // Rule: an all-ASCII pseudo of an original that has non-ASCII characters is a
    // romanization => Translit; otherwise Translate. The metadata-less fallback
    // can't tell a romanization from a translation, so a genuine English
    // translation only resolves to Translate via the primary language=eng path.

    // classify_pseudo with no text-representation falls through to classify_alt.
    let mut p = pseudo_with_text_rep("Muzai Moratorium", None, None);
    p.text_representation = None;
    assert_eq!(classify_pseudo("無罪モラトリアム", &p), AltKind::Translit);

    // ASCII pseudo of a non-ASCII original => romanization => Translit.
    assert_eq!(
        classify_alt("無罪モラトリアム", "Muzai Moratorium"),
        AltKind::Translit
    );
    // An English translation is also ASCII, so the metadata-less fallback can
    // only call it Translit; its Translate verdict comes from the primary
    // language=eng path, not here.
    assert_eq!(
        classify_alt("無罪モラトリアム", "Innocence Moratorium"),
        AltKind::Translit
    );
    // Non-ASCII pseudo (e.g. a Korean rendering) => not a romanization => Translate.
    assert_eq!(
        classify_alt("無罪モラトリアム", "무죄 모라토리엄"),
        AltKind::Translate
    );
    // All-ASCII original (nothing non-ASCII to romanize) => Translate.
    assert_eq!(
        classify_alt("Muzai Moratorium", "Innocence Moratorium"),
        AltKind::Translate
    );
}

// ── store.rs tests (Task 11) ──────────────────────────────────────────────

fn seed_one_release(conn: &rusqlite::Connection) {
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('art1','椎名林檎','椎名林檎')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release_group(mbid,title,first_release_date) VALUES ('rg1','無罪モラトリアム',NULL)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title,date) VALUES ('rel1','rg1','art1','無罪モラトリアム',NULL)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(release_mbid,recording_mbid,disc,position,title) VALUES ('rel1','rec1',1,1,'歌舞伎町の女王')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at) VALUES ('/m/a.flac',0,0,1,0)",
        [],
    )
    .unwrap();
}

#[test]
fn applies_artist_transliteration_and_sort_key() {
    let conn = open(":memory:").unwrap();
    seed_one_release(&conn);
    // Seeded sort_name is the embedded albumartistsort value "椎名林檎".
    store::apply_artist_transliteration(
        &conn,
        "art1",
        &rust_lib_olivier::enrich::select::ChosenAlias {
            name: "Ringo Sheena".into(),
            sort_name: "Sheena, Ringo".into(),
            from_entity_sort_name: false,
        },
        "椎名林檎",
    )
    .unwrap();
    let (translit, sort, embedded): (Option<String>, String, Option<String>) = conn
        .query_row(
            "SELECT transliteration, sort_name, sort_name_embedded FROM artist WHERE mbid='art1'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(translit.as_deref(), Some("Ringo Sheena"));
    assert_eq!(sort, "Sheena, Ringo");
    // The pre-enrichment embedded sort_name is preserved for the §6.1 tier-3 fallback.
    assert_eq!(embedded.as_deref(), Some("椎名林檎"));
    // The MusicBrainz original-script name is stored separately from `name`.
    let name_original: Option<String> = conn
        .query_row(
            "SELECT name_original FROM artist WHERE mbid='art1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(name_original.as_deref(), Some("椎名林檎"));

    // A re-enrich must NOT clobber the preserved embedded value.
    store::apply_artist_transliteration(
        &conn,
        "art1",
        &rust_lib_olivier::enrich::select::ChosenAlias {
            name: "Ringo Sheena".into(),
            sort_name: "Sheena, Ringo".into(),
            from_entity_sort_name: false,
        },
        "椎名林檎",
    )
    .unwrap();
    let embedded2: Option<String> = conn
        .query_row(
            "SELECT sort_name_embedded FROM artist WHERE mbid='art1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(embedded2.as_deref(), Some("椎名林檎"));
}

#[test]
fn applies_dates_from_release_and_group() {
    let conn = open(":memory:").unwrap();
    seed_one_release(&conn);
    store::apply_dates(
        &conn,
        "rel1",
        "rg1",
        "無罪モラトリアム",
        Some("1999-02-24"),
        Some("1999-02-24"),
    )
    .unwrap();
    let (orig, reissue): (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT rg.first_release_date, r.date FROM release r JOIN release_group rg ON rg.mbid=r.release_group_mbid WHERE r.mbid='rel1'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(orig.as_deref(), Some("1999-02-24"));
    assert_eq!(reissue.as_deref(), Some("1999-02-24"));
}

#[test]
fn original_year_lands_on_real_rg_when_catalog_rg_is_synthetic() {
    // The catalog release points at a synth:rg:… key (file tags lacked the RG
    // MBID). apply_dates must write the original year to the REAL RG from the
    // MB JSON and re-point the release, not to the synth key.
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('art1','椎名林檎','椎名林檎')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release_group(mbid,title) VALUES ('synth:rg:art1|無罪モラトリアム','無罪モラトリアム')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title,date) VALUES ('rel1','synth:rg:art1|無罪モラトリアム','art1','無罪モラトリアム',NULL)",
        [],
    )
    .unwrap();

    store::apply_dates(
        &conn,
        "rel1",
        "realrg1",
        "無罪モラトリアム",
        Some("1999-02-24"),
        Some("1999-02-24"),
    )
    .unwrap();

    // The release now points at the real RG, and the original year lives there.
    let (rg_mbid, orig): (String, Option<String>) = conn
        .query_row(
            "SELECT rg.mbid, rg.first_release_date
           FROM release r JOIN release_group rg ON rg.mbid = r.release_group_mbid
           WHERE r.mbid='rel1'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(rg_mbid, "realrg1");
    assert_eq!(orig.as_deref(), Some("1999-02-24"));
    // The synthetic RG did NOT receive the original year.
    let synth_date: Option<String> = conn
        .query_row(
            "SELECT first_release_date FROM release_group WHERE mbid='synth:rg:art1|無罪モラトリアム'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(synth_date, None);
}

#[test]
fn upserts_release_and_track_alts() {
    let conn = open(":memory:").unwrap();
    seed_one_release(&conn);
    store::upsert_release_alt(&conn, "rel1", AltKind::Translit, "Muzai Moratorium").unwrap();
    store::upsert_release_alt(&conn, "rel1", AltKind::Translate, "Innocence Moratorium").unwrap();
    store::upsert_track_alt(&conn, "rec1", AltKind::Translit, "Kabukichou no Joou").unwrap();
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM release_title_alt WHERE release_mbid='rel1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 2);
    // Re-applying the same kind overwrites, not duplicates.
    store::upsert_release_alt(&conn, "rel1", AltKind::Translit, "Muzai Moratorium 2").unwrap();
    let title: String = conn
        .query_row(
            "SELECT title FROM release_title_alt WHERE release_mbid='rel1' AND kind='translit'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(title, "Muzai Moratorium 2");
}

#[test]
fn marks_files_enriched_for_release() {
    let conn = open(":memory:").unwrap();
    seed_one_release(&conn);
    store::mark_release_files_enriched(&conn, "rel1").unwrap();
    let enriched: i64 = conn
        .query_row(
            "SELECT enriched FROM file WHERE path='/m/a.flac'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(enriched, 1);
}

// ── Task 13: end-to-end orchestration tests ───────────────────────────────

// Real MBIDs from the recorded fixtures:
const ARTIST_MBID: &str = "9e414497-23b7-4ab7-9ec6-8ea9864c9e87";
const RELEASE_MBID: &str = "5588dfca-c011-4f66-9899-dcaa5f4efed5";
const RELEASE_GROUP_MBID: &str = "923db16c-6620-3e44-ba00-a20745c6a957";
// recording MBID of 歌舞伎町の女王 (track 2 in the fixture)
const REC_KABUKI: &str = "4dd9d08d-376c-42b2-8b44-e3322ed657b7";

// URL patterns matching client.rs
const BASE: &str = "https://musicbrainz.org/ws/2";

fn artist_url() -> String {
    format!("{BASE}/artist/{ARTIST_MBID}?inc=aliases&fmt=json")
}
fn release_url() -> String {
    format!("{BASE}/release/{RELEASE_MBID}?inc=recordings+release-rels+release-groups+artist-credits&fmt=json")
}
/// Release-group browse (inc=recordings) — the alt-discovery path.
fn browse_url() -> String {
    format!("{BASE}/release?release-group={RELEASE_GROUP_MBID}&inc=recordings&limit=100&offset=0&fmt=json")
}

fn seed_taggable_catalog(conn: &rusqlite::Connection) {
    conn.execute(
        &format!(
            "INSERT INTO artist(mbid,name,sort_name) VALUES ('{}','椎名林檎','椎名林檎')",
            ARTIST_MBID
        ),
        [],
    )
    .unwrap();
    conn.execute(
        &format!(
            "INSERT INTO release_group(mbid,title) VALUES ('{}','無罪モラトリアム')",
            RELEASE_GROUP_MBID
        ),
        [],
    )
    .unwrap();
    conn.execute(
        &format!(
            "INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title) VALUES ('{}','{}','{}','無罪モラトリアム')",
            RELEASE_MBID, RELEASE_GROUP_MBID, ARTIST_MBID
        ),
        [],
    )
    .unwrap();
    // 歌舞伎町の女王 with its actual recording MBID from the fixture.
    conn.execute(
        &format!(
            "INSERT INTO track(release_mbid,recording_mbid,disc,position,title) VALUES ('{}','{}',1,1,'歌舞伎町の女王')",
            RELEASE_MBID, REC_KABUKI
        ),
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at,enriched) VALUES ('/m/a.flac',0,0,1,0,0)",
        [],
    )
    .unwrap();
}

#[tokio::test]
async fn enriches_catalog_end_to_end() {
    let conn = open(":memory:").unwrap();
    seed_taggable_catalog(&conn);

    // Alt-discovery path: browse the REAL release group (inc=recordings). The
    // browse fixture carries the Japanese original + a romaji (Latn/jpn) sibling
    // + an English (Latn/eng) sibling, all sharing the 歌舞伎町の女王 recording MBID.
    let http = FakeHttp::new()
        .with(&artist_url(), 200, &fixture("artist_9e414497_aliases.json"))
        .with(&release_url(), 200, &fixture("release_muzai.json"))
        .with(
            &browse_url(),
            200,
            &fixture("release_group_browse_muzai.json"),
        );
    let client = rust_lib_olivier::enrich::client::MbClient::new(http);

    let mut last: Option<rust_lib_olivier::enrich::progress::EnrichProgress> = None;
    enrich(&conn, &client, false, |p| {
        last = Some(p.clone());
        true
    })
    .await
    .unwrap();
    assert!(last.unwrap().done);

    // The alt path browses the REAL release group from the fetched JSON.
    assert!(
        client.http().calls.borrow().iter().any(|u| u
            .contains(&format!("release-group={RELEASE_GROUP_MBID}"))
            && u.contains("inc=recordings")),
        "must browse the release group with inc=recordings"
    );

    // Artist transliteration + sort key set.
    // "Sheena Ringo" is the primary EN "Artist name" alias in the fixture
    // (primary=true, locale=en), so select_transliteration picks it.
    let (translit, sort): (Option<String>, String) = conn
        .query_row(
            &format!(
                "SELECT transliteration, sort_name FROM artist WHERE mbid='{}'",
                ARTIST_MBID
            ),
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(translit.as_deref(), Some("Sheena Ringo"));
    assert_eq!(sort, "Sheena, Ringo");

    // Album-title alts: romaji ⇒ translit, English ⇒ translate, keyed by release.
    let album_translit: String = conn
        .query_row(
            &format!(
                "SELECT title FROM release_title_alt WHERE release_mbid='{RELEASE_MBID}' AND kind='translit'"
            ),
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(album_translit, "Muzai Moratorium");
    let album_translate: String = conn
        .query_row(
            &format!(
                "SELECT title FROM release_title_alt WHERE release_mbid='{RELEASE_MBID}' AND kind='translate'"
            ),
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(album_translate, "Innocence Moratorium");

    // Track-title alts for 歌舞伎町の女王, joined by recording MBID.
    let track_translit: String = conn
        .query_row(
            &format!(
                "SELECT title FROM track_title_alt WHERE recording_mbid='{REC_KABUKI}' AND kind='translit'"
            ),
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(track_translit, "Kabukicho no Joo");
    let track_translate: String = conn
        .query_row(
            &format!(
                "SELECT title FROM track_title_alt WHERE recording_mbid='{REC_KABUKI}' AND kind='translate'"
            ),
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(track_translate, "Queen of Kabuki-Cho");

    // The same-script Japanese reissue (2008) must NOT have written a Japanese
    // "translate" alt over the English one — guarded by exact title above, and
    // by the row count: exactly one translate row for this recording.
    let translate_rows: i64 = conn
        .query_row(
            &format!(
                "SELECT count(*) FROM track_title_alt WHERE recording_mbid='{REC_KABUKI}' AND kind='translate'"
            ),
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(translate_rows, 1);

    // File marked enriched.
    let e: i64 = conn
        .query_row(
            "SELECT enriched FROM file WHERE path='/m/a.flac'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(e, 1);
}

// ── International-edition case (real W → Applause / Burn / CO2) ─────────────

/// A regular *international edition* (a real Official release whose
/// `text-representation` is Latin/English) in the same release group — NOT a
/// `transl-tracklisting` pseudo-release — must contribute its English titles as
/// `translate` alts, joined to the original's recordings by recording MBID.
/// Mirrors album "W" by Akira Yuki: a Japanese original (拍手喝采 / 火傷 / 二酸化炭素)
/// and an English edition (Applause / Burn / CO2) sharing recording MBIDs.
#[tokio::test]
async fn international_edition_supplies_translate_alts() {
    const W_RG: &str = "03271c5b-ced2-4356-ac0f-686cc9d9fc52";
    const W_REL: &str = "w0000000-0000-0000-0000-00000000jpan";
    const W_ARTIST: &str = "aaaaaaaa-0000-0000-0000-00000000akir";
    const REC1: &str = "rec00000-0000-0000-0000-000000000001"; // 拍手喝采 / Applause
    const REC2: &str = "rec00000-0000-0000-0000-000000000002"; // 火傷    / Burn
    const REC3: &str = "rec00000-0000-0000-0000-000000000003"; // 二酸化炭素 / CO2

    let conn = open(":memory:").unwrap();
    conn.execute(
        &format!("INSERT INTO artist(mbid,name,sort_name) VALUES ('{W_ARTIST}','結城アイラ','結城アイラ')"),
        [],
    )
    .unwrap();
    conn.execute(
        &format!("INSERT INTO release_group(mbid,title) VALUES ('{W_RG}','W')"),
        [],
    )
    .unwrap();
    conn.execute(
        &format!("INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title) VALUES ('{W_REL}','{W_RG}','{W_ARTIST}','W')"),
        [],
    )
    .unwrap();
    for (i, (rec, jp)) in [(REC1, "拍手喝采"), (REC2, "火傷"), (REC3, "二酸化炭素")]
        .iter()
        .enumerate()
    {
        conn.execute(
            &format!(
                "INSERT INTO track(release_mbid,recording_mbid,disc,position,title) VALUES ('{W_REL}','{rec}',1,{},'{jp}')",
                i + 1
            ),
            [],
        )
        .unwrap();
        conn.execute(
            &format!(
                "INSERT INTO file(path,mtime,size,track_id,added_at,enriched) VALUES ('/m/w{}.flac',0,0,{},0,0)",
                i + 1,
                i + 1
            ),
            [],
        )
        .unwrap();
    }

    let artist_url = format!("{BASE}/artist/{W_ARTIST}?inc=aliases&fmt=json");
    let release_url = format!(
        "{BASE}/release/{W_REL}?inc=recordings+release-rels+release-groups+artist-credits&fmt=json"
    );
    let browse_url =
        format!("{BASE}/release?release-group={W_RG}&inc=recordings&limit=100&offset=0&fmt=json");
    // Minimal artist body — no usable EN "Artist name" alias, so artist
    // transliteration falls back to entity sort-name (irrelevant here).
    let artist_body = format!(
        "{{\"id\":\"{W_ARTIST}\",\"name\":\"結城アイラ\",\"sort-name\":\"Yuki, Aira\",\"aliases\":[]}}"
    );

    let http = FakeHttp::new()
        .with(&artist_url, 200, &artist_body)
        .with(&release_url, 200, &fixture("release_w_jpan.json"))
        .with(
            &browse_url,
            200,
            &fixture("release_group_browse_w_intl.json"),
        );
    let client = rust_lib_olivier::enrich::client::MbClient::new(http);

    enrich(&conn, &client, false, |_| true).await.unwrap();

    // The English international edition's titles land as `translate` track alts,
    // keyed by the SHARED recording MBIDs of the original's tracks.
    let english = |rec: &str| -> Option<String> {
        conn.query_row(
            "SELECT title FROM track_title_alt WHERE recording_mbid=?1 AND kind='translate'",
            [rec],
            |r| r.get::<_, String>(0),
        )
        .ok()
    };
    assert_eq!(english(REC1).as_deref(), Some("Applause"));
    assert_eq!(english(REC2).as_deref(), Some("Burn"));
    assert_eq!(english(REC3).as_deref(), Some("CO2"));

    // The album title alt is the edition's title (here also "W"), stored translate.
    let album_translate: String = conn
        .query_row(
            &format!("SELECT title FROM release_title_alt WHERE release_mbid='{W_REL}' AND kind='translate'"),
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(album_translate, "W");

    // The original Japanese edition (same script) contributed NO alts: no
    // `translit` rows, and the Japanese titles were never stored as alts.
    let translit_rows: i64 = conn
        .query_row(
            &format!("SELECT count(*) FROM track_title_alt WHERE recording_mbid='{REC1}' AND kind='translit'"),
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(translit_rows, 0);
}

/// The same-script guard is load-bearing: a same-script native reissue must NOT
/// clobber a real translation alt, even though it sorts LAST and would win the
/// `ON CONFLICT(...,kind)` last-writer race without the guard.
///
/// The release group browses to THREE editions, all sharing recording REC_GUARD:
///   1. the Japanese original (id `1111…`) — filtered out by id.
///   2. an English edition (id `5555…`, Latn/eng) → translate alt "Applause".
///   3. a Japanese reissue (id `9999…`, Jpan/jpn) with a DIFFERENT title.
/// Ascending-id order processes English (`5…`) before the reissue (`9…`); without
/// the guard the `Jpan` reissue hits `Some(_) => Translate` and, as last writer,
/// would clobber REC_GUARD's translate alt with the Japanese reissue title. With
/// the guard the reissue is skipped, so "Applause" survives.
#[tokio::test]
async fn same_script_reissue_does_not_clobber_translate_alt() {
    const RG: &str = "g0000000-0000-0000-0000-0000000guard";
    const REL: &str = "11111111-1111-1111-1111-111111111111";
    const ARTIST: &str = "aaaaaaaa-0000-0000-0000-0000000guard";
    const REC_GUARD: &str = "rec00000-0000-0000-0000-0000000guard";

    let conn = open(":memory:").unwrap();
    conn.execute(
        &format!(
            "INSERT INTO artist(mbid,name,sort_name) VALUES ('{ARTIST}','結城アイラ','結城アイラ')"
        ),
        [],
    )
    .unwrap();
    conn.execute(
        &format!("INSERT INTO release_group(mbid,title) VALUES ('{RG}','拍手')"),
        [],
    )
    .unwrap();
    conn.execute(
        &format!("INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title) VALUES ('{REL}','{RG}','{ARTIST}','拍手')"),
        [],
    )
    .unwrap();
    conn.execute(
        &format!("INSERT INTO track(release_mbid,recording_mbid,disc,position,title) VALUES ('{REL}','{REC_GUARD}',1,1,'拍手')"),
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at,enriched) VALUES ('/m/guard.flac',0,0,1,0,0)",
        [],
    )
    .unwrap();

    let artist_url = format!("{BASE}/artist/{ARTIST}?inc=aliases&fmt=json");
    let release_url = format!(
        "{BASE}/release/{REL}?inc=recordings+release-rels+release-groups+artist-credits&fmt=json"
    );
    let browse_url =
        format!("{BASE}/release?release-group={RG}&inc=recordings&limit=100&offset=0&fmt=json");
    let artist_body = format!(
        "{{\"id\":\"{ARTIST}\",\"name\":\"結城アイラ\",\"sort-name\":\"Yuki, Aira\",\"aliases\":[]}}"
    );

    let http = FakeHttp::new()
        .with(&artist_url, 200, &artist_body)
        .with(&release_url, 200, &fixture("release_guard_jpan.json"))
        .with(
            &browse_url,
            200,
            &fixture("release_group_browse_guard.json"),
        );
    let client = rust_lib_olivier::enrich::client::MbClient::new(http);

    enrich(&conn, &client, false, |_| true).await.unwrap();

    // The English edition's translate alt survives — the same-script Japanese
    // reissue (which sorts last) was skipped by the guard, not stored.
    let translate: Option<String> = conn
        .query_row(
            "SELECT title FROM track_title_alt WHERE recording_mbid=?1 AND kind='translate'",
            [REC_GUARD],
            |r| r.get::<_, String>(0),
        )
        .ok();
    assert_eq!(translate.as_deref(), Some("Applause"));

    // Exactly ONE translate row for REC_GUARD — the reissue never wrote a second
    // one (and never clobbered the first).
    let translate_rows: i64 = conn
        .query_row(
            "SELECT count(*) FROM track_title_alt WHERE recording_mbid=?1 AND kind='translate'",
            [REC_GUARD],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(translate_rows, 1);
}

#[tokio::test]
async fn resumes_skipping_already_enriched_and_cached() {
    let conn = open(":memory:").unwrap();
    seed_taggable_catalog(&conn);
    conn.execute("UPDATE file SET enriched = 1", []).unwrap();
    // FakeHttp with NO responses: if enrich tried to fetch anything it would error.
    let client = rust_lib_olivier::enrich::client::MbClient::new(FakeHttp::new());
    enrich(&conn, &client, false, |_| true).await.unwrap();
    assert_eq!(
        client.http().calls.borrow().len(),
        0,
        "nothing to do => no HTTP"
    );
}

#[tokio::test]
async fn synthetic_mbids_are_skipped() {
    let conn = open(":memory:").unwrap();
    // A synth-keyed artist/release (no real MBID) must never be fetched.
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('synth:aa:foo','Foo','Foo')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('synth:rel:foo|bar','synth:aa:foo','Bar')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(release_mbid,disc,position,title) VALUES ('synth:rel:foo|bar',1,1,'T')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at,enriched) VALUES ('/m/s.flac',0,0,1,0,0)",
        [],
    )
    .unwrap();
    let client = rust_lib_olivier::enrich::client::MbClient::new(FakeHttp::new());
    enrich(&conn, &client, false, |_| true).await.unwrap();
    assert_eq!(client.http().calls.borrow().len(), 0);
    // Synthetic file stays unenriched (correctly — no MB data exists).
    let e: i64 = conn
        .query_row(
            "SELECT enriched FROM file WHERE path='/m/s.flac'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(e, 0);
}

// ── Task 15: post-scan enrich contract ───────────────────────────────────

/// The audio fixtures carry synthetic-looking fake MBIDs
/// (e.g. `dddddddd-0000-0000-0000-000000000001`) that are NOT prefixed with
/// `synth:`, so the enrich logic treats them as real MBIDs and will fetch them.
/// We provide canned responses using the recorded Shiina Ringo fixtures so that
/// the post-scan enrich call completes without error.  The key contract verified
/// here is that calling `enrich_library` right after a scan is SAFE and
/// idempotent: it completes, emits `done`, and does not crash or leave the DB
/// in a broken state.
#[tokio::test]
async fn enrich_after_scan_is_safe_noop_for_untagged_fixtures() {
    const BASE_URL: &str = "https://musicbrainz.org/ws/2";
    // MBIDs embedded in the fixture audio files (sample.flac / sample.mp3):
    // MUSICBRAINZ_ALBUMARTISTID = dddddddd-0000-0000-0000-000000000001
    // MUSICBRAINZ_ALBUMID       = bbbbbbbb-0000-0000-0000-000000000001
    let fake_artist_mbid = "dddddddd-0000-0000-0000-000000000001";
    let fake_release_mbid = "bbbbbbbb-0000-0000-0000-000000000001";
    let artist_url = format!("{BASE_URL}/artist/{fake_artist_mbid}?inc=aliases&fmt=json");
    let release_url = format!(
        "{BASE_URL}/release/{fake_release_mbid}?inc=recordings+release-rels+release-groups+artist-credits&fmt=json"
    );

    let dir = tempfile::tempdir().unwrap();
    for f in ["sample.mp3", "sample.flac"] {
        std::fs::copy(
            format!("{}/tests/fixtures/{f}", env!("CARGO_MANIFEST_DIR")),
            dir.path().join(f),
        )
        .unwrap();
    }
    let mut conn = open(":memory:").unwrap();
    let root = dir.path().to_string_lossy().to_string();
    rust_lib_olivier::catalog::scan::scan_roots(&mut conn, std::slice::from_ref(&root), |_| {})
        .unwrap();

    // Provide canned responses for the fake MBIDs so enrich can complete.
    // release_muzai.json's release-group is the real muzai RG, so enrich browses
    // it (inc=recordings) for sibling editions — provide that browse response.
    let http = FakeHttp::new()
        .with(&artist_url, 200, &fixture("artist_9e414497_aliases.json"))
        .with(&release_url, 200, &fixture("release_muzai.json"))
        .with(
            &browse_url(),
            200,
            &fixture("release_group_browse_muzai.json"),
        );
    let client = rust_lib_olivier::enrich::client::MbClient::new(http);

    let mut saw_done = false;
    enrich(&conn, &client, false, |p| {
        saw_done |= p.done;
        true
    })
    .await
    .unwrap();
    assert!(saw_done, "enrich must emit a done=true progress event");
    // The post-scan call must complete without error — this is the contract.
    // (A second call with the same conn is idempotent: files are now enriched.)
    let mut saw_done2 = false;
    let client2 = rust_lib_olivier::enrich::client::MbClient::new(FakeHttp::new());
    enrich(&conn, &client2, false, |p| {
        saw_done2 |= p.done;
        true
    })
    .await
    .unwrap();
    assert!(saw_done2, "second call must also emit done");
    assert_eq!(
        client2.http().calls.borrow().len(),
        0,
        "second call must make no HTTP requests (already enriched)"
    );
}
