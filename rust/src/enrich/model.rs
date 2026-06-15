use serde::Deserialize;

// ── artist?inc=aliases ──────────────────────────────────────────────────
#[derive(Debug, Clone, Deserialize)]
pub struct Artist {
    pub id: String,
    pub name: String,
    #[serde(rename = "sort-name")]
    pub sort_name: String,
    #[serde(default)]
    pub aliases: Vec<Alias>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Alias {
    pub name: String,
    #[serde(rename = "sort-name")]
    pub sort_name: Option<String>,
    pub locale: Option<String>,
    /// `Option<bool>` instead of the spec's `#[serde(default)] bool` because
    /// the real MB fixture contains JSON `null` for this field on some aliases,
    /// which would cause a serde error if the type were plain `bool`.
    /// Task 8 callers should use `primary: Some(true)` in test helpers and
    /// `a.primary.unwrap_or(false)` in filter predicates.
    pub primary: Option<bool>,
    #[serde(rename = "type")]
    pub alias_type: Option<String>,
}

// ── release?inc=recordings+release-rels+release-groups+artist-credits ────
#[derive(Debug, Deserialize)]
pub struct Release {
    pub id: String,
    pub title: String,
    pub date: Option<String>,
    /// Script/language of THIS (pseudo-)release's titles. Drives translit-vs-
    /// translate classification (Task 9): `script == "Latn"` ⇒ transliteration;
    /// a non-Latn script, or `language == "eng"`, ⇒ translation.
    #[serde(rename = "text-representation")]
    pub text_representation: Option<TextRepresentation>,
    #[serde(rename = "release-group")]
    pub release_group: Option<ReleaseGroup>,
    #[serde(default)]
    pub media: Vec<Medium>,
    #[serde(default)]
    pub relations: Vec<Relation>,
}

/// MB `text-representation`: the script the titles are written in and the
/// language they are in. Both fields are optional in MB's data.
#[derive(Debug, Deserialize)]
pub struct TextRepresentation {
    pub script: Option<String>,
    pub language: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ReleaseGroup {
    pub id: String,
    #[serde(rename = "first-release-date")]
    pub first_release_date: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Medium {
    #[serde(default)]
    pub tracks: Vec<MbTrack>,
}

#[derive(Debug, Deserialize)]
pub struct MbTrack {
    pub title: String,
    pub recording: Option<Recording>,
}

#[derive(Debug, Deserialize)]
pub struct Recording {
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct Relation {
    #[serde(rename = "type-id")]
    pub type_id: Option<String>,
    pub release: Option<RelationRelease>,
}

#[derive(Debug, Deserialize)]
pub struct RelationRelease {
    pub id: String,
}

// ── release?release-group=<mbid>&inc=release-rels (browse fallback) ──────
#[derive(Debug, Deserialize)]
pub struct ReleaseBrowse {
    #[serde(default)]
    pub releases: Vec<Release>,
    #[serde(rename = "release-count", default)]
    pub release_count: u32,
}
