# Manual Reading/Translation Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user manually set a track's or album's reading/translation (overriding the automatic classifier), via a "Set reading…" dialog, with the overrides surviving re-fetch.

**Architecture:** Two override tables (`track_title_override`, `release_title_override`) whose values `COALESCE` over the enriched `*_title_alt` values in every display query; a Rust getter/setter API; a Flutter `TitleOverrideDialog` mirroring `ArtistReadingDialog`, wired into the track and album right-click menus. Per field: NULL = automatic, non-empty = override, `''` = suppress.

**Tech Stack:** Rust (rusqlite) + flutter_rust_bridge; Dart/Flutter/Riverpod. Builds on the existing artist-reading-override pattern.

**Commands:** Rust: `cd rust && cargo test`. Bridge: `mise exec -- flutter_rust_bridge_codegen generate`. Flutter: `mise exec -- flutter test <path>`, `mise exec -- flutter analyze`. Lint: `just lint --all`.

**Conventions:** NEVER `git add` the `TODO` file or any `#TODO#`. Commit messages: plain imperative + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Task order:** 1 (schema + storage) → 2 (display COALESCE) → 3 (FFI + bridge regen) → 4 (Flutter dialog + providers) → 5 (wire into the menus). Each leaves a compiling, green tree.

---

### Task 1: Override tables + getter/setter

**Files:**
- Modify: `rust/src/db.rs` (migration), `rust/src/catalog/schema.rs` (struct), `rust/src/catalog/query.rs` (getter/setter)
- Test: `rust/tests/title_override_test.rs`

- [ ] **Step 1: Add the migration**

In `rust/src/db.rs`, append to `MIGRATION_SLICE` (after the artist-override `M::up`):

```rust
    // ── Per-track / per-album manual reading+translation override ────────
    M::up(
        "CREATE TABLE track_title_override (
            recording_mbid TEXT PRIMARY KEY,
            translit       TEXT,
            translate      TEXT
         );
         CREATE TABLE release_title_override (
            release_mbid   TEXT PRIMARY KEY,
            translit       TEXT,
            translate      TEXT
         );",
    ),
```

- [ ] **Step 2: Add the getter struct**

