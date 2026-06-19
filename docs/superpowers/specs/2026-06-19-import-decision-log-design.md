# Import & Enrichment Decision Log — Design

**Date:** 2026-06-19
**Status:** Approved design → ready for implementation plan
**Backlog item:** "Record a log of all decisions made during imports — de-dupe, etc. — viewable in app via settings" (TODO line 3)
**Out of scope:** structured/queryable log (a DB table was considered and rejected in favour of a plain text file); auto-rotation/size-capping (deferred); logging routine "unchanged file" skips (no-ops, not decisions).

## Goal

Give the user visibility into what the scanner and the MusicBrainz enricher actually *did* to the library — especially de-duplication and removals — by writing human-readable decision lines to a plain text file and viewing that file in the app.

## Storage: one plain-text file

A single append-only file `import-log.log` in the **same directory as the SQLite DB**. No new FFI parameters are threaded for the path: the Rust side derives it from the `db_path` each scan/enrich FFI already receives (`<dirname(db_path)>/import-log.log`); the Dart viewer derives the same path from `dbPathProvider`. Lines are human-readable so the file is useful opened externally too.

### Line format

`<local timestamp>  <CATEGORY>  <detail>`, with each run delimited by a header:

```
=== Scan /m/Music @ 2026-06-19 14:30:01 ===
2026-06-19 14:30:02  ADD     track "歌舞伎町の女王" — Sheena Ringo  [/m/…/01.flac]
2026-06-19 14:30:02  DEDUP   /m/…/01.mp3 → existing track "歌舞伎町の女王" (rel …, disc 1, pos 1)
2026-06-19 14:30:05  REMOVE  file /m/…/old.flac (gone from disk)
2026-06-19 14:30:05  PRUNE   album "W" — Akira Yuki (no files remain)
2026-06-19 14:30:06  FAIL    /m/…/broken.flac: read_tags failed (<error>)
2026-06-19 14:30:06  MERGE   synth artist "akira yuki" → Akira Yuki (mbid …)
=== Enrich @ 2026-06-19 14:31:10 ===
2026-06-19 14:31:11  MB FETCH    artist "Sheena Ringo" (network)
2026-06-19 14:31:11  MB CACHE    release … (cache hit)
2026-06-19 14:31:11  MB APPLY    artist "Sheena Ringo": name_original = 椎名林檎
2026-06-19 14:31:12  MB APPLY    track "…" (rel …): title_translit = "Kabukicho no Joo"
2026-06-19 14:31:12  MB NOMATCH  release … (no MusicBrainz data)
```

