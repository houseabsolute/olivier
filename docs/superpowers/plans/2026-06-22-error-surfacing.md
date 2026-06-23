# App-Wide Error Surfacing (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No error vanishes to the terminal or is silently swallowed — every error surfaces via a snackbar and the persistent "Activity & errors" log — and MusicBrainz enrichment becomes resilient (per-entity errors logged + skipped) with a circuit-breaker (abort at >10 errors / 30 s).

**Architecture:** A Rust `log_activity` FFI appends to the existing decision log; a Dart `ErrorReporter` (snackbar via a global messenger key + the log FFI) is fed by a global guard (`runZonedGuarded` + `FlutterError.onError` + `PlatformDispatcher.onError`); enrich's loop catches per-entity errors and trips a shared circuit-breaker.

**Tech Stack:** Rust (rusqlite) + flutter_rust_bridge; Dart/Flutter/Riverpod.

**Commands:** Rust: `cd rust && cargo test`. Bridge: `mise exec -- flutter_rust_bridge_codegen generate`. Flutter: `mise exec -- flutter test <path>`, `mise exec -- flutter analyze`, `mise exec -- dart format <files>`. Lint: `just lint --all`.

**Conventions:** NEVER `git add` the `TODO` file. Commit messages: plain imperative + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Task order:** 1 (log_activity FFI) → 2 (enrich resilience + breaker + MB body) → 3 (ErrorReporter + seam) → 4 (global guard + messenger key) → 5 (rename page + error branch).

---

### Task 1: `log_activity` FFI

**Files:**
- Create: `rust/src/api/activity.rs`
- Modify: `rust/src/api/mod.rs` (register the module)
- Regenerate: `lib/src/rust/**`, `rust/src/frb_generated.rs`

- [ ] **Step 1: Write the failing test**

Create `rust/tests/activity_log_test.rs`:

```rust
use rust_lib_olivier::api::activity::log_activity;
use std::fs;

#[test]
fn log_activity_appends_a_categorized_line() {
    let dir = std::env::temp_dir().join(format!("olivier_activity_{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let db = dir.join("library.db");
    log_activity(db.to_string_lossy().to_string(), "ERROR".into(), "boom happened".into());
    let logged = fs::read_to_string(dir.join("import-log.log")).unwrap();
    assert!(logged.contains("ERROR"), "category present: {logged}");
    assert!(logged.contains("boom happened"), "detail present: {logged}");
    fs::remove_dir_all(&dir).ok();
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd rust && cargo test --test activity_log_test`
Expected: FAIL to compile — `api::activity` doesn't exist.

- [ ] **Step 3: Implement**

Create `rust/src/api/activity.rs`:

```rust
use crate::decision_log::DecisionLog;

/// Append one timestamped line to the shared activity/error log
/// (`import-log.log`, next to the DB), so Dart-side errors join the Rust-side
/// scan/enrich decisions in one log. `DecisionLog` swallows its own IO errors,
/// so this can never fail a caller.
pub fn log_activity(db_path: String, category: String, detail: String) {
    DecisionLog::for_db(&db_path).line(&category, &detail);
}
```

In `rust/src/api/mod.rs`, add the module (alphabetical, before `catalog`):

```rust
pub mod activity;
```

- [ ] **Step 4: Run to verify pass; regen; analyze**

Run: `cd rust && cargo test --test activity_log_test` (pass). Then from repo root `mise exec -- flutter_rust_bridge_codegen generate`. Verify the generated Dart fn exists:
```bash
grep -rn 'logActivity' lib/src/rust/
```
Expected: `Future<void> logActivity({required String dbPath, required String category, required String detail})` in `lib/src/rust/api/activity.dart`. Then `mise exec -- flutter analyze` (clean).

- [ ] **Step 5: Lint + commit**

