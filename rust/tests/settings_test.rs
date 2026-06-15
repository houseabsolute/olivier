use rust_lib_olivier::db::open;
use rust_lib_olivier::settings::{get_setting, get_setting_or_default, set_setting};

#[test]
fn unset_key_returns_none_then_default() {
    let conn = open(":memory:").unwrap();
    assert_eq!(get_setting(&conn, "language_leads").unwrap(), None);
    // Known key falls back to its spec default.
    assert_eq!(
        get_setting_or_default(&conn, "language_leads").unwrap(),
        "A"
    );
    assert_eq!(
        get_setting_or_default(&conn, "mb_contact_email").unwrap(),
        "autarch@urth.org"
    );
    assert_eq!(
        get_setting_or_default(&conn, "play_threshold_percent").unwrap(),
        "50"
    );
    assert_eq!(
        get_setting_or_default(&conn, "play_threshold_seconds").unwrap(),
        "240"
    );
}

#[test]
fn set_then_get_roundtrips_and_overwrites() {
    let conn = open(":memory:").unwrap();
    set_setting(&conn, "language_leads", "B").unwrap();
    assert_eq!(
        get_setting(&conn, "language_leads").unwrap(),
        Some("B".to_string())
    );
    // get_setting_or_default returns the stored value, not the default.
    assert_eq!(
        get_setting_or_default(&conn, "language_leads").unwrap(),
        "B"
    );
    set_setting(&conn, "language_leads", "A").unwrap();
    assert_eq!(
        get_setting(&conn, "language_leads").unwrap(),
        Some("A".to_string())
    );
}

#[test]
fn unknown_key_has_no_default() {
    let conn = open(":memory:").unwrap();
    // get_setting_or_default on an unknown key errors (caller bug), not silently "".
    assert!(get_setting_or_default(&conn, "nope").is_err());
}
