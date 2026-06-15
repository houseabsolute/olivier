# Phase 1 results (2026-06-15)

Phase 1 (Catalog, Browse & Play) for [the Olivier design](../specs/2026-06-13-olivier-design.md),
plan: [phase1-catalog-browse-play](../plans/2026-06-14-olivier-phase1-catalog-browse-play.md).

End state: scanning a real library populates the catalog; a 3-column Miller browser shows
Artists → Albums → Tracks grouped by **album artist**; selecting an album or track plays it with a
now-playing bar, MPRIS metadata + cover art, and play tracking; root folders are managed from a
Settings page and persisted; all data lives under the XDG data dir.

## Automated outcomes (proven by tests / CI)

33 Rust integration tests + 2 Dart↔Rust FFI tests, all green; `flutter analyze` clean;
`precious lint --all` green; `flutter build linux --debug` builds and links.

- **Catalog schema + migrations** — `rust/tests/catalog_test.rs::migration_creates_catalog_tables`:
  artist / release_group / release / track / file / track_stats (+ the `root` table). FKs are
  **enforced** (libsqlite3-sys bundles SQLite with `SQLITE_DEFAULT_FOREIGN_KEYS=1`).
- **Incremental scanner** — `rust/tests/catalog_test.rs`: `scan_populates_catalog_and_is_incremental`
  (re-scan reports `files_changed == 0`), `scan_stores_embedded_sort_name`, and the synthetic-key /
  sort-name unit checks. Per-file progress is emitted so the UI counts up live.
- **Multi-root, scoped deletion** — `scoped_scan_preserves_other_roots`,
  `scoped_scan_preserves_shared_parent_rows`, `scoped_sweep_handles_multibyte_root_paths`: the
  deletion sweep is scoped to the roots being scanned (UTF-8-safe path prefix), so scanning one
  folder never deletes another's files, and a shared artist/release survives.
- **Root folder store** — `roots_add_list_remove`, `remove_root_prunes_files_beneath_it`,
  `remove_root_keeps_files_under_nested_root`, `remove_root_keeps_files_still_covered_by_another_root`:
  add/list/remove roots; removing a root prunes only files no longer under any remaining root.
- **Browse queries** — `artists_page_ordered_and_keyset`, `artists_page_limit`,
  `albums_for_artist_ordered_by_year`, `tracks_for_album_ordered_by_disc_position`,
  `file_paths_for_album_ordered_by_disc_position`: keyset paging of album-artists, albums by original
  year, tracks by disc/position.
- **Case-insensitive sort** — `artists_page_sorts_case_insensitively`,
  `albums_for_artist_title_tiebreak_is_case_insensitive`: artists and albums sort with `COLLATE
  NOCASE` (a lowercase-led name no longer sorts after the uppercase ones).
- **Album-artist dedup** — `reconcile_merges_synth_album_artist_into_real`,
  `reconcile_leaves_synth_only_artist_untouched`: an album-artist tagged with its MBID on some
  albums but not others is merged into one entry (re-point synth-keyed releases onto the real MBID,
  matched on the recomputed synthetic key so case/whitespace differences can't miss a merge).
- **Play tracking** — `record_play_accumulates_stats`: `play_count` / `last_played` /
  `first_played` aggregate in `track_stats`.
- **Tag + cover reading** — `rust/tests/tags_test.rs` (7): single-parse common fields + MBIDs +
  sort names across formats, and `extract_cover_*` (extract embedded art to a cached file, cache
  hit returns the same path, art-less file returns `None`).
- **FFI bridge** — `integration_test/catalog_ffi_test.dart` + `tags_ffi_test.dart` run **in CI**
  headless under xvfb (one file per `flutter test … -d linux` invocation), catching bridge
  regressions after each codegen.
- **Lint/tidy** — `precious lint --all` green (clippy, rustfmt, dart-format, flutter-analyze,
  prettier, taplo, shellcheck, shfmt, omegasort, typos). CI runs it.

## Human checklist (manual, on Linux)

Run `mise exec -- flutter run -d linux`. (Scanning, multi-folder add, and case-insensitive ordering
were observed working during development; the rest want a tick.)

- Scan & folders (Settings ⚙️):
  - [ ] Add a real music folder → live "Scanning… N files (M new)" progress → catalog populates.
  - [ ] Add a **second** folder → the first folder's music is still present (no wipe); both coexist.
  - [ ] Add a folder **while a scan is running** → it queues ("· K queued"), no crash.
  - [ ] Remove a folder (confirm dialog) → its tracks disappear; "Rescan all" re-scans.
- Browse:
  - [ ] Artists grouped by **album artist**, sorted case-insensitively by sort-name.
  - [ ] Albums ordered by original year; Tracks by disc/position with `#. title` + mm:ss.
  - [ ] After "Rescan all", inconsistently-tagged album-artists (e.g. AJICO, ANOHNI) appear **once**.
- Play:
  - [ ] Click an album/track → audio plays; now-playing bar shows title/artist; seek slider tracks.
  - [ ] Play / pause / next / previous work.
  - [ ] Play tracking: after a qualifying play (finish / ≥50% / 4 min) `last_played` updates.
- MPRIS (in another terminal, with a track playing):
  - [ ] `playerctl metadata` shows title / artist / album and an `mpris:artUrl` for art-bearing tracks.
  - [ ] The GNOME/KDE media widget shows the cover thumbnail.
- Storage:
  - [ ] DB lives at `~/.local/share/olivier/olivier.db`; an existing `~/Documents/olivier.db` was
        migrated (moved) on first run and the library survived.

## Decisions / adjustments (carried into Phase 2)

- **Album-level dedup deferred.** Two sub-cases exist: a synthetic release duplicating a real one
  (mergeable, like the album-artist fix, but requires merging tracks past the
  `UNIQUE(release_mbid, disc, position)` constraint), and two *real* MBIDs sharing an artist+title —
  which are frequently **distinct albums** (e.g. Faye Wong's self-titled 1997 *and* 2001 releases),
  so "same artist + same title" must **not** auto-merge. The real cure is Phase 2 MusicBrainz
  enrichment backfilling the missing release MBIDs.
- **Album-artist dedup is an interim heuristic.** `reconcile_album_artists` runs at the end of every
  scan; once enrichment fills in album-artist MBIDs, the synthetic split mostly stops happening.
- **Single-language display only.** The bilingual Japanese layout (transliteration of names,
  translation of titles, original beneath) is Phase 2.
- **Storage relocated to the XDG data dir** (`$XDG_DATA_HOME/olivier`), with a one-time migration
  from the former documents-dir location (`.db` moves last as the commit point; cross-fs fallback is
  copy-to-temp + atomic rename + delete).
- **Scan model:** per-root-scoped deletion + a single-writer serialized scan queue (`ScanController`);
  `reconcile_album_artists` then the orphan sweep run after every scan. Progress is emitted per file.
- **Play threshold** (first of finish / ≥50% / 4 min) is enforced Dart-side; Rust just records the
  aggregate. Spec §4's per-play event table remains deferred.
- **Cover art** is extracted to the app cache dir keyed by a per-build path hash and surfaced to
  MPRIS as a `file://` `artUri`; only the currently-playing track's art is extracted (lazily, memoized).
- **MPRIS** still has no Seek/Volume (`audio_service_mpris` 1.0.0-beta.2 limitation, carried from
  Phase 0).