Run: `just lint --all` (PASS). Then:
```bash
git add rust/src/api/activity.rs rust/src/api/mod.rs lib/src/rust rust/src/frb_generated.rs rust/tests/activity_log_test.rs
git commit -m "$(cat <<'EOF'
Add log_activity FFI (append to the shared activity/error log)

Lets the Dart error reporter append errors to the same import-log.log the
scanner/enricher write to. Regenerates the bridge.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Enrich resilience + circuit-breaker + MB error body

**Files:**
- Modify: `rust/src/enrich/client.rs` (`fetch_with_backoff` error body)
- Modify: `rust/src/enrich/run.rs` (`enrich_lists` per-entity handling + breaker)
- Test: `rust/tests/enrich_resilience_test.rs`

- [ ] **Step 1: Write the failing tests**

Create `rust/tests/enrich_resilience_test.rs`. The `FakeHttp` double (URL → `MbResponse{status, body}`, via `.with(url, status, body)`) is defined in `rust/tests/enrich_test.rs`; copy that small struct + its `MbHttp` impl into this file (or a shared `mod`), since integration test files don't share items. Use `MbClient::new(fake)` (the NoopPacer test constructor, so no real sleeping).

```rust
use rust_lib_olivier::db::open;
use rust_lib_olivier::decision_log::DecisionLog;
use rust_lib_olivier::enrich::client::MbClient;
use rust_lib_olivier::enrich::http::{MbHttp, MbResponse};
use rust_lib_olivier::enrich::run::enrich;

// ---- FakeHttp (copied from enrich_test.rs) ----
struct FakeHttp {
    responses: std::collections::HashMap<String, MbResponse>,
    calls: std::cell::RefCell<Vec<String>>,
}
impl FakeHttp {
    fn new() -> Self { Self { responses: Default::default(), calls: Default::default() } }
    fn with(mut self, url: &str, status: u16, body: &str) -> Self {
        self.responses.insert(url.to_string(), MbResponse { status, body: body.to_string() });
        self
    }
}
#[async_trait::async_trait(?Send)]
impl MbHttp for FakeHttp {
    async fn get(&self, url: &str) -> anyhow::Result<MbResponse> {
        self.calls.borrow_mut().push(url.to_string());
        self.responses.get(url).cloned()
            .ok_or_else(|| anyhow::anyhow!("no canned response for {url}"))
    }
}

fn artist_url(mbid: &str) -> String {
    format!("https://musicbrainz.org/ws/2/artist/{mbid}?inc=aliases&fmt=json")
}

// Seed one album-artist (+ a release referencing it, satisfying the FK) so
// artists_to_enrich(force) returns it.
fn seed_artist(conn: &rusqlite::Connection, mbid: &str) {
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES (?1,?1,?1)",
        [mbid],
    ).unwrap();
    let rel = format!("rel-{mbid}");
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES (?1,?2,'T')",
        [&rel, &mbid.to_string()],
    ).unwrap();
}

#[tokio::test]
async fn one_bad_artist_is_logged_and_skipped_pass_succeeds() {
    let conn = open(":memory:").unwrap();
    let mbid = "00000000-0000-0000-0000-000000000001";
    seed_artist(&conn, mbid);
    let http = FakeHttp::new().with(&artist_url(mbid), 400, "{\"error\":\"Invalid mbid.\"}");
    let client = MbClient::new(http);

    let logdir = std::env::temp_dir().join(format!("olivier_enrich_res_{}", std::process::id()));
    std::fs::create_dir_all(&logdir).unwrap();
    let log = DecisionLog::to_path(Some(logdir.join("import-log.log")));

    let res = enrich(&conn, &client, true, &log, |_p| true).await;
    assert!(res.is_ok(), "one bad artist must not abort the pass: {res:?}");

    let logged = std::fs::read_to_string(logdir.join("import-log.log")).unwrap();
    assert!(logged.contains("ERROR"), "error logged: {logged}");
    assert!(logged.contains(mbid), "names the bad artist: {logged}");
    assert!(logged.contains("Invalid mbid."), "includes MB's body: {logged}");
    std::fs::remove_dir_all(&logdir).ok();
}

#[tokio::test]
async fn circuit_breaker_aborts_after_more_than_ten_errors() {
    let conn = open(":memory:").unwrap();
    let mut http = FakeHttp::new();
    for i in 1..=11 {
        let mbid = format!("00000000-0000-0000-0000-{i:012}");
        seed_artist(&conn, &mbid);
        http = http.with(&artist_url(&mbid), 400, "nope");
    }
    let client = MbClient::new(http);
    let log = DecisionLog::to_path(None);

    let res = enrich(&conn, &client, true, &log, |_p| true).await;
    assert!(res.is_err(), "should abort once >10 errors pile up");
    assert!(format!("{}", res.unwrap_err()).contains("aborted"));
}

