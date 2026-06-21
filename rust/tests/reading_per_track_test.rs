use rust_lib_olivier::enrich::select::{
    english_words, is_non_latin, resolve_edition_kind, store_alt_for, AltKind,
};
use std::collections::HashSet;

fn dict(words: &[&str]) -> HashSet<String> {
    words.iter().map(|w| w.to_string()).collect()
}

#[test]
fn is_non_latin_detects_original_script() {
    assert!(is_non_latin("夜の探検")); // Japanese original
    assert!(is_non_latin("歌舞伎町の女王"));
    assert!(is_non_latin("夜のNight")); // mixed, still mostly non-Latin
    assert!(!is_non_latin("ingredients")); // English original
    assert!(!is_non_latin("Yoru no Tanken")); // a romanization is Latin
    assert!(!is_non_latin("")); // empty
    assert!(!is_non_latin("12:34")); // no letters
}

#[test]
fn resolve_edition_kind_uses_only_the_subset() {
    let d = dict(&["no", "night", "of", "the"]);
    assert_eq!(
        resolve_edition_kind(AltKind::Translate, &["Yoru no Tanken", "Kiseki"], &d),
        AltKind::Translit
    );
    assert_eq!(
        resolve_edition_kind(AltKind::Translate, &[], &d),
        AltKind::Translate
    );
    assert_eq!(
        resolve_edition_kind(AltKind::Translate, &["Night of the"], &d),
        AltKind::Translate
    );
}

#[test]
fn store_alt_for_gates_readings_to_non_latin() {
    assert!(store_alt_for(AltKind::Translit, true));
    assert!(!store_alt_for(AltKind::Translit, false));
    assert!(store_alt_for(AltKind::Translate, true));
    assert!(store_alt_for(AltKind::Translate, false));
}

#[test]
fn mixed_album_only_non_latin_tracks_get_readings() {
    let d = english_words();
    let non_latin_alts = ["Yoru no Tanken", "Hajimari no Uta", "Kiseki"];
    let kind = resolve_edition_kind(AltKind::Translate, &non_latin_alts, d);
    assert_eq!(kind, AltKind::Translit);
    assert!(store_alt_for(kind, true));
    assert!(!store_alt_for(kind, false));
}
