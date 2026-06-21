use crate::enrich::model::{MbAlias, MbArtist, MbTextRepresentation};
use std::collections::HashSet;
use std::sync::OnceLock;

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
/// edition's `text-representation`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AltKind {
    Translit,
    Translate,
}

/// Lowercased English words for the reading-vs-translation content check,
/// bundled from atebits/Words `en.txt` (CC0) and embedded into the binary.
/// Loaded once on first use.
pub fn english_words() -> &'static HashSet<String> {
    static WORDS: OnceLock<HashSet<String>> = OnceLock::new();
    WORDS.get_or_init(|| {
        include_str!("../../data/en_words.txt")
            .lines()
            .map(|w| w.trim().to_ascii_lowercase())
            .filter(|w| !w.is_empty())
            .collect()
    })
}

/// Fraction of alphabetic characters that are ASCII letters (0.0 if none).
/// Gates the English check to latin-script titles: a Cyrillic/Greek translation
/// scores ~0 and keeps MB's classification.
fn ascii_latin_ratio(text: &str) -> f64 {
    let mut alpha = 0usize;
    let mut ascii = 0usize;
    for c in text.chars() {
        if c.is_alphabetic() {
            alpha += 1;
            if c.is_ascii_alphabetic() {
                ascii += 1;
            }
        }
    }
    if alpha == 0 {
        0.0
    } else {
        ascii as f64 / alpha as f64
    }
}

/// Split latin text into lowercase word tokens: maximal runs of ASCII letters,
/// keeping an apostrophe inside a word ("don't" stays one token) and trimming
/// any leading/trailing apostrophes.
fn tokenize(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for c in text.chars() {
        if c.is_ascii_alphabetic() {
            cur.push(c.to_ascii_lowercase());
        } else if c == '\'' && !cur.is_empty() {
            cur.push(c);
        } else if !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out.into_iter()
        .map(|w| w.trim_matches('\'').to_string())
        .filter(|w| !w.is_empty())
        .collect()
}

/// Correct MB's classification in the one failing direction: when MB says
/// `Translate` for a latin-script edition whose pooled titles are mostly NOT
/// English (a romanization MB mislabeled as a translation), return `Translit`.
/// Every other case is returned unchanged.
pub fn correct_alt_kind(mb_kind: AltKind, titles: &[&str], dict: &HashSet<String>) -> AltKind {
    if mb_kind != AltKind::Translate {
        return mb_kind;
    }
    let combined = titles.join(" ");
    // Latin-script guard: leave non-latin translations to MB.
    if ascii_latin_ratio(&combined) < 0.8 {
        return AltKind::Translate;
    }
    let tokens = tokenize(&combined);
    // Min-token guard: too little signal to override MB.
    if tokens.len() < 2 {
        return AltKind::Translate;
    }
    let found = tokens.iter().filter(|t| dict.contains(t.as_str())).count();
    let fraction = found as f64 / tokens.len() as f64;
    if fraction < 0.5 {
        AltKind::Translit
    } else {
        AltKind::Translate
    }
}

/// Classify an edition by its `text-representation` (script/language): a Latin
/// script ⇒ transliteration; `language == "eng"` (or any other non-original
/// script) ⇒ translation. Returns `None` when `text-representation` carries no
/// script and no language; on the sibling-edition path the caller then skips the
/// edition.
pub fn classify_from_text_representation(tr: Option<&MbTextRepresentation>) -> Option<AltKind> {
    let tr = tr?;
    // English-language title is a translation regardless of script.
    if tr.language.as_deref() == Some("eng") {
        return Some(AltKind::Translate);
    }
    match tr.script.as_deref() {
        Some("Latn") => Some(AltKind::Translit),
        Some(_) => Some(AltKind::Translate), // non-Latn script that isn't the original
        None => None,                        // no script + non-eng language => skip
    }
}
