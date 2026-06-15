use crate::db;
use crate::settings;

pub fn get_setting(db_path: String, key: String) -> anyhow::Result<Option<String>> {
    settings::get_setting(&db::open(&db_path)?, &key)
}

pub fn set_setting(db_path: String, key: String, value: String) -> anyhow::Result<()> {
    settings::set_setting(&db::open(&db_path)?, &key, &value)
}
