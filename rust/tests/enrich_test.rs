use rust_lib_olivier::db::open;

#[test]
fn migration_creates_enrichment_tables() {
    let conn = open(":memory:").unwrap();
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table'
             AND name IN ('setting','mb_cache','release_title_alt','track_title_alt')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 4);

    // artist.transliteration + artist.sort_name_embedded columns added.
    let cols: i64 = conn
        .query_row(
            "SELECT count(*) FROM pragma_table_info('artist')
             WHERE name IN ('transliteration','sort_name_embedded')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(cols, 2);
}
