use crate::enrich::model::{MbAlias, MbArtist, MbRelease, MbTextRepresentation};

/// The chosen display transliteration for an artist (§5.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChosenAlias {
    pub name: String,
    pub sort_name: String,
    /// True when no usable alias existed and we fell back to the entity
    /// sort-name (sort-key priority tier 2/3 in §6.1).
    pub from_entity_sort_name: bool,
}

/// §5.1 artist-transliteration selection.
/// 1. keep type == "Artist name"
/// 2. prefer locale=="en" && primary; else any locale=="en"; else entity sort-name
/// 3. tie-break: name ascending, take first (deterministic).
pub fn select_transliteration(artist: &MbArtist) -> Option<ChosenAlias> {
    let artist_names: Vec<&MbAlias> = artist
        .aliases
        .iter()
        .filter(|a| a.alias_type.as_deref() == Some("Artist name"))
        .collect();

    // Tier 1: en + primary.
    if let Some(a) = pick_min_by_name(
        artist_names
            .iter()
            .copied()
            .filter(|a| is_en(a) && a.primary.unwrap_or(false)),
    ) {
        return Some(chosen(a));
    }
    // Tier 2: any en.
    if let Some(a) = pick_min_by_name(artist_names.iter().copied().filter(|a| is_en(a))) {
        return Some(chosen(a));
    }
    // Tier 3: entity sort-name (display name == sort-name; flagged).
    Some(ChosenAlias {
        name: artist.sort_name.clone(),
        sort_name: artist.sort_name.clone(),
        from_entity_sort_name: true,
    })
}

fn is_en(a: &MbAlias) -> bool {
    a.locale.as_deref() == Some("en")
}

fn pick_min_by_name<'a>(it: impl Iterator<Item = &'a MbAlias>) -> Option<&'a MbAlias> {
    it.min_by(|x, y| x.name.cmp(&y.name))
}

fn chosen(a: &MbAlias) -> ChosenAlias {
    ChosenAlias {
        name: a.name.clone(),
        // An alias may omit sort-name; fall back to its display name.
        sort_name: a.sort_name.clone().unwrap_or_else(|| a.name.clone()),
        from_entity_sort_name: false,
    }
}

// ── Alt-kind classification ───────────────────────────────────────────────

/// Which kind of alternate an edition supplies. Authoritative source is the
/// edition's `text-representation`; the title-pair heuristic is only a documented
/// fallback for editions that omit it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AltKind {
    Translit,
    Translate,
}

/// Classify a pseudo-release using its `text-representation` (preferred), or
/// the title-pair fallback when that metadata is absent. `original_title` is
/// only consulted by the fallback.
pub fn classify_pseudo(original_title: &str, pseudo: &MbRelease) -> AltKind {
    if let Some(kind) = classify_from_text_representation(pseudo.text_representation.as_ref()) {
        return kind;
    }
    // No usable text-representation: deterministic title-pair fallback.
    classify_alt(original_title, &pseudo.title)
}

/// Classify an edition by its `text-representation` (script/language): a Latin
/// script ⇒ transliteration; `language == "eng"` (or any other non-original
/// script) ⇒ translation. Returns `None` when `text-representation` carries no
/// script and no language (caller then falls back to the title heuristic, or —
/// for the sibling-edition path — skips the edition).
pub fn classify_from_text_representation(tr: Option<&MbTextRepresentation>) -> Option<AltKind> {
    let tr = tr?;
    // English-language title is a translation regardless of script.
    if tr.language.as_deref() == Some("eng") {
        return Some(AltKind::Translate);
    }
    match tr.script.as_deref() {
        Some("Latn") => Some(AltKind::Translit),
        Some(_) => Some(AltKind::Translate), // non-Latn script that isn't the original
        None => None,                        // no script + non-eng language => fall back
    }
}

/// Deterministic title-pair fallback (no MB metadata available): an all-ASCII
/// pseudo title whose original contains non-ASCII characters is a romanization
/// ⇒ transliteration; otherwise ⇒ translation. A genuine English semantic
/// translation reaches `Translate` via the primary `text-representation`
/// `language=eng` path (`classify_from_text_representation`), not this fallback —
/// which cannot distinguish a romanization from a translation without metadata.
///
/// In practice this fallback is rarely reached because modern MusicBrainz
/// releases include `text-representation` metadata that takes the primary path
/// first.
pub fn classify_alt(original_title: &str, pseudo_title: &str) -> AltKind {
    // A romanization: the pseudo is plain ASCII while the original is not.
    let romaji_like = pseudo_title.is_ascii() && !original_title.is_ascii();
    if romaji_like {
        AltKind::Translit
    } else {
        AltKind::Translate
    }
}
