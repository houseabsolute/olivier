use crate::enrich::model::{Alias, Artist, Release, TextRepresentation};

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
pub fn select_transliteration(artist: &Artist) -> Option<ChosenAlias> {
    let artist_names: Vec<&Alias> = artist
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

fn is_en(a: &Alias) -> bool {
    a.locale.as_deref() == Some("en")
}

fn pick_min_by_name<'a>(it: impl Iterator<Item = &'a Alias>) -> Option<&'a Alias> {
    it.min_by(|x, y| x.name.cmp(&y.name))
}

fn chosen(a: &Alias) -> ChosenAlias {
    ChosenAlias {
        name: a.name.clone(),
        // An alias may omit sort-name; fall back to its display name.
        sort_name: a.sort_name.clone().unwrap_or_else(|| a.name.clone()),
        from_entity_sort_name: false,
    }
}

// ── Pseudo-release discovery ──────────────────────────────────────────────

/// MusicBrainz `transl-tracklisting` relationship type-id (§5.1, Appendix B).
pub const TRANSL_TRACKLISTING_TYPE_ID: &str = "fc399d47-23a7-4c28-bfcf-0607a562b644";

/// Pseudo-release target MBIDs linked from `release` via `transl-tracklisting`.
pub fn pseudo_release_targets(release: &Release) -> Vec<String> {
    release
        .relations
        .iter()
        .filter(|rel| rel.type_id.as_deref() == Some(TRANSL_TRACKLISTING_TYPE_ID))
        .filter_map(|rel| rel.release.as_ref().map(|r| r.id.clone()))
        .collect()
}

// ── Alt-kind classification ───────────────────────────────────────────────

/// Which kind of alternate a pseudo-release supplies. Authoritative source is
/// the pseudo-release's `text-representation`; the title-pair heuristic is only
/// a documented fallback for releases that omit it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AltKind {
    Translit,
    Translate,
}

/// Classify a pseudo-release using its `text-representation` (preferred), or
/// the title-pair fallback when that metadata is absent. `original_title` is
/// only consulted by the fallback.
pub fn classify_pseudo(original_title: &str, pseudo: &Release) -> AltKind {
    if let Some(kind) = classify_from_text_representation(pseudo.text_representation.as_ref()) {
        return kind;
    }
    // No usable text-representation: deterministic title-pair fallback.
    classify_alt(original_title, &pseudo.title)
}

/// Returns `None` when `text-representation` carries no script and no language
/// (caller then falls back to the title heuristic).
fn classify_from_text_representation(tr: Option<&TextRepresentation>) -> Option<AltKind> {
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