#[tokio::test]
async fn already_enriched_data_is_not_refetched_on_resume() {
    let conn = open(":memory:").unwrap();
    // An album-artist already enriched (name_original set) whose release's files
    // are already enriched=1 — i.e. a prior pass completed it.
    let ambid = "00000000-0000-0000-0000-0000000000aa";
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name,name_original) VALUES (?1,'A','A','エー')",
        [ambid],
    ).unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R',?1,'T')",
        [ambid],
    ).unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,recording_mbid,disc,position,title) VALUES (1,'R','REC',1,1,'t')",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO file(id,path,mtime,size,track_id,enriched,added_at) VALUES (1,'/m/a.flac',0,0,1,1,0)",
        [],
    ).unwrap();

    let http = FakeHttp::new(); // no canned responses — any fetch would error
    let client = MbClient::new(http);
    let res = enrich(&conn, &client, false, &DecisionLog::to_path(None), |_p| true).await;

    assert!(res.is_ok(), "a resume pass over fully-enriched data is a clean no-op: {res:?}");
    assert!(
        client.http().calls.borrow().is_empty(),
        "already-enriched artist+release must not be re-fetched: {:?}",
        client.http().calls.borrow()
    );
}
```

(Note: the breaker counts errors across the whole pass within a 30 s window; in a fast test all 11 fall inside the window, so the 11th trips it. The resume test relies on the non-force selection — `artists_to_enrich`/`releases_to_enrich` skip entities with `name_original` set and no `enriched=0` files. Confirm the `file` columns match the real schema; adjust the INSERT if needed.)

- [ ] **Step 2: Run to verify failure**

Run: `cd rust && cargo test --test enrich_resilience_test`
Expected: FAIL — currently a single 400 aborts the pass (so test 1's `is_ok()` fails / the run errors early), and there is no breaker.

- [ ] **Step 3: Include MB's response body in the error**

In `rust/src/enrich/client.rs`, change the catch-all arm of `fetch_with_backoff`:

```rust
                s => return Err(anyhow::anyhow!("MB returned HTTP {s} for {url}")),
```

to:

```rust
                s => {
                    let snippet: String = resp.body.chars().take(200).collect();
                    return Err(anyhow::anyhow!("MB returned HTTP {s} for {url}: {snippet}"));
                }
```

- [ ] **Step 4: Add the breaker helper + wrap the loops**

In `rust/src/enrich/run.rs`: ensure `use std::time::Duration;` is present (add it if not). Add, above `enrich_lists`:

```rust
const ENRICH_ERROR_WINDOW: Duration = Duration::from_secs(30);
const ENRICH_ERROR_LIMIT: usize = 10;

