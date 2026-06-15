/// A single MusicBrainz HTTP response, reduced to what the client needs.
#[derive(Debug, Clone)]
pub struct MbResponse {
    pub status: u16,
    pub body: String,
}

/// The injectable HTTP seam. Real impl talks to MusicBrainz; tests serve
/// recorded JSON. `?Send` because the enrichment core is driven by a private
/// current-thread tokio runtime via `block_on` (see `api/enrich.rs`), so the
/// future never needs to be `Send`; the test double also holds a non-Send
/// `RefCell`.
#[async_trait::async_trait(?Send)]
pub trait MbHttp {
    async fn get(&self, url: &str) -> anyhow::Result<MbResponse>;
}

/// Production HTTP via reqwest with the MusicBrainz-required User-Agent.
pub struct ReqwestHttp {
    client: reqwest::Client,
    user_agent: String,
}

impl ReqwestHttp {
    /// `contact_email` comes from the `mb_contact_email` setting; `version`
    /// from CARGO_PKG_VERSION. User-Agent: `Olivier/<version> ( <email> )`.
    pub fn new(version: &str, contact_email: &str) -> anyhow::Result<Self> {
        let user_agent = format!("Olivier/{version} ( {contact_email} )");
        let client = reqwest::Client::builder()
            .build()
            .map_err(|e| anyhow::anyhow!("build reqwest client: {e}"))?;
        Ok(Self { client, user_agent })
    }
}

#[async_trait::async_trait(?Send)]
impl MbHttp for ReqwestHttp {
    async fn get(&self, url: &str) -> anyhow::Result<MbResponse> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::USER_AGENT, &self.user_agent)
            .send()
            .await?;
        let status = resp.status().as_u16();
        let body = resp.text().await?;
        Ok(MbResponse { status, body })
    }
}
