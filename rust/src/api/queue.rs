use crate::db::{self, QueueSnapshot};

pub fn save_queue(db_path: String, snapshot: QueueSnapshot) -> anyhow::Result<()> {
    let conn = db::open(&db_path)?;
    db::save_queue(&conn, &snapshot)
}

pub fn load_queue(db_path: String) -> anyhow::Result<Option<QueueSnapshot>> {
    let conn = db::open(&db_path)?;
    db::load_queue(&conn)
}