/// Record an error at "now" and report whether more than ENRICH_ERROR_LIMIT
/// errors occurred within the last ENRICH_ERROR_WINDOW (rolling).
fn breaker_tripped(times: &mut Vec<std::time::Instant>) -> bool {
    let now = std::time::Instant::now();
    times.push(now);
    times.retain(|t| now.duration_since(*t) <= ENRICH_ERROR_WINDOW);
    times.len() > ENRICH_ERROR_LIMIT
}
```

In `enrich_lists`, add `let mut error_times: Vec<std::time::Instant> = Vec::new();` next to `let mut done = 0u64;`.

Replace the **artist loop body** (from `let mb = client.fetch_artist(...).await?;` through the end of the `else { … NOMATCH … }` block) so the fetch+apply runs inside an async block and errors are caught. The loop becomes:

```rust
    for artist_mbid in &artists {
        if !is_real_mbid(artist_mbid) {
            continue;
        }
        log.line(
            if client.is_cached_artist(conn, artist_mbid) { "CACHE" } else { "FETCH" },
            &format!("artist {artist_mbid}"),
        );
        let outcome: anyhow::Result<String> = async {
            let mb = client.fetch_artist(conn, artist_mbid).await?;
            if let Some(chosen) = select_transliteration(&mb) {
                store::apply_artist_transliteration(conn, artist_mbid, &chosen, &mb.name)?;
                if chosen.from_entity_sort_name {
                    log.line("APPLY", &format!("artist \"{}\": sort name = \"{}\"", mb.name, chosen.sort_name));
                } else {
                    log.line("APPLY", &format!("artist \"{}\": reading = \"{}\"", mb.name, chosen.name));
                }
            } else {
                log.line("NOMATCH", &format!("artist \"{}\": no reading from MusicBrainz", mb.name));
            }
            Ok(mb.name)
        }
        .await;
        let current = match outcome {
            Ok(name) => name,
            Err(e) => {
                log.line("ERROR", &format!("artist {artist_mbid}: {e}"));
                if breaker_tripped(&mut error_times) {
                    return Err(anyhow::anyhow!(
                        "Enrichment aborted after more than {ENRICH_ERROR_LIMIT} errors in {}s — see Activity & errors. Re-run enrichment to resume; already-enriched items are skipped.",
                        ENRICH_ERROR_WINDOW.as_secs()
                    ));
                }
                artist_mbid.clone()
            }
        };
        done += 1;
        if !on_progress(EnrichProgress {
            entities_done: done,
            entities_total: total,
            current,
            done: false,
        }) {
            return Ok(()); // cancelled
        }
    }
```

Replace the **release loop body** (from `let release = client.fetch_release(...).await?;` through `tx.commit()?;`) so it runs inside an async block and errors are caught. The loop becomes:

```rust
    for (rel_mbid, _rg_mbid, title) in &releases {
        log.line(
            if client.is_cached_release(conn, rel_mbid) { "CACHE" } else { "FETCH" },
            &format!("release {rel_mbid}"),
        );
        let outcome: anyhow::Result<()> = async {
            let release = client.fetch_release(conn, rel_mbid).await?;
            let mut editions = Vec::new();
            if let Some(rg) = release.release_group.as_ref() {
                if is_real_mbid(&rg.id) {
                    editions = browse_all_editions(conn, client, &rg.id).await?;
                }
            }
            let tx = conn.unchecked_transaction()?;
            if let Some(rg) = release.release_group.as_ref() {
                store::apply_dates(
                    &tx, rel_mbid, &rg.id, title,
                    rg.first_release_date.as_deref(), release.date.as_deref(),
                )?;
                if let Some(d) = rg.first_release_date.as_deref() {
                    log.line("APPLY", &format!("release \"{title}\": original date {d}"));
                }
                if let Some(d) = release.date.as_deref() {
                    log.line("APPLY", &format!("release \"{title}\": reissue date {d}"));
                }
            }
            apply_edition_alts(&tx, rel_mbid, release.text_representation.as_ref(), &editions, log, title)?;
            store::mark_release_files_enriched(&tx, rel_mbid)?;
            tx.commit()?;
            Ok(())
        }
        .await;
        if let Err(e) = outcome {
            log.line("ERROR", &format!("release {rel_mbid} (\"{title}\"): {e}"));
            if breaker_tripped(&mut error_times) {
                return Err(anyhow::anyhow!(
                    "Enrichment aborted after more than {ENRICH_ERROR_LIMIT} errors in {}s — see Activity & errors. Re-run enrichment to resume; already-enriched items are skipped.",
                    ENRICH_ERROR_WINDOW.as_secs()
                ));
            }
        }
        done += 1;
        if !on_progress(EnrichProgress {
            entities_done: done,
            entities_total: total,
            current: title.clone(),
            done: false,
        }) {
            return Ok(()); // cancelled
        }
    }
```

(The final `on_progress(... done: true ...)` + `Ok(())` after the release loop stays unchanged.)

- [ ] **Step 5: Run to verify pass; full suite; lint; commit**

Run: `cd rust && cargo test --test enrich_resilience_test` (3 pass — the resumability test characterizes existing skip-already-enriched behavior and passes from the start; the other two are the red→green ones), `cd rust && cargo test` (FULL suite green — the existing `enrich_test` happy-path still passes; per-entity wrapping doesn't change success behavior), `just lint --all` (PASS). Then:
```bash
git add rust/src/enrich/client.rs rust/src/enrich/run.rs rust/tests/enrich_resilience_test.rs
git commit -m "$(cat <<'EOF'
Make enrich resilient: log+skip per-entity errors, circuit-breaker, MB body

