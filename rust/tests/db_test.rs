use rust_lib_olivier::db::{open, search_contains};

fn seed() -> rusqlite::Connection {
    let conn = open(":memory:").unwrap();
    conn.execute("INSERT INTO search(text) VALUES (?1)", ["椎名林檎の歌"])
        .unwrap();
    conn.execute(
        "INSERT INTO search(text) VALUES (?1)",
        ["Ringo Sheena live"],
    )
    .unwrap();
    conn
}

#[test]
fn cjk_two_char_substring_matches_via_like() {
    let conn = seed();
    let hits = search_contains(&conn, "椎名").unwrap(); // 2 chars -> LIKE path
    assert_eq!(hits, ["椎名林檎の歌"]);
}

#[test]
fn cjk_three_char_substring_matches_via_match() {
    let conn = seed();
    let hits = search_contains(&conn, "名林檎").unwrap(); // 3 chars -> MATCH path
    assert_eq!(hits, ["椎名林檎の歌"]);
}

#[test]
fn latin_substring_matches() {
    let conn = seed();
    let hits = search_contains(&conn, "Ringo").unwrap();
    assert_eq!(hits, ["Ringo Sheena live"]);
}
