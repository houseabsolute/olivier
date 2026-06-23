# App-Wide Error Surfacing (Phase 1) — Design Spec

**Date:** 2026-06-22
**Status:** Approved in brainstorming — pending spec review

## Goal

No error is lost to the terminal or silently swallowed: the user can always see what happened. Errors surface two ways — a transient **snackbar** and a persistent **"Activity & errors"** log (the existing decision/import log, expanded). Plus, MusicBrainz enrichment becomes resilient (one bad entity no longer aborts the pass) with a circuit-breaker that stops a runaway failure fast.

Driven by an enrich `HTTP 400` that both aborted the whole pass and surfaced as an *unhandled* terminal exception while the UI acted like enrichment had finished.

## Background (from the error-handling audit)

- **Streaming-FFI errors are lost.** The four streaming FFI calls (`scan_library`, `enrich_library`, `enrich_artist`, `enrich_album`) push progress on one port but return their `Result` on a **separate, unawaited** port. A fatal `Err` (e.g. the 400) becomes an **unhandled async error → terminal exception**, while the progress stream closes *normally* — so the Dart `try/catch` around `await for` never fires and `EnrichState.lastError` stays null. Hence: terminal crash + UI looks successful.
- **No global handler.** There is no `runZonedGuarded`, `FlutterError.onError`, or `PlatformDispatcher.onError`, so any uncaught/fire-and-forget async error falls through to the terminal or the red error screen.
- **Pervasive fire-and-forget.** Queue mutations (`append`/`removeAt`/`reorder`/`clear`/`setShuffle`/`setQueue`/`replaceLibraryShuffled`/`_persist`→`saveQueue`), transport actions (play/pause/seek/skip/volume), the set-reading dialogs, `recordPlay`, root persistence (`addRoot`/`removeRoot`/`listRoots`), settings saves, and startup restore are all called unawaited with no `try/catch` → silent or terminal.
- **The decision log** (`rust/src/decision_log.rs` → `import-log.log`, shown read-only by `lib/settings/import_log_page.dart`) records scan decisions and per-file scan failures (`FAIL`), but records **no enrich errors at all**.
- Existing surfaces that DO work and stay: scan snackbar + Settings error rows (`scan.lastError`/`enrich.lastError`); per-column `AsyncValue.when(error:)`; search overlay error; intentional silent-degrade for cover art (kept).

## Decisions (from brainstorming)

- **Central surface:** a transient snackbar **and** the existing log, renamed **"Activity & errors,"** carrying both Rust-side (scan/enrich) and Dart-side (caught) errors.
- **Global safety net:** `runZonedGuarded` + `FlutterError.onError` + `PlatformDispatcher.onError`, all feeding one error reporter — the highest-leverage way to make every uncaught/fire-and-forget error visible without touching each call site.
- **Enrich resilience + circuit-breaker:** per-entity errors are logged + skipped + counted; the pass aborts if **more than 10 errors occur within a 30-second window**; MB's response body is included so the reason is visible.
- **Phasing:** this Phase 1 = the safety net + central surface + enrich resilience/breaker. Phase 2 (out of scope here) = friendly messages, per-dialog inline errors, per-action success/failure toasts, snackbar de-dup tuning, colouring ERROR lines.

## Architecture

### 1. Error reporter (Dart) — the single sink

A small service exposed as a provider, e.g. `errorReporter`, with `report(Object error, {StackTrace? stack, String? context})` that:
- Shows a snackbar via a global `GlobalKey<ScaffoldMessengerState>` (added to `MaterialApp.scaffoldMessengerKey`), so it works even when the error originates outside a widget's `BuildContext`.
- Appends an `ERROR` line to the activity log via a new FFI seam (below).
- Applies light de-duplication: suppress an identical message seen within the last few seconds, so a repeating failure (e.g. a failing `saveQueue`) doesn't spam.

### 2. Global guard (Dart, `lib/main.dart`)

Wrap startup in `runZonedGuarded(() { … runApp(…); }, (e, st) => errorReporter.report(e, stack: st))`. Also set `FlutterError.onError = (d) { errorReporter.report(d.exception, stack: d.stack); FlutterError.presentError(d); }` and `PlatformDispatcher.instance.onError = (e, st) { errorReporter.report(e, stack: st); return true; }`. Together these catch widget-build errors, platform/async uncaught errors, and the lost-port streaming-FFI rejections — so the enrich 400 (and every fire-and-forget failure) is now caught and surfaced instead of hitting the terminal.

### 3. Activity-log FFI (Rust)

