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

    /// Fetch raw bytes (e.g. Cover Art Archive images, which are not UTF-8).
    /// The default errors so existing text-only fakes need no change; real
    /// transports override it.
    async fn get_bytes(&self, _url: &str) -> anyhow::Result<(u16, Vec<u8>)> {
        anyhow::bail!("get_bytes not implemented for this MbHttp")
    }
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

    async fn get_bytes(&self, url: &str) -> anyhow::Result<(u16, Vec<u8>)> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::USER_AGENT, &self.user_agent)
            .send()
            .await?;
        let status = resp.status().as_u16();
        let bytes = resp.bytes().await?.to_vec();
        Ok((status, bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct OverrideFake;
    #[async_trait::async_trait(?Send)]
    impl MbHttp for OverrideFake {
        async fn get(&self, _url: &str) -> anyhow::Result<MbResponse> {
            anyhow::bail!("unused")
        }
        async fn get_bytes(&self, _url: &str) -> anyhow::Result<(u16, Vec<u8>)> {
            Ok((200, vec![0xFF, 0xD8, 0xFF]))
        }
    }

    struct DefaultFake;
    #[async_trait::async_trait(?Send)]
    impl MbHttp for DefaultFake {
        async fn get(&self, _url: &str) -> anyhow::Result<MbResponse> {
            anyhow::bail!("unused")
        }
        // get_bytes intentionally NOT overridden -> uses the trait default.
    }

    fn block<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(f)
    }

    #[test]
    fn get_bytes_override_returns_bytes() {
        let (status, bytes) = block(OverrideFake.get_bytes("x")).unwrap();
        assert_eq!(status, 200);
        assert_eq!(bytes, vec![0xFF, 0xD8, 0xFF]);
    }

    #[test]
    fn get_bytes_default_impl_errors() {
        assert!(block(DefaultFake.get_bytes("x")).is_err());
    }
}
