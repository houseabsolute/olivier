use rust_lib_olivier::enrich::select::english_words;

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