A single artist/release fetch error is logged (ERROR) to the activity log and
skipped instead of aborting the whole pass; the pass aborts only if >10 errors
occur within 30s. The HTTP error now includes MB's response body so the reason
(e.g. "Invalid mbid.") is visible.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `ErrorReporter` + `logActivity` seam

**Files:**
- Create: `lib/state/error_reporter.dart`
- Modify: `lib/state/providers.dart` (the `logActivity` seam + `errorReporterProvider`)
- Test: `test/error_reporter_test.dart`

- [ ] **Step 1: Add the seam provider**

In `lib/state/providers.dart` (the FFI `logActivity` is in the already-importable `package:olivier/src/rust/api/activity.dart` — add that import):

```dart
typedef LogActivityFn = Future<void> Function(String category, String detail);

final logActivityFnProvider = Provider<LogActivityFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (category, detail) =>
      logActivity(dbPath: db, category: category, detail: detail);
});
```

- [ ] **Step 2: Write the failing test**

Create `test/error_reporter_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/error_reporter.dart';

void main() {
  testWidgets('report shows a snackbar and appends to the activity log',
      (tester) async {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    final logged = <(String, String)>[];
    final reporter = ErrorReporter(
      messengerKey: messengerKey,
      logActivity: (cat, detail) async => logged.add((cat, detail)),
    );

    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: messengerKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ));

    reporter.report(Exception('kaboom'));
    await tester.pump(); // let the snackbar appear + the log future run

    expect(find.textContaining('kaboom'), findsOneWidget);
    expect(logged.single.$1, 'ERROR');
    expect(logged.single.$2, contains('kaboom'));
  });

  testWidgets('identical errors are de-duped within the window', (tester) async {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    var calls = 0;
    final reporter = ErrorReporter(
      messengerKey: messengerKey,
      logActivity: (cat, detail) async => calls++,
    );
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: messengerKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ));
    reporter.report(Exception('same'));
    reporter.report(Exception('same'));
    await tester.pump();
    expect(calls, 1, reason: 'second identical report within the window is suppressed');
  });
}
```

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- flutter test test/error_reporter_test.dart` → FAIL (`error_reporter.dart` not found).

- [ ] **Step 4: Implement the reporter**

Create `lib/state/error_reporter.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Central error sink: shows a transient snackbar (via a global messenger key,
/// so it works from outside any widget context) and appends an ERROR line to
/// the activity log. Fed by the global guard in main() and usable from anywhere.
class ErrorReporter {
  ErrorReporter({required this.messengerKey, required this.logActivity});

  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Future<void> Function(String category, String detail) logActivity;

  String? _lastMessage;
  DateTime? _lastAt;

  void report(Object error, {StackTrace? stack, String? context}) {
    final message = context == null ? '$error' : '$context: $error';

    // De-dup: suppress an identical message seen within the last 3 seconds so a
    // repeating failure doesn't flood the user.
    final now = DateTime.now();
    if (_lastMessage == message &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastMessage = message;
    _lastAt = now;

    // Best-effort persistent record; never let logging throw.
    logActivity('ERROR', message).catchError((_) {});

    messengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
        behavior: SnackBarBehavior.floating,
      ));
  }
}

/// Overridden in main()'s ProviderScope to the app-wide instance so widgets can
/// report errors too.
final errorReporterProvider = Provider<ErrorReporter>((ref) =>
    throw UnimplementedError('errorReporterProvider must be overridden'));
```

(`DateTime.now()` is fine in app/test code — the no-`Date.now()` rule is only for Workflow scripts.)

- [ ] **Step 5: Run to verify pass; analyze; format; commit**

Run: `mise exec -- flutter test test/error_reporter_test.dart` (2 pass), `mise exec -- flutter analyze` (clean), `mise exec -- dart format lib/state/error_reporter.dart lib/state/providers.dart test/error_reporter_test.dart`. Then:
```bash
git add lib/state/error_reporter.dart lib/state/providers.dart test/error_reporter_test.dart
git commit -m "$(cat <<'EOF'
Add ErrorReporter (snackbar + activity log) + logActivity seam

