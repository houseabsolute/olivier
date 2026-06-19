use rust_lib_olivier::cover::resolve_cover;
use rust_lib_olivier::enrich::http::{MbHttp, MbResponse};
use std::cell::RefCell;
use std::collections::HashMap;
use tempfile::TempDir;

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn block<F: std::future::Future>(f: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(f)
}

/// A bytes-serving MbHttp double. `get()` is unused by the resolver.
struct FakeCoverHttp {
    responses: HashMap<String, (u16, Vec<u8>)>,
    calls: RefCell<Vec<String>>,
}

impl FakeCoverHttp {
    fn new() -> Self {
        Self { responses: HashMap::new(), calls: RefCell::new(Vec::new()) }
    }
    fn with(mut self, url: &str, status: u16, bytes: Vec<u8>) -> Self {
        self.responses.insert(url.to_string(), (status, bytes));
        self
    }
    fn call_count(&self) -> usize {
        self.calls.borrow().len()
    }
}

#[async_trait::async_trait(?Send)]
impl MbHttp for FakeCoverHttp {
    async fn get(&self, _url: &str) -> anyhow::Result<MbResponse> {
        anyhow::bail!("get() is unused in cover tests")
    }
    async fn get_bytes(&self, url: &str) -> anyhow::Result<(u16, Vec<u8>)> {
        self.calls.borrow_mut().push(url.to_string());
        self.responses
            .get(url)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("no canned response for {url}"))
    }
}

const JPEG: [u8; 4] = [0xFF, 0xD8, 0xFF, 0xE0];
const PNG: [u8; 4] = [0x89, 0x50, 0x4E, 0x47];

#[test]
fn embedded_art_is_used_without_network() {
    let tmp = TempDir::new().unwrap();
    let http = FakeCoverHttp::new();
    let src = fixture("sample-with-cover.flac");

    let result = block(resolve_cover(
        &http,
        Some(src.to_str().unwrap()),
        "rel-1",
        None,
        tmp.path().to_str().unwrap(),
    ))
    .unwrap();

    let path = result.expect("embedded art should resolve");
    assert!(std::path::Path::new(&path).exists());
    assert_eq!(http.call_count(), 0, "embedded art must not hit the network");
}

#[test]
fn caa_release_front_is_fetched_and_cached() {
    let tmp = TempDir::new().unwrap();
    let cache = tmp.path().to_str().unwrap();
    let no_art = fixture("sample.flac");
    let url = "https://coverartarchive.org/release/rel-2/front-500";
    let http = FakeCoverHttp::new().with(url, 200, JPEG.to_vec());

    let r1 = block(resolve_cover(
        &http, Some(no_art.to_str().unwrap()), "rel-2", None, cache,
    ))
    .unwrap();
    let p1 = r1.expect("CAA cover should resolve");
    assert!(p1.ends_with("olivier-caa-rel-2.jpg"), "got {p1}");
    assert!(std::path::Path::new(&p1).exists());
    assert_eq!(http.call_count(), 1);

    let r2 = block(resolve_cover(
        &http, Some(no_art.to_str().unwrap()), "rel-2", None, cache,
    ))
    .unwrap();
    assert_eq!(r2.unwrap(), p1);
    assert_eq!(http.call_count(), 1, "second call must be a disk hit");
}

#[test]
fn falls_back_to_release_group_front() {
    let tmp = TempDir::new().unwrap();
    let cache = tmp.path().to_str().unwrap();
    let no_art = fixture("sample.flac");
    let rel_url = "https://coverartarchive.org/release/rel-3/front-500";
    let rg_url = "https://coverartarchive.org/release-group/rg-3/front-500";
    let http = FakeCoverHttp::new()
        .with(rel_url, 404, vec![])
        .with(rg_url, 200, PNG.to_vec());

    let r = block(resolve_cover(
        &http, Some(no_art.to_str().unwrap()), "rel-3", Some("rg-3"), cache,
    ))
    .unwrap();
    let p = r.expect("release-group cover should resolve");
    assert!(p.ends_with("olivier-caa-rel-3.png"), "got {p}");
    assert_eq!(http.call_count(), 2);
}

#[test]
fn records_a_miss_and_does_not_refetch() {
    let tmp = TempDir::new().unwrap();
    let cache = tmp.path().to_str().unwrap();
    let no_art = fixture("sample.flac");
    let rel_url = "https://coverartarchive.org/release/rel-4/front-500";
    let rg_url = "https://coverartarchive.org/release-group/rg-4/front-500";
    let http = FakeCoverHttp::new()
        .with(rel_url, 404, vec![])
        .with(rg_url, 404, vec![]);

    let r1 = block(resolve_cover(
        &http, Some(no_art.to_str().unwrap()), "rel-4", Some("rg-4"), cache,
    ))
    .unwrap();
    assert!(r1.is_none());
    assert!(std::path::Path::new(cache)
        .join("olivier-caa-rel-4.miss")
        .exists());
    assert_eq!(http.call_count(), 2);

    let r2 = block(resolve_cover(
        &http, Some(no_art.to_str().unwrap()), "rel-4", Some("rg-4"), cache,
    ))
    .unwrap();
    assert!(r2.is_none());
    assert_eq!(http.call_count(), 2, "a recorded miss must not re-fetch");
}