Timestamps are local wall-clock formatted `YYYY-MM-DD HH:MM:SS`. The project has no date crate today; the implementation adds a minimal epoch→civil formatter (a small helper, or a lightweight crate such as `time`/`jiff` — the plan picks one, favouring the project's lean-dependency style).

## What's logged

| Category | When | Source |
|----------|------|--------|
| `ADD` | a new track / album / artist enters the catalog | `upsert_file` (insert, not conflict-update) |
| `DEDUP` | a second file maps onto an existing track (same `release_mbid, disc, position`) | `upsert_file` (track `ON CONFLICT` with a pre-existing different file) |
| `MERGE` | a synthetic same-name artist is folded into the real MBID artist | `reconcile_album_artists` |
| `REMOVE` | a file is dropped because its path is no longer on disk | deletion sweep |
| `PRUNE` | a track/album/artist is removed because it has no files left | `prune_orphans` |
| `FAIL` | a file's tags can't be read | `read_tags` error (see behaviour change) |
| `MB FETCH` / `MB CACHE` | an entity's MusicBrainz data is fetched from the network vs served from `mb_cache` | enrich client |
| `MB APPLY` | a field is written from MB data (artist transliteration/`name_original`; release/track `title_translit`/`title_translate`; original/reissue year) | `enrich/run.rs` apply points |
| `MB NOMATCH` | an entity has no usable MusicBrainz data | `enrich/run.rs` |

Routine unchanged-file skips are **not** logged.

## Capture architecture (the substantive work)

A small `DecisionLog` appender owns a buffered handle to `import-log.log` (opened in append mode) and exposes typed methods (`add(category, detail)`, `scan_header(roots)`, `enrich_header()`). **All writes are best-effort** — a logging/IO failure is swallowed and must never abort or fail a scan/enrich. It is constructed at each FFI entry point (which all have `db_path`) and threaded into the core functions.

Today these decisions are made by bulk SQL that yields no per-row detail, so the core functions are instrumented:

- **`scan.rs::upsert_file`** returns the decisions it made (a `Vec` of events) instead of `()`. It detects, per entity, insert-vs-conflict (via `INSERT … RETURNING` / `changes()` / a pre-SELECT) and, for the track key, whether a *different* file already backed `(release_mbid, disc, position)` → `DEDUP`. `scan_roots` logs the returned events.
- **Deletion sweep** and **`prune_orphans`** switch from blind `DELETE` to **SELECT-the-affected-rows then DELETE**, so removed file paths and orphaned entity names can be logged (`REMOVE` / `PRUNE`).
- **`reconcile_album_artists`** already iterates real artists and recomputes synth keys; it logs each synth→real re-point (`MERGE`).
- **`enrich/run.rs`** logs `MB FETCH`/`MB CACHE` (from the client's cache path), `MB APPLY` at each `store::apply_*` / `upsert_*_alt` / date-write call (with the field and new value), and `MB NOMATCH` when an entity yields no usable data.

`scan_roots`, `enrich`, and the per-entity entry points (`reread_track_tags`, `enrich_artist`, `enrich_album`) all take the `DecisionLog`.

## Behaviour change: a bad file no longer aborts the scan

Today `scan_roots` reads tags with `read_tags(path)?` — a single unreadable file propagates the error and **aborts the entire scan**. With `FAIL` logging, this becomes: log a `FAIL` line for that file and `continue` to the next. One corrupt file no longer kills the whole import.

## Retention

Append across all runs. A **"Clear log"** action (Settings) truncates the file to empty. No automatic trimming/rotation in v1 — re-scans are infrequent and the file stays small for a personal library; size-capped rotation is deferred.

## Viewer

A new **"Import log"** entry in `lib/settings/settings_page.dart` opens an **import-log page** that:
- reads the file directly in Dart (`File(path).readAsString()` — no FFI; pure local read), shown as scrollable, copy-pasteable monospace `SelectableText` in **chronological order (oldest first)**, with the view opening scrolled to the **bottom** so the newest run is visible (no content reversal — keeps within-run line order correct);
- shows the file's path so it can be opened externally;
- has a **Clear** button (truncates the file) and a refresh.

The file path comes from a `importLogPathProvider` derived from `dbPathProvider`; the read goes through an injectable seam (`importLogFnProvider` returning the file's contents) so the page is host-VM testable against a temp file with no real catalog.

## Error handling

Logging is strictly best-effort: every `DecisionLog` write that fails (open/append/flush) is silently ignored so it can never break or slow a scan/enrich. The viewer treats a missing/unreadable file as "empty log".

## Testing

- **Rust** (tempdir DB → sibling `import-log.log`):
  - scanning a folder where two files share `(release, disc, position)` produces a `DEDUP` line; a brand-new track produces `ADD`.
  - re-scanning after deleting a file on disk produces `REMOVE` + the resulting `PRUNE`.
  - a file with unreadable tags produces a `FAIL` line **and the scan still completes** (the other files import).
  - `reconcile` produces a `MERGE` line when a synth artist folds into a real one.
  - an enrich run against a `FakeHttp` fixture produces `MB FETCH` + `MB APPLY` lines; an entity with no data produces `MB NOMATCH`.
  - the appender never returns an error to the caller (best-effort): a non-writable log path leaves the scan succeeding.
- **Dart** (host-VM, no FFI): the import-log page renders an injected temp file's contents; the Clear action empties it; a missing file shows an empty state.

## Build order (for the plan)

1. `DecisionLog` appender + the minimal timestamp formatter (+ unit tests).
2. Scan instrumentation: `upsert_file` returns events (`ADD`/`DEDUP`); `scan_roots` writes the scan header + events; the **abort→skip+FAIL** behaviour change.
3. Removal instrumentation: SELECT-then-DELETE in the deletion sweep + `prune_orphans` (`REMOVE`/`PRUNE`); `MERGE` in `reconcile_album_artists`.
4. Enrich instrumentation: `MB FETCH`/`CACHE`/`APPLY`/`NOMATCH` in `enrich/run.rs` + the enrich entry points.
5. Thread the `DecisionLog` through all FFI entry points (scan/enrich/reread/per-entity).
6. Dart: `importLogPathProvider` + `importLogFnProvider` seam + the import-log page + the Settings entry + Clear.

## Notes / deferred

- **Auto-rotation / size cap** deferred; "Clear log" is the only pruning in v1.
- **Per-entity actions** (`reread_track_tags`, `enrich_artist`, `enrich_album`) log to the same file with their own headers.
- Host-VM test rule (as elsewhere): Dart tests run under plain `mise exec -- flutter test`; the viewer's file read is behind an injectable seam; Rust decision capture is covered by `rust/tests`.
- The log is intentionally human-readable prose, not a machine format — it is a diagnostic aid, not an API.