In `rust/src/catalog/schema.rs`, add (a plain bridged struct; match the file's existing derive style, e.g. `#[derive(Debug, Clone)]`):

```rust
/// Current enriched + manual-override reading/translation for one title, for the
/// "Set reading…" dialog. Each override field: None = automatic, Some("") =
/// suppress, Some(text) = override.
#[derive(Debug, Clone)]
pub struct TitleOverride {
    pub translit: Option<String>,
    pub translate: Option<String>,
    pub translit_override: Option<String>,
    pub translate_override: Option<String>,
}
```

- [ ] **Step 3: Write the failing storage tests**

Create `rust/tests/title_override_test.rs`:

```rust
use rust_lib_olivier::catalog::query::{
    release_title_override, set_release_title_override, set_track_title_override,
    track_title_override,
};
use rust_lib_olivier::db::open;

fn seed(conn: &rusqlite::Connection) {
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('A','Artist','Artist')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('R','A','Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,recording_mbid,disc,position,title) VALUES (1,'R','REC',1,1,'曲')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track_title_alt(recording_mbid,kind,title) VALUES ('REC','translit','Kyoku')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release_title_alt(release_mbid,kind,title) VALUES ('R','translit','Arubamu')",
        [],
    )
    .unwrap();
}

#[test]
fn track_override_round_trips_and_clears() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    // Initially: enriched translit present, no override.
    let t = track_title_override(&conn, "REC").unwrap();
    assert_eq!(t.translit.as_deref(), Some("Kyoku"));
    assert_eq!(t.translit_override, None);

    // Set an override + a suppress on translate.
    set_track_title_override(&conn, "REC", Some("Kyoku!".into()), Some("".into())).unwrap();
    let t = track_title_override(&conn, "REC").unwrap();
    assert_eq!(t.translit_override.as_deref(), Some("Kyoku!"));
    assert_eq!(t.translate_override.as_deref(), Some(""));

    // Clearing both (None,None) deletes the row -> back to automatic.
    set_track_title_override(&conn, "REC", None, None).unwrap();
    let t = track_title_override(&conn, "REC").unwrap();
    assert_eq!(t.translit_override, None);
    assert_eq!(t.translate_override, None);
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM track_title_override WHERE recording_mbid='REC'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 0);
}

#[test]
fn release_override_round_trips() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    set_release_title_override(&conn, "R", None, Some("Album (EN)".into())).unwrap();
    let r = release_title_override(&conn, "R").unwrap();
    assert_eq!(r.translit.as_deref(), Some("Arubamu")); // enriched
    assert_eq!(r.translit_override, None); // automatic
    assert_eq!(r.translate_override.as_deref(), Some("Album (EN)"));
}
```

- [ ] **Step 4: Run to verify failure**

Run: `cd rust && cargo test --test title_override_test`
Expected: FAIL to compile (functions not defined).

- [ ] **Step 5: Implement the getter + setter**

In `rust/src/catalog/query.rs`, add (import `TitleOverride` from schema alongside the others):

```rust
pub fn track_title_override(conn: &Connection, recording_mbid: &str) -> anyhow::Result<TitleOverride> {
    let row = conn.query_row(
        "SELECT
            (SELECT title FROM track_title_alt WHERE recording_mbid = ?1 AND kind = 'translit'),
            (SELECT title FROM track_title_alt WHERE recording_mbid = ?1 AND kind = 'translate'),
            (SELECT translit  FROM track_title_override WHERE recording_mbid = ?1),
            (SELECT translate FROM track_title_override WHERE recording_mbid = ?1)",
        [recording_mbid],
        |r| {
            Ok(TitleOverride {
                translit: r.get(0)?,
                translate: r.get(1)?,
                translit_override: r.get(2)?,
                translate_override: r.get(3)?,
            })
        },
    )?;
    Ok(row)
}

pub fn release_title_override(conn: &Connection, release_mbid: &str) -> anyhow::Result<TitleOverride> {
    let row = conn.query_row(
        "SELECT
            (SELECT title FROM release_title_alt WHERE release_mbid = ?1 AND kind = 'translit'),
            (SELECT title FROM release_title_alt WHERE release_mbid = ?1 AND kind = 'translate'),
            (SELECT translit  FROM release_title_override WHERE release_mbid = ?1),
            (SELECT translate FROM release_title_override WHERE release_mbid = ?1)",
        [release_mbid],
        |r| {
            Ok(TitleOverride {
                translit: r.get(0)?,
                translate: r.get(1)?,
                translit_override: r.get(2)?,
                translate_override: r.get(3)?,
            })
        },
    )?;
    Ok(row)
}

pub fn set_track_title_override(
    conn: &Connection,
    recording_mbid: &str,
    translit: Option<String>,
    translate: Option<String>,
) -> anyhow::Result<()> {
    if translit.is_none() && translate.is_none() {
        conn.execute(
            "DELETE FROM track_title_override WHERE recording_mbid = ?1",
            [recording_mbid],
        )?;
    } else {
        conn.execute(
            "INSERT INTO track_title_override(recording_mbid, translit, translate) VALUES (?1, ?2, ?3)
             ON CONFLICT(recording_mbid) DO UPDATE SET translit = excluded.translit, translate = excluded.translate",
            rusqlite::params![recording_mbid, translit, translate],
        )?;
    }
    Ok(())
}

pub fn set_release_title_override(
    conn: &Connection,
    release_mbid: &str,
    translit: Option<String>,
    translate: Option<String>,
) -> anyhow::Result<()> {
    if translit.is_none() && translate.is_none() {
        conn.execute(
            "DELETE FROM release_title_override WHERE release_mbid = ?1",
            [release_mbid],
        )?;
    } else {
        conn.execute(
            "INSERT INTO release_title_override(release_mbid, translit, translate) VALUES (?1, ?2, ?3)
             ON CONFLICT(release_mbid) DO UPDATE SET translit = excluded.translit, translate = excluded.translate",
            rusqlite::params![release_mbid, translit, translate],
        )?;
    }
    Ok(())
}
```

- [ ] **Step 6: Run to verify pass; lint; commit**

Run: `cd rust && cargo test --test title_override_test` (expect 2 pass), `cd rust && cargo build`, `just lint --all` (expect PASS). Then:

```bash
git add rust/src/db.rs rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/tests/title_override_test.rs
git commit -m "$(cat <<'EOF'
Add track/album title-override tables + getter/setter

Per-recording / per-release reading+translation overrides (NULL=auto,
''=suppress, text=override), with a getter returning enriched + override
values and a setter that deletes the row when fully automatic.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: COALESCE overrides into the display queries

**Files:**
- Modify: `rust/src/catalog/query.rs` (`albums_for_artist`, `tracks_for_album`, `tracks_for_paths`)
- Test: `rust/tests/title_override_test.rs` (extend)

- [ ] **Step 1: Write the failing display tests**

Append to `rust/tests/title_override_test.rs` (imports for the three query fns + adjust the existing import line):

```rust
use rust_lib_olivier::catalog::query::{albums_for_artist, tracks_for_album, tracks_for_paths};

#[test]
fn override_beats_enriched_in_displays() {
    let conn = open(":memory:").unwrap();
    seed(&conn);
    conn.execute(
        "INSERT INTO file(id,path,mtime,size,track_id,added_at) VALUES (1,'/m/x.flac',0,0,1,0)",
        [],
    )
    .unwrap();
    set_track_title_override(&conn, "REC", Some("MyReading".into()), Some("".into())).unwrap();
    set_release_title_override(&conn, "R", Some("MyAlbumReading".into()), None).unwrap();

    let tracks = tracks_for_album(&conn, "R").unwrap();
    assert_eq!(tracks[0].title_translit.as_deref(), Some("MyReading")); // override beats "Kyoku"
    assert_eq!(tracks[0].title_translate, None); // '' suppress -> None

    let albums = albums_for_artist(&conn, "A").unwrap();
    assert_eq!(albums[0].title_translit.as_deref(), Some("MyAlbumReading"));

    let q = tracks_for_paths(&conn, &["/m/x.flac".to_string()]).unwrap();
    assert_eq!(q[0].title_translit.as_deref(), Some("MyReading"));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd rust && cargo test --test title_override_test`
Expected: FAIL (assertions: still shows enriched "Kyoku"/"Arubamu", translate not suppressed).

- [ ] **Step 3: COALESCE in `albums_for_artist`**

In `albums_for_artist`, replace the two `release_title_alt` subqueries (the `title_translit`/`title_translate` columns) with override-coalesced, suppress-aware versions:

```sql
                NULLIF(COALESCE(
                    (SELECT translit FROM release_title_override WHERE release_mbid = r.mbid),
                    (SELECT title FROM release_title_alt WHERE release_mbid = r.mbid AND kind = 'translit')
                ), ''),
                NULLIF(COALESCE(
                    (SELECT translate FROM release_title_override WHERE release_mbid = r.mbid),
                    (SELECT title FROM release_title_alt WHERE release_mbid = r.mbid AND kind = 'translate')
                ), ''),
```

- [ ] **Step 4: COALESCE in `tracks_for_album`**

In `tracks_for_album`, replace the `MAX(CASE WHEN tta.kind = 'translit' …)` / `'translate'` columns with:

```sql
                NULLIF(COALESCE(
                    (SELECT translit FROM track_title_override WHERE recording_mbid = t.recording_mbid),
                    MAX(CASE WHEN tta.kind = 'translit' THEN tta.title END)
                ), ''),
                NULLIF(COALESCE(
                    (SELECT translate FROM track_title_override WHERE recording_mbid = t.recording_mbid),
                    MAX(CASE WHEN tta.kind = 'translate' THEN tta.title END)
                ), ''),
```

(The correlated subquery is constant per `GROUP BY t.recording_mbid` group, so it composes with the `MAX` aggregates.)

- [ ] **Step 5: COALESCE in `tracks_for_paths`**

In `tracks_for_paths`, replace the two `track_title_alt` subqueries the same way:

```sql
                NULLIF(COALESCE(
                    (SELECT translit FROM track_title_override WHERE recording_mbid = t.recording_mbid),
                    (SELECT title FROM track_title_alt WHERE recording_mbid = t.recording_mbid AND kind = 'translit')
                ), ''),
                NULLIF(COALESCE(
                    (SELECT translate FROM track_title_override WHERE recording_mbid = t.recording_mbid),
                    (SELECT title FROM track_title_alt WHERE recording_mbid = t.recording_mbid AND kind = 'translate')
                ), ''),
```

- [ ] **Step 6: Run to verify pass; full suite; lint; commit**

Run: `cd rust && cargo test --test title_override_test` (expect 3 pass), `cd rust && cargo test` (FULL suite green — the existing track/album/queue tests still pass; the NULLIF(COALESCE(...)) is a no-op when no override row exists), `just lint --all`. Then:

```bash
git add rust/src/catalog/query.rs rust/tests/title_override_test.rs
git commit -m "$(cat <<'EOF'
COALESCE title overrides over enriched in display queries

albums_for_artist, tracks_for_album, and tracks_for_paths now prefer the
manual override (NULLIF(...,'') maps a '' suppress to no value). No-op when
no override row exists.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: FFI wrappers + bridge regen

**Files:**
- Modify: `rust/src/api/catalog.rs`
- Regenerate: `lib/src/rust/**`, `rust/src/frb_generated.rs`

- [ ] **Step 1: Add the FFI wrappers**

In `rust/src/api/catalog.rs`, add (mirroring `artist_reading` / `set_artist_reading_override`; `TitleOverride` is already imported via the `schema::{...}` use — add it there):

```rust
pub fn track_title_override(db_path: String, recording_mbid: String) -> anyhow::Result<TitleOverride> {
    query::track_title_override(&db::open(&db_path)?, &recording_mbid)
}

pub fn release_title_override(db_path: String, release_mbid: String) -> anyhow::Result<TitleOverride> {
    query::release_title_override(&db::open(&db_path)?, &release_mbid)
}

pub fn set_track_title_override(
    db_path: String,
    recording_mbid: String,
    translit: Option<String>,
    translate: Option<String>,
) -> anyhow::Result<()> {
    query::set_track_title_override(&db::open(&db_path)?, &recording_mbid, translit, translate)
}

pub fn set_release_title_override(
    db_path: String,
    release_mbid: String,
    translit: Option<String>,
    translate: Option<String>,
) -> anyhow::Result<()> {
    query::set_release_title_override(&db::open(&db_path)?, &release_mbid, translit, translate)
}
```

- [ ] **Step 2: cargo build, regen, verify**

Run: `cd rust && cargo build` (compiles). Then `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`. Verify: `grep -nE 'setTrackTitleOverride|trackTitleOverride|TitleOverride' lib/src/rust/api/catalog.dart lib/src/rust/catalog/schema.dart` shows the generated fns + the `TitleOverride` class. Run `mise exec -- flutter analyze` (No issues).

- [ ] **Step 3: Lint + commit**

Run: `just lint --all` (PASS). Then:

```bash
git add rust/src/api/catalog.rs lib/src/rust rust/src/frb_generated.rs
git commit -m "$(cat <<'EOF'
Add title-override FFI + regenerate bridge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Flutter dialog + seam providers

**Files:**
- Create: `lib/widgets/title_override_dialog.dart`
- Modify: `lib/state/providers.dart` (seam providers)
- Test: `test/title_override_dialog_test.dart`

- [ ] **Step 1: Add seam providers**

In `lib/state/providers.dart`, add (mirroring `artistReadingFnProvider` / `setArtistReadingOverrideFnProvider`; `TitleOverride` + the four fns come from the already-imported `package:olivier/src/rust/api/catalog.dart`):

```dart
typedef TitleOverrideFn = Future<TitleOverride> Function(String mbid);
typedef SetTitleOverrideFn = Future<void> Function(
    String mbid, String? translit, String? translate);

final trackTitleOverrideFnProvider = Provider<TitleOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid) => trackTitleOverride(dbPath: db, recordingMbid: mbid);
});
final releaseTitleOverrideFnProvider = Provider<TitleOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid) => releaseTitleOverride(dbPath: db, releaseMbid: mbid);
});
final setTrackTitleOverrideFnProvider = Provider<SetTitleOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid, t, tr) =>
      setTrackTitleOverride(dbPath: db, recordingMbid: mbid, translit: t, translate: tr);
});
final setReleaseTitleOverrideFnProvider = Provider<SetTitleOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid, t, tr) =>
      setReleaseTitleOverride(dbPath: db, releaseMbid: mbid, translit: t, translate: tr);
});
```

(Add `import 'package:olivier/src/rust/catalog/schema.dart';` is already present in providers.dart; `TitleOverride` is exported from the rust api/schema bindings — import whichever the generated `TitleOverride` lives in.)

- [ ] **Step 2: Write the failing dialog test**

Create `test/title_override_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/title_override_dialog.dart';