Central error sink: a global-messenger-key snackbar plus an ERROR line in the
activity log, with short-window de-dup. errorReporterProvider + the
logActivityFn seam wire it into Riverpod.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Global guard + messenger key

**Files:**
- Modify: `lib/main.dart` (`main()` guard + `OlivierApp` messenger key)
- Test: `test/global_guard_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/global_guard_test.dart` — verify the `FlutterError.onError` wiring routes a build-phase error to a reporter. (The full `runZonedGuarded` in `main()` is not unit-testable; this covers the routing contract.)

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart' show installErrorHandlers;
import 'package:olivier/state/error_reporter.dart';

void main() {
  test('installErrorHandlers routes FlutterError.onError to the reporter', () {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    final logged = <String>[];
    final reporter = ErrorReporter(
      messengerKey: messengerKey,
      logActivity: (cat, detail) async => logged.add(detail),
    );
    final previous = FlutterError.onError;
    installErrorHandlers(reporter);
    addTearDown(() => FlutterError.onError = previous);

    FlutterError.onError!(FlutterErrorDetails(exception: Exception('build boom')));
    expect(logged.single, contains('build boom'));
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/global_guard_test.dart` → FAIL (`installErrorHandlers` not exported from main.dart).

- [ ] **Step 3: Wire the guard in main.dart**

In `lib/main.dart`:

Add imports:
```dart
import 'dart:async' show runZonedGuarded;
import 'package:olivier/src/rust/api/activity.dart';
import 'package:olivier/state/error_reporter.dart';
```

Add top-level declarations (near `late final String dbPath;`):
```dart
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
ErrorReporter? errorReporter;

/// Route Flutter framework + platform async errors to [reporter]. Exposed for
/// testing the routing contract.
void installErrorHandlers(ErrorReporter reporter) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    reporter.report(details.exception, stack: details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    reporter.report(error, stack: stack);
    return true;
  };
}
```

Wrap the body of `main()` in `runZonedGuarded`, construct the reporter right after `dbPath` is resolved, install the handlers, and add the reporter override to the `ProviderScope`. The new `main()`:

```dart
Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    JustAudioMediaKit.ensureInitialized(
      linux: true, windows: false, android: false, iOS: false, macOS: false,
    );
    await RustLib.init();

    dbPath = await _resolveDbPath();

    final reporter = ErrorReporter(
      messengerKey: scaffoldMessengerKey,
      logActivity: (category, detail) =>
          logActivity(dbPath: dbPath, category: category, detail: detail),
    );
    errorReporter = reporter;
    installErrorHandlers(reporter);

    // ... UNCHANGED: AudioServiceMpris.init / AudioService.init / controllers /
    //     restore-from-snapshot block, verbatim ...

    runApp(
      ProviderScope(
        overrides: [
          dbPathProvider.overrideWithValue(dbPath),
          playbackControllerProvider.overrideWithValue(playbackController),
          errorReporterProvider.overrideWithValue(reporter),
        ],
        child: const OlivierApp(),
      ),
    );
  }, (error, stack) {
    // Uncaught async errors (incl. the unawaited streaming-FFI return port).
    errorReporter?.report(error, stack: stack);
  });
}
```

In `OlivierApp.build`, add the messenger key to the `MaterialApp`:
```dart
        child: MaterialApp(
          title: 'Olivier',
          theme: olivierTheme(),
          scaffoldMessengerKey: scaffoldMessengerKey,
          home: home ?? const BrowserPage(),
        ),
```

- [ ] **Step 4: Run to verify pass; analyze; full suite; commit**

Run: `mise exec -- flutter test test/global_guard_test.dart` (pass), `mise exec -- flutter analyze` (clean), `mise exec -- dart format lib/main.dart test/global_guard_test.dart`, `mise exec -- flutter test` (full suite green — existing widget tests build `OlivierApp`/`BrowserPage` with their own `MaterialApp`, unaffected by the top-level key). Then:
```bash
git add lib/main.dart test/global_guard_test.dart
git commit -m "$(cat <<'EOF'
Add global error guard + scaffold messenger key