Add `pub fn log_activity(db_path: String, category: String, detail: String)` in `rust/src/api/` that appends one timestamped line via `DecisionLog` to the same `import-log.log`. The Dart error reporter calls it (through a seam provider) so Dart-caught errors join the Rust scan/enrich decisions in one log. (`DecisionLog` already swallows its own IO errors, so logging can never itself fail a flow.)

### 4. "Activity & errors" page

Rename the page title and its Settings entry from "Import log" to **"Activity & errors"** (`lib/settings/import_log_page.dart`, `lib/settings/settings_page.dart`). It already renders the whole log file read-only; no parsing change is required. Also add an **error branch** to its `FutureBuilder` so a log-read failure shows a message instead of an infinite spinner (a current bug).

### 5. Enrich resilience (Rust, `rust/src/enrich/run.rs`)

Process each artist and each release as an independent unit: on a fetch/apply error, write `log.line("ERROR", "<artist|release> <mbid> (\"<name>\"): <err>")`, count it, and **continue** to the next entity — never propagate a single entity's error. (Scan already does this for per-file tag reads; this brings enrich to parity.)

### 6. Circuit-breaker (Rust)

Track error timestamps during a pass; if the number of errors within any rolling **30-second** window exceeds **10**, stop the pass and return `Err(anyhow!("Enrichment aborted: >10 errors in 30s — see Activity & errors"))` and write a final `ERROR` line. The returned `Err` surfaces via the global guard (snackbar) and the abort is recorded in the log. (A systemic failure — MB down, a bad request affecting every entity — thus stops in ~seconds instead of grinding through the whole library.)

### 7. MB error body (Rust, `rust/src/enrich/client.rs`)

In `fetch_with_backoff`, include a truncated snippet of the response body in the non-200/503 error: `anyhow!("MB returned HTTP {s} for {url}: {body_snippet}")`, so the activity-log ERROR line shows MB's reason (e.g. `Invalid mbid.`).

## Resumability (errors don't waste prior work)

Enrichment is already incrementally resumable, and this design preserves that:

- Each release marks its files `enriched=1` inside its **own** transaction (`store::mark_release_files_enriched`), committed per-release. With the per-entity error handling above, an **errored release's transaction rolls back** (uncommitted → dropped on the `Err` path) so its files stay `enriched=0`; a **succeeded** release stays `enriched=1`. A circuit-breaker abort therefore preserves every release completed before it.
- **Re-running the default pass resumes.** `enrich(force=false)` (the Settings "Enrich library" button) selects only releases with `enriched=0` files and artists that are unenriched or own un-enriched files — so already-enriched data is **not** re-processed. The `mb_cache` further means any re-touched entity isn't re-fetched from the network. ("Re-fetch from MusicBrainz" / `force=true` is the deliberate full redo and is unchanged.)
- **Resume hint:** the circuit-breaker abort message tells the user how to resume (re-run enrichment; already-enriched items are skipped).

No new "resume" command is needed — "Enrich library" *is* the resume.

## Edge cases

- **Single-entity re-fetch** (`enrich_artist`/`enrich_album` from the right-click menu): there is nothing to "skip to," so a failure legitimately ends the (one-entity) pass; it is logged as `ERROR` and surfaced via the global guard's snackbar. The circuit-breaker is irrelevant for one entity.
- **Snackbar storms:** the reporter's de-dup window prevents a repeating failure from flooding; batch enrich errors go to the log (not a snackbar each) — only the final abort/summary is worth a toast.
- **Intentional silent-degrade kept:** cover-art and layout-settings load failures keep their local `catch → fallback` and do NOT route to the reporter (they are not errors the user must act on).
- **Logging never fails a flow:** `log_activity`/`DecisionLog` swallow their own IO errors by design.

## Testing

- **Rust:** (a) enrich where a stubbed HTTP returns 400 for one artist → that artist is logged `ERROR` + skipped, the rest enrich, the pass returns `Ok`; (b) circuit-breaker: a stub that fails >10 entities (which, in a fast test, all fall inside the 30 s window) → the pass aborts with the abort error after the threshold; (c) `fetch_with_backoff` error string includes the response body; (d) `log_activity` appends a line to the log file.
- **Dart:** `errorReporter.report(...)` shows a snackbar (pump + find) and calls the `logActivity` seam (overridden in the test); the `FlutterError.onError` wiring routes a thrown build error to the reporter; the activity page shows an error message (not an infinite spinner) when the log read fails.

## Out of scope (Phase 2)

Friendly/user-facing error messages (vs raw `$e`); per-dialog inline errors (set-reading dialogs currently hang on persist failure); per-action success/failure toasts where the user clicked (e.g. "Re-fetch failed"); colouring/filtering ERROR lines in the activity page; broader snackbar de-dup tuning; wrapping individual queue/transport mutations in local `try/catch` for targeted messages (the global guard already surfaces them in Phase 1).