void main() {
  group('overrideTitleValue', () {
    test('unchanged from enriched -> null (automatic)', () {
      expect(overrideTitleValue('Kyoku', 'Kyoku'), isNull);
      expect(overrideTitleValue('', null), isNull); // both empty
    });
    test('cleared a non-empty enriched -> "" (suppress)', () {
      expect(overrideTitleValue('', 'Kyoku'), '');
    });
    test('edited -> the text (override)', () {
      expect(overrideTitleValue('NewReading', 'Kyoku'), 'NewReading');
    });
  });
}
```

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- flutter test test/title_override_dialog_test.dart`
Expected: FAIL (URI/`overrideTitleValue` not found).

- [ ] **Step 4: Create the dialog**

Create `lib/widgets/title_override_dialog.dart` (mirrors `ArtistReadingDialog`; the save mapping differs — empty clears to a suppress):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/api/catalog.dart' show TitleOverride;

/// Map a dialog field to a stored override value: unchanged from the enriched
/// value -> null (automatic); cleared a non-empty enriched value -> '' (suppress
/// — hide the wrong auto value); otherwise the trimmed text (override).
String? overrideTitleValue(String field, String? enriched) {
  final v = field.trim();
  if (v == (enriched ?? '')) return null;
  if (v.isEmpty) return '';
  return v;
}