Wrap main() in runZonedGuarded and route FlutterError.onError +
PlatformDispatcher.onError to the ErrorReporter, so every uncaught/
fire-and-forget async error (incl. the lost streaming-FFI return port that
hid the enrich 400) surfaces as a snackbar + activity-log line. MaterialApp
gets the global messenger key the reporter uses.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Rename to "Activity & errors" + page error branch

**Files:**
- Modify: `lib/settings/import_log_page.dart` (title + error branch)
- Modify: `lib/settings/settings_page.dart` (the list-tile title)
- Test: `test/activity_log_page_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/activity_log_page_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/settings/import_log_page.dart';
import 'package:olivier/state/import_log.dart';

void main() {
  testWidgets('titled "Activity & errors"', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [importLogFnProvider.overrideWithValue(() async => 'some line')],
      child: const MaterialApp(home: ImportLogPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Activity & errors'), findsOneWidget);
  });

  testWidgets('shows a message (not an infinite spinner) when the log read fails',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        importLogFnProvider.overrideWithValue(() async => throw Exception('read failed')),
      ],
      child: const MaterialApp(home: ImportLogPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('read failed'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/activity_log_page_test.dart` → FAIL (title is still "Import log"; the error case shows an infinite spinner so `CircularProgressIndicator` is found).

- [ ] **Step 3: Rename + add the error branch**

In `lib/settings/import_log_page.dart`, change the AppBar title:
```dart
        title: const Text('Import log'),
```
to:
```dart
        title: const Text('Activity & errors'),
```
And add an error branch in the `FutureBuilder` — change:
```dart
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final text = snap.data ?? '';
```
to:
```dart
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not read the log: ${snap.error}'),
              ),
            );
          }
          final text = snap.data ?? '';
```

In `lib/settings/settings_page.dart`, change the list-tile title (line ~208):
```dart
            title: const Text('Import log'),
```
to:
```dart
            title: const Text('Activity & errors'),
```

- [ ] **Step 4: Run to verify pass; analyze; full suite; lint; commit**

Run: `mise exec -- flutter test test/activity_log_page_test.dart` (2 pass), `mise exec -- flutter analyze` (clean), `mise exec -- dart format` the two files + test, `mise exec -- flutter test` (full suite green), `just lint --all` (PASS). Then:
```bash
git add lib/settings/import_log_page.dart lib/settings/settings_page.dart test/activity_log_page_test.dart
git commit -m "$(cat <<'EOF'
Rename "Import log" to "Activity & errors" + handle read failure

The page now also shows a message instead of spinning forever when the log
read fails.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `cd rust && cargo test` — green (incl. `activity_log_test`, `enrich_resilience_test`).
- [ ] `mise exec -- flutter test` — green (incl. the four new Dart tests).
- [ ] `mise exec -- flutter analyze` — No issues; `just lint --all` — PASS.
- [ ] Manual (`just run`): trigger an enrich error (or any failing action) → a snackbar appears and the entry shows in Settings ▸ "Activity & errors"; a systemic failure aborts enrich with the ">10 errors in 30s" message; nothing lands only in the terminal.

## Touched files

| File | Change |
|------|--------|
| `rust/src/api/activity.rs`, `api/mod.rs` | `log_activity` FFI |
| `rust/src/enrich/client.rs` | MB response body in the error |
| `rust/src/enrich/run.rs` | per-entity error catch + circuit-breaker |
| `lib/src/rust/**`, `rust/src/frb_generated.rs` | regenerated bridge |
| `lib/state/error_reporter.dart` | `ErrorReporter` |
| `lib/state/providers.dart` | `logActivityFn` seam + `errorReporterProvider` |
| `lib/main.dart` | `runZonedGuarded` + handlers + messenger key |
| `lib/settings/import_log_page.dart`, `settings_page.dart` | "Activity & errors" + error branch |
| `rust/tests/*`, `test/*` | tests |
