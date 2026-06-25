use rust_lib_olivier::db::open;
use rust_lib_olivier::enrich::select::ChosenAlias;
use rust_lib_olivier::enrich::store::apply_artist_transliteration;

fn seed_artist(conn: &rusqlite::Connection, mbid: &str, name: &str) {
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES (?1, ?2, ?2)",
        rusqlite::params![mbid, name],
    )
    .unwrap();
}

fn translit_of(conn: &rusqlite::Connection, mbid: &str) -> Option<String> {
    conn.query_row(
        "SELECT transliteration FROM artist WHERE mbid = ?1",
        [mbid],
        |r| r.get(0),
    )
    .unwrap()
}

fn tier3(sort: &str) -> ChosenAlias {
    ChosenAlias {
        name: sort.to_string(),
        sort_name: sort.to_string(),
        from_entity_sort_name: true,
    }
}

#[test]
fn tier3_latin_tag_name_becomes_the_reading() {
    let conn = open(":memory:").unwrap();
    seed_artist(&conn, "A1", "Yayoi Yula"); // tag name is the romanization
    apply_artist_transliteration(&conn, "A1", &tier3("Yula, Yayoi"), "柚楽弥衣").unwrap();

    assert_eq!(translit_of(&conn, "A1").as_deref(), Some("Yayoi Yula"));
    let orig: Option<String> = conn
        .query_row(
            "SELECT name_original FROM artist WHERE mbid='A1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(orig.as_deref(), Some("柚楽弥衣"));
}

#[test]
fn tier3_non_latin_tag_name_stays_null() {
    let conn = open(":memory:").unwrap();
    seed_artist(&conn, "A2", "日本語名"); // tag name is itself non-Latin: no usable reading
    apply_artist_transliteration(&conn, "A2", &tier3("Sort, Key"), "柚楽弥衣").unwrap();

    assert_eq!(translit_of(&conn, "A2"), None);
}

#[test]
fn tier1_alias_reading_ignores_the_tag_name_guard() {
    let conn = open(":memory:").unwrap();
    // Catalog tag name is non-Latin: if the tier-3 `name`-guard leaked into the
    // tier-1/2 path it would null this reading. The alias must be used regardless.
    seed_artist(&conn, "A3", "浅井健一");
    let chosen = ChosenAlias {
        name: "Kenichi Asai".to_string(),
        sort_name: "Asai, Kenichi".to_string(),
        from_entity_sort_name: false, // MB had an English alias
    };
    apply_artist_transliteration(&conn, "A3", &chosen, "浅井健一").unwrap();

    assert_eq!(translit_of(&conn, "A3").as_deref(), Some("Kenichi Asai"));
}