/// Loads the current reading/translation (enriched + override) for [mbid], shows
/// the dialog, and on Save persists via [onSubmit] and runs [onSaved] (refresh).
Future<void> showTitleOverrideDialog(
  BuildContext context, {
  required String label,
  required TitleOverride current,
  required Future<void> Function(String? translit, String? translate) onSubmit,
  required void Function() onSaved,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => TitleOverrideDialog(
      label: label,
      current: current,
      onSubmit: (t, tr) async {
        await onSubmit(t, tr);
        onSaved();
      },
    ),
  );
}

class TitleOverrideDialog extends StatefulWidget {
  const TitleOverrideDialog({
    super.key,
    required this.label,
    required this.current,
    required this.onSubmit,
  });

  final String label;
  final TitleOverride current;
  final Future<void> Function(String? translit, String? translate) onSubmit;

  @override
  State<TitleOverrideDialog> createState() => _TitleOverrideDialogState();
}

class _TitleOverrideDialogState extends State<TitleOverrideDialog> {
  late final TextEditingController _reading = TextEditingController(
    text: widget.current.translitOverride ?? widget.current.translit ?? '',
  );
  late final TextEditingController _translation = TextEditingController(
    text: widget.current.translateOverride ?? widget.current.translate ?? '',
  );

  @override
  void dispose() {
    _reading.dispose();
    _translation.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = overrideTitleValue(_reading.text, widget.current.translit);
    final tr = overrideTitleValue(_translation.text, widget.current.translate);
    await widget.onSubmit(t, tr);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Set reading — ${widget.label}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _reading,
              decoration: InputDecoration(
                labelText: 'Reading',
                helperText: 'MusicBrainz: ${widget.current.translit ?? '—'}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _translation,
              decoration: InputDecoration(
                labelText: 'Translation',
                helperText: 'MusicBrainz: ${widget.current.translate ?? '—'}',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
```

(Confirm the generated field names on `TitleOverride` — `translitOverride` / `translateOverride` / `translit` / `translate`; adjust if frb names them differently.)

- [ ] **Step 5: Run to verify pass; analyze; commit**

Run: `mise exec -- flutter test test/title_override_dialog_test.dart` (3 pass), `mise exec -- flutter analyze` (clean), `mise exec -- dart format` the new/changed files. Then:

```bash
git add lib/widgets/title_override_dialog.dart lib/state/providers.dart test/title_override_dialog_test.dart
git commit -m "$(cat <<'EOF'
Add TitleOverrideDialog + seam providers

Reading/translation override dialog mirroring ArtistReadingDialog; the save
mapping treats a cleared non-empty field as a suppress. Seam providers for
the track/release getters + setters.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire "Set reading…" into the track and album menus

**Files:**
- Modify: `lib/catalog/track_column.dart`, `lib/catalog/album_column.dart`
- Test: `test/album_column_enqueue_test.dart`, `test/track_column_select_test.dart`

- [ ] **Step 1: Write the failing menu tests**

In `test/album_column_enqueue_test.dart`, add a test that right-clicking an album shows "Set reading…" and tapping it loads + opens the dialog (override the `releaseTitleOverrideFnProvider` to return a stub `TitleOverride`, and assert `find.text('Set reading…')` then, after tapping, `find.byType(TitleOverrideDialog)` is present). Mirror the existing `kSecondaryButton` right-click test pattern in that file. Do the analogous test in `test/track_column_select_test.dart` for a track (override `trackTitleOverrideFnProvider`).

(Exact widget-test body follows the existing right-click tests in those files: `startGesture(buttons: kSecondaryButton)` → `up()` → `pumpAndSettle()` → assert the menu item → tap → `pumpAndSettle()` → assert the dialog. Build a `TitleOverride(translit: ..., translate: ..., translitOverride: null, translateOverride: null)` stub in the provider override.)

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/album_column_enqueue_test.dart test/track_column_select_test.dart`
Expected: FAIL — "Set reading…" not found (track/album menus don't pass `onSetReading` yet).

- [ ] **Step 3: Wire the album menu**

In `lib/catalog/album_column.dart`, add `onSetReading` to the album's `RowContextMenu` (it already supports the callback — artists use it):

```dart
            onSetReading: (_) async {
              final messenger = ScaffoldMessenger.of(context);
              final current = await ref.read(releaseTitleOverrideFnProvider)(album.releaseMbid);
              if (!context.mounted) return;
              await showTitleOverrideDialog(
                context,
                label: album.title,
                current: current,
                onSubmit: (t, tr) => ref
                    .read(setReleaseTitleOverrideFnProvider)(album.releaseMbid, t, tr),
                onSaved: () {
                  ref.invalidate(albumsProvider);
                  ref.invalidate(tracksProvider);
                  ref.read(queueControllerProvider).refreshMetadata();
                  messenger
                    ..clearSnackBars()
                    ..showSnackBar(const SnackBar(content: Text('Reading updated')));
                },
              );
            },
```

Add the import `import 'package:olivier/widgets/title_override_dialog.dart';`.

- [ ] **Step 4: Wire the track menu**

In `lib/catalog/track_column.dart`, add `onSetReading` to the track's `RowContextMenu`:

```dart
                  onSetReading: (_) async {
                    final messenger = ScaffoldMessenger.of(context);
                    final current =
                        await ref.read(trackTitleOverrideFnProvider)(track.recordingMbid);
                    if (!context.mounted) return;
                    await showTitleOverrideDialog(
                      context,
                      label: track.title,
                      current: current,
                      onSubmit: (t, tr) => ref
                          .read(setTrackTitleOverrideFnProvider)(track.recordingMbid, t, tr),
                      onSaved: () {
                        ref.invalidate(tracksProvider);
                        ref.read(queueControllerProvider).refreshMetadata();
                        messenger
                          ..clearSnackBars()
                          ..showSnackBar(const SnackBar(content: Text('Reading updated')));
                      },
                    );
                  },
```

Add the import `import 'package:olivier/widgets/title_override_dialog.dart';`. (Confirm the `Track` field for the recording MBID — `track.recordingMbid`; adjust to the actual generated field name.)

- [ ] **Step 5: Run to verify pass; analyze; full suite; lint; commit**

Run: `mise exec -- flutter test test/album_column_enqueue_test.dart test/track_column_select_test.dart` (pass), `mise exec -- flutter analyze` (clean), `mise exec -- flutter test` (full suite green), `just lint --all` (PASS). Then:

```bash
git add lib/catalog/album_column.dart lib/catalog/track_column.dart test/album_column_enqueue_test.dart test/track_column_select_test.dart
git commit -m "$(cat <<'EOF'
Wire Set reading… into the track and album menus

Right-click "Set reading…" on a track or album opens the override dialog
(loads current values, persists on save, refreshes the lists).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `cd rust && cargo test` — all green (incl. `title_override_test`).
- [ ] `mise exec -- flutter test` — full suite green.
- [ ] `just lint --all` — green.
- [ ] Manual (optional): right-click a track/album → "Set reading…" → edit Reading/Translation (clear a field to suppress) → Save → the list reflects it; re-fetch the album → the override persists.

## Touched files

| File | Change |
|------|--------|
| `rust/src/db.rs` | migration: 2 override tables |
| `rust/src/catalog/schema.rs` | `TitleOverride` struct |
| `rust/src/catalog/query.rs` | getter/setter + COALESCE in 3 display queries |
| `rust/src/api/catalog.rs` | 4 FFI wrappers |
| `lib/src/rust/**`, `rust/src/frb_generated.rs` | regenerated bridge |
| `lib/widgets/title_override_dialog.dart` | dialog + `overrideTitleValue` |
| `lib/state/providers.dart` | 4 seam providers |
| `lib/catalog/album_column.dart`, `track_column.dart` | `onSetReading` → dialog |
| `rust/tests/title_override_test.rs`, `test/title_override_dialog_test.dart`, column tests | tests |
