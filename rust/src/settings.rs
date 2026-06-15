use rusqlite::{Connection, OptionalExtension};

/// Spec §4 setting keys and their defaults. `root_folders` lives in the
/// dedicated `root` table (Phase 1), so it is intentionally absent here.
const DEFAULTS: &[(&str, &str)] = &[
    ("language_leads", "A"),
    ("mb_contact_email", "autarch@urth.org"),
    ("play_threshold_percent", "50"),
    ("play_threshold_seconds", "240"),
];

/// Read a raw setting; `None` if never written.
pub fn get_setting(conn: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    let v = conn
        .query_row("SELECT value FROM setting WHERE key = ?1", [key], |r| {
            r.get::<_, String>(0)
        })
        .optional()?;
    Ok(v)
}

/// Read a setting, falling back to the spec default for a known key.
/// Errors if `key` is neither stored nor a known default — that's a caller bug.
pub fn get_setting_or_default(conn: &Connection, key: &str) -> anyhow::Result<String> {
    if let Some(v) = get_setting(conn, key)? {
        return Ok(v);
    }
    DEFAULTS
        .iter()
        .find(|(k, _)| *k == key)
        .map(|(_, v)| v.to_string())
        .ok_or_else(|| anyhow::anyhow!("unknown setting key with no default: {key}"))
}

/// Write (upsert) a setting.
pub fn set_setting(conn: &Connection, key: &str, value: &str) -> anyhow::Result<()> {
    conn.execute(
        "INSERT INTO setting(key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![key, value],
    )?;
    Ok(())
}
