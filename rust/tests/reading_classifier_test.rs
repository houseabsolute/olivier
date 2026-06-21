use rust_lib_olivier::enrich::select::{correct_alt_kind, english_words, AltKind};
use std::collections::HashSet;

#[test]
fn dictionary_loads_with_expected_membership() {
    let dict = english_words();
    assert!(
        dict.contains("night"),
        "common English word should be present"
    );
    assert!(dict.contains("exploration"));
    assert!(
        !dict.contains("yoru"),
        "romaji should not be an English word"
    );
    assert!(!dict.contains("tanken"));
}

fn dict(words: &[&str]) -> HashSet<String> {
    words.iter().map(|w| w.to_string()).collect()
}

#[test]
fn romaji_translation_is_corrected_to_reading() {
    // Only "no" is English; "yoru"/"tanken"/"hajimari"/"uta"/"kiseki" are not.
    let d = dict(&["no", "night", "song"]);
    let titles = ["Yoru no Tanken", "Hajimari no Uta", "Kiseki"];
    assert_eq!(
        correct_alt_kind(AltKind::Translate, &titles, &d),
        AltKind::Translit
    );
}

#[test]
fn english_translation_stays_translation() {
    let d = dict(&["night", "exploration", "song", "of", "the", "beginning"]);
    let titles = ["Night Exploration", "Song of the Beginning"];
    assert_eq!(
        correct_alt_kind(AltKind::Translate, &titles, &d),
        AltKind::Translate
    );
}

#[test]
fn translit_kind_is_never_changed() {
    let d = dict(&["night", "exploration"]);
    // English content, but mb_kind is already Translit -> unchanged.
    let titles = ["Night Exploration"];
    assert_eq!(
        correct_alt_kind(AltKind::Translit, &titles, &d),
        AltKind::Translit
    );
}

#[test]
fn non_latin_titles_keep_mb_classification() {
    let d = dict(&["no"]);
    let titles = ["Ночь", "Песня"]; // Cyrillic translation, not latin
    assert_eq!(
        correct_alt_kind(AltKind::Translate, &titles, &d),
        AltKind::Translate
    );
}

#[test]
fn single_token_keeps_mb_classification() {
    let d = dict(&["no"]);
    let titles = ["Yoru"]; // one token: too little signal
    assert_eq!(
        correct_alt_kind(AltKind::Translate, &titles, &d),
        AltKind::Translate
    );
}

#[test]
fn real_dictionary_corrects_the_chilldspot_case() {
    let titles = ["Yoru no Tanken"];
    assert_eq!(
        correct_alt_kind(AltKind::Translate, &titles, english_words()),
        AltKind::Translit
    );
}
