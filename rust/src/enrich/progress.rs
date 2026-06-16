/// Streamed enrichment progress, mirroring `catalog::scan::ScanProgress`.
#[derive(Clone)]
pub struct EnrichProgress {
    /// Unique album-artists + releases processed so far.
    pub entities_done: u64,
    /// Total entities to process this run (artists + releases).
    pub entities_total: u64,
    /// Human-readable label of the current entity (artist/album name).
    pub current: String,
    pub done: bool,
}
