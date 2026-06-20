# Per-Artist Reading + Sort Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user manually override an album-artist's displayed reading and sort position, persisted per-artist and surviving MusicBrainz re-enrichment, edited from the artist right-click menu.

**Architecture:** Two nullable columns on `artist` (`transliteration_override`, `sort_name_override`); `artists_page` returns `COALESCE(override, mb_value)` so display, sort, and keyset pagination stay consistent; enrichment never touches the override columns. Two new FFIs (`artist_reading` to load raw values, `set_artist_reading_override` to write/clear) feed a Riverpod-seamed "Set reading…" dialog wired into the existing `RowContextMenu`.

**Tech Stack:** Rust (rusqlite, rusqlite_migration), flutter_rust_bridge 2.x, Flutter + Riverpod 3.x.

**Spec:** `docs/superpowers/specs/2026-06-20-artist-reading-override-design.md`

**Conventions for every task:**
- Rust tests run with `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test`.
- Dart tests run with `cd /home/autarch/projects/olivier && mise exec -- flutter test`.
- Commit message trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- NEVER `git add` the `TODO` file or the untracked `#TODO#` autosave; stage only the files each task lists.
- The repo has no remote; do not push.

---

## File Structure

- `rust/src/db.rs` — append one migration adding the two override columns.
- `rust/src/catalog/schema.rs` — new `ArtistReading` struct.
- `rust/src/catalog/query.rs` — `artists_page` COALESCE; new `artist_reading`, `set_artist_reading_override`.
- `rust/src/api/catalog.rs` — two new FFI wrappers.
- `rust/src/frb_generated.rs`, `lib/src/rust/**` — regenerated bridge (do not hand-edit).
- `lib/state/providers.dart` — two fn-provider seams + typedefs.
- `lib/widgets/artist_reading_dialog.dart` — new: `overrideValue` helper, `ArtistReadingDialog`, `showArtistReadingDialog`.
- `lib/widgets/context_menu.dart` — `onSetReading` callback + "Set reading…" item.
- `lib/catalog/artist_column.dart` — wire `onSetReading`.
- `rust/tests/catalog_test.rs` — Rust round-trip tests.
- `test/artist_reading_dialog_test.dart` — `overrideValue` + dialog tests.
- `test/context_menu_test.dart` — menu-item test.
- `test/catalog/artist_column_test.dart` — menu-presence test.

---

### Task 1: Migration — add override columns

**Files:**
- Modify: `rust/src/db.rs` (append to `MIGRATION_SLICE`, after the Phase 2b `name_original` migration ~line 102)
- Test: `rust/tests/catalog_test.rs`

- [ ] **Step 1: Write the failing test**

Add to `rust/tests/catalog_test.rs`:

```rust
#[test]
fn migration_adds_artist_override_columns() {
    let conn = open(":memory:").unwrap();
    // pragma_table_info lists every column; both override columns must exist.
    let n: i64 = conn
        .query_row(
            "SELECT count(*) FROM pragma_table_info('artist')
             WHERE name IN ('transliteration_override', 'sort_name_override')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 2);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test migration_adds_artist_override_columns`
Expected: FAIL (count is 0, columns don't exist yet).

- [ ] **Step 3: Add the migration**

In `rust/src/db.rs`, append a new entry to `MIGRATION_SLICE` immediately after the existing
`M::up("ALTER TABLE artist ADD COLUMN name_original TEXT;"),` line (keep the closing `];`):

```rust
    // ── Per-artist manual reading + sort override ────────────────────────
    M::up(
        "ALTER TABLE artist ADD COLUMN transliteration_override TEXT;
         ALTER TABLE artist ADD COLUMN sort_name_override TEXT;",
    ),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test migration_adds_artist_override_columns`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/autarch/projects/olivier
git add rust/src/db.rs rust/tests/catalog_test.rs
git commit -m "Add artist transliteration/sort override columns

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `ArtistReading` struct + `artist_reading` + `set_artist_reading_override`

**Files:**
- Modify: `rust/src/catalog/schema.rs` (add `ArtistReading`)
- Modify: `rust/src/catalog/query.rs` (add two functions)
- Test: `rust/tests/catalog_test.rs`

- [ ] **Step 1: Write the failing test**

Add to `rust/tests/catalog_test.rs`. Extend the existing query `use` to include the new
functions and the struct (replace the `use rust_lib_olivier::catalog::query::{…}` block's
closing to add `artist_reading, set_artist_reading_override`, and add a `use` for the struct):

```rust
use rust_lib_olivier::catalog::query::{
    albums_for_artist, artist_reading, artists_page, file_paths_for_album, record_play,
    set_artist_reading_override, track_path, track_paths_for_artist, track_paths_for_library,
    tracks_for_album, tracks_for_paths,
};
use rust_lib_olivier::catalog::schema::ArtistReading;
```

```rust
#[test]
fn artist_reading_round_trip_and_clear() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name, transliteration, name_original)
         VALUES ('m', '椎名林檎', 'Sheena, Ringo', 'Sheena Ringo', '椎名林檎')",
        [],
    )
    .unwrap();

    // Raw read before any override: mb_* populated, *_override null.
    let r: ArtistReading = artist_reading(&conn, "m").unwrap();
    assert_eq!(r.name, "椎名林檎");
    assert_eq!(r.name_original.as_deref(), Some("椎名林檎"));
    assert_eq!(r.mb_transliteration.as_deref(), Some("Sheena Ringo"));
    assert_eq!(r.mb_sort_name, "Sheena, Ringo");
    assert_eq!(r.transliteration_override, None);
    assert_eq!(r.sort_name_override, None);

    // Write an override for both dimensions.
    set_artist_reading_override(&conn, "m", Some("Shiina Ringo"), Some("Shiina, Ringo")).unwrap();
    let r = artist_reading(&conn, "m").unwrap();
    assert_eq!(r.transliteration_override.as_deref(), Some("Shiina Ringo"));
    assert_eq!(r.sort_name_override.as_deref(), Some("Shiina, Ringo"));
    // The MB values are untouched.
    assert_eq!(r.mb_transliteration.as_deref(), Some("Sheena Ringo"));
    assert_eq!(r.mb_sort_name, "Sheena, Ringo");

    // Clearing sets both back to null.
    set_artist_reading_override(&conn, "m", None, None).unwrap();
    let r = artist_reading(&conn, "m").unwrap();
    assert_eq!(r.transliteration_override, None);
    assert_eq!(r.sort_name_override, None);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test artist_reading_round_trip_and_clear`
Expected: FAIL to compile (`artist_reading` / `set_artist_reading_override` / `ArtistReading` don't exist).

- [ ] **Step 3: Add the `ArtistReading` struct**

In `rust/src/catalog/schema.rs`, add after the `Artist` struct (same derive as its siblings):

```rust
/// Raw (non-coalesced) reading/sort fields for one artist — populates the
/// "Set reading" edit dialog so it can show the current override alongside the
/// MusicBrainz value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtistReading {
    pub name: String,
    pub name_original: Option<String>,
    pub mb_transliteration: Option<String>,
    pub transliteration_override: Option<String>,
    pub mb_sort_name: String,
    pub sort_name_override: Option<String>,
}
```

- [ ] **Step 4: Add the two query functions**

In `rust/src/catalog/query.rs`, update the schema `use` on line 1 to include `ArtistReading`:

```rust
use crate::catalog::schema::{Album, Artist, ArtistReading, QueueTrack, Track};
```

Then add these two functions (e.g. right after `artists_page`):

```rust
/// Raw reading/sort fields for one artist (for the edit dialog).
pub fn artist_reading(conn: &Connection, mbid: &str) -> anyhow::Result<ArtistReading> {
    let r = conn.query_row(
        "SELECT name, name_original, transliteration, transliteration_override,
                sort_name, sort_name_override
         FROM artist WHERE mbid = ?1",
        [mbid],
        |r| {
            Ok(ArtistReading {
                name: r.get(0)?,
                name_original: r.get(1)?,
                mb_transliteration: r.get(2)?,
                transliteration_override: r.get(3)?,
                mb_sort_name: r.get(4)?,
                sort_name_override: r.get(5)?,
            })
        },
    )?;
    Ok(r)
}

/// Set or clear an artist's manual reading/sort overrides. `None` clears that
/// dimension (falls back to the MusicBrainz value via COALESCE in `artists_page`).
pub fn set_artist_reading_override(
    conn: &Connection,
    mbid: &str,
    reading: Option<&str>,
    sort: Option<&str>,
) -> anyhow::Result<()> {
    conn.execute(
        "UPDATE artist
            SET transliteration_override = ?2, sort_name_override = ?3
          WHERE mbid = ?1",
        rusqlite::params![mbid, reading, sort],
    )?;
    Ok(())
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test artist_reading_round_trip_and_clear`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/tests/catalog_test.rs
git commit -m "Add artist_reading + set_artist_reading_override queries

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `artists_page` returns effective (overridden) reading + sort

**Files:**
- Modify: `rust/src/catalog/query.rs:12-17` (the `artists_page` SQL)
- Test: `rust/tests/catalog_test.rs`

- [ ] **Step 1: Write the failing test**

Add to `rust/tests/catalog_test.rs`:

```rust
#[test]
fn artists_page_applies_reading_and_sort_override() {
    let conn = open(":memory:").unwrap();
    // 椎名林檎: MB romanization "Sheena", which the user prefers as "Shiina".
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name, transliteration, name_original)
         VALUES ('m-ringo', '椎名林檎', 'Sheena, Ringo', 'Sheena Ringo', '椎名林檎')",
        [],
    )
    .unwrap();
    // A second artist that sorts BETWEEN the MB ("Sheena") and override ("Shiina").
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('m-sg', 'Sheena G', 'Shenagan, X')",
        [],
    )
    .unwrap();
    for (rel, mbid) in [("r-ringo", "m-ringo"), ("r-sg", "m-sg")] {
        conn.execute(
            "INSERT INTO release(mbid, album_artist_mbid, title) VALUES (?1, ?2, 'X')",
            rusqlite::params![rel, mbid],
        )
        .unwrap();
    }

    // Before override: ordered by MB sort_name → "Sheena, Ringo" < "Shenagan, X".
    let page = artists_page(&conn, None, 50).unwrap();
    assert_eq!(page[0].mbid, "m-ringo");
    assert_eq!(page[1].mbid, "m-sg");

    // Override Ringo to read + sort as "Shiina"; now "Shenagan" < "Shiina".
    set_artist_reading_override(&conn, "m-ringo", Some("Shiina Ringo"), Some("Shiina, Ringo"))
        .unwrap();
    let page = artists_page(&conn, None, 50).unwrap();
    // Effective reading + sort reflect the override.
    let ringo = page.iter().find(|a| a.mbid == "m-ringo").unwrap();
    assert_eq!(ringo.transliteration.as_deref(), Some("Shiina Ringo"));
    assert_eq!(ringo.sort_name, "Shiina, Ringo");
    // Order changed: the override moved Ringo after "Shenagan, X".
    assert_eq!(page[0].mbid, "m-sg");
    assert_eq!(page[1].mbid, "m-ringo");

    // Keyset cursor uses the effective sort: after "Shenagan, X" → only Ringo.
    let page2 = artists_page(&conn, Some("Shenagan, X"), 50).unwrap();
    assert_eq!(page2.len(), 1);
    assert_eq!(page2[0].mbid, "m-ringo");
}

#[test]
fn override_survives_reenrichment() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name, transliteration)
         VALUES ('m', '椎名林檎', 'Sheena, Ringo', 'Sheena Ringo')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r', 'm', 'X')",
        [],
    )
    .unwrap();
    set_artist_reading_override(&conn, "m", Some("Shiina Ringo"), Some("Shiina, Ringo")).unwrap();

    // Simulate a MusicBrainz re-enrichment writing fresh MB values (the exact
    // statement enrich/store.rs uses). It must NOT disturb the override.
    conn.execute(
        "UPDATE artist SET transliteration = ?1, sort_name = ?2, name_original = ?3 WHERE mbid = ?4",
        rusqlite::params!["Sheena Ringo (new)", "Sheena, Ringo (new)", "椎名林檎", "m"],
    )
    .unwrap();

    let page = artists_page(&conn, None, 50).unwrap();
    assert_eq!(page[0].transliteration.as_deref(), Some("Shiina Ringo"));
    assert_eq!(page[0].sort_name, "Shiina, Ringo");

    // Clearing the override falls back to the (new) MB values.
    set_artist_reading_override(&conn, "m", None, None).unwrap();
    let page = artists_page(&conn, None, 50).unwrap();
    assert_eq!(page[0].transliteration.as_deref(), Some("Sheena Ringo (new)"));
    assert_eq!(page[0].sort_name, "Sheena, Ringo (new)");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test override`
Expected: FAIL (effective values still equal the MB values; ordering unchanged).

- [ ] **Step 3: Update `artists_page` to coalesce**

In `rust/src/catalog/query.rs`, replace the SQL string in `artists_page` (lines 12-17) with:

```rust
        "SELECT a.mbid, a.name,
                COALESCE(a.sort_name_override, a.sort_name)             AS sort_name,
                COALESCE(a.transliteration_override, a.transliteration) AS transliteration,
                a.name_original
         FROM artist a
         WHERE a.mbid IN (SELECT DISTINCT album_artist_mbid FROM release)
           AND (?1 IS NULL
                OR COALESCE(a.sort_name_override, a.sort_name) > ?1 COLLATE NOCASE)
         ORDER BY COALESCE(a.sort_name_override, a.sort_name) COLLATE NOCASE LIMIT ?2",
```

(The `query_map` closure is unchanged: columns 0-4 are still mbid, name, sort_name, transliteration, name_original.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test`
Expected: PASS (the new tests plus all existing `artists_page_*` tests, which use no overrides and so see `COALESCE(NULL, mb) == mb`).

- [ ] **Step 5: Commit**

```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/query.rs rust/tests/catalog_test.rs
git commit -m "artists_page: return effective (overridden) reading and sort

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: FFI wrappers + bridge regeneration

**Files:**
- Modify: `rust/src/api/catalog.rs`
- Regenerate: `rust/src/frb_generated.rs`, `lib/src/rust/**` (do not hand-edit)

- [ ] **Step 1: Add the FFI wrappers**

In `rust/src/api/catalog.rs`, add `ArtistReading` to the schema import on line 4:

```rust
use crate::catalog::schema::{Album, Artist, ArtistReading, QueueTrack, Track};
```

Then add (e.g. after `list_artists`):

```rust
pub fn artist_reading(db_path: String, mbid: String) -> anyhow::Result<ArtistReading> {
    query::artist_reading(&db::open(&db_path)?, &mbid)
}

pub fn set_artist_reading_override(
    db_path: String,
    mbid: String,
    reading: Option<String>,
    sort: Option<String>,
) -> anyhow::Result<()> {
    query::set_artist_reading_override(
        &db::open(&db_path)?,
        &mbid,
        reading.as_deref(),
        sort.as_deref(),
    )
}
```

- [ ] **Step 2: Verify Rust still builds and tests pass**

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test`
Expected: PASS (all tests). If `<new-diagnostics>` reports stale errors mid-edit, trust `cargo test`, not the diagnostics.

- [ ] **Step 3: Regenerate the bridge**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`
Expected: regenerates `lib/src/rust/**` and `rust/src/frb_generated.rs`. Confirm the new symbols exist:

Run: `grep -rn "artistReading\|setArtistReadingOverride\|class ArtistReading" lib/src/rust/`
Expected: `artistReading` + `setArtistReadingOverride` functions in `lib/src/rust/api/catalog.dart` and a `class ArtistReading` in `lib/src/rust/catalog/schema.dart`.

- [ ] **Step 4: Confirm Dart still analyzes**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter analyze lib/src/rust 2>&1 | tail -3`
Expected: No issues.

- [ ] **Step 5: Commit (include the regenerated bridge)**

```bash
cd /home/autarch/projects/olivier
git add rust/src/api/catalog.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "Expose artist_reading + set_artist_reading_override over FFI

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Dart provider seams

**Files:**
- Modify: `lib/state/providers.dart` (add two typedefs + two providers, after `rereadTrackTagsFnProvider` ~line 134)

- [ ] **Step 1: Add the seams**

In `lib/state/providers.dart`, add (the `artistReading` / `setArtistReadingOverride` bridge
functions come from the already-imported `package:olivier/src/rust/api/catalog.dart`; the
`ArtistReading` type from the already-imported `…/catalog/schema.dart`):

```dart
// Loads one artist's raw reading/sort values for the "Set reading" dialog. Seam.
typedef ArtistReadingFn = Future<ArtistReading> Function(String mbid);

final artistReadingFnProvider = Provider<ArtistReadingFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid) => artistReading(dbPath: db, mbid: mbid);
});

// Writes/clears one artist's reading + sort override. Seam.
typedef SetArtistReadingOverrideFn =
    Future<void> Function(String mbid, String? reading, String? sort);

final setArtistReadingOverrideFnProvider =
    Provider<SetArtistReadingOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid, reading, sort) => setArtistReadingOverride(
        dbPath: db, mbid: mbid, reading: reading, sort: sort);
});
```

- [ ] **Step 2: Verify it analyzes**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter analyze lib/state/providers.dart 2>&1 | tail -3`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
cd /home/autarch/projects/olivier
git add lib/state/providers.dart
git commit -m "Add artist-reading override FFI seams

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `overrideValue` helper + `ArtistReadingDialog` + `showArtistReadingDialog`

**Files:**
- Create: `lib/widgets/artist_reading_dialog.dart`
- Test: `test/artist_reading_dialog_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/artist_reading_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/artist_reading_dialog.dart';

const _reading = ArtistReading(
  name: '椎名林檎',
  nameOriginal: '椎名林檎',
  mbTransliteration: 'Sheena Ringo',
  transliterationOverride: null,
  mbSortName: 'Sheena, Ringo',
  sortNameOverride: null,
);

void main() {
  group('overrideValue', () {
    test('empty or whitespace → null', () {
      expect(overrideValue('', 'Sheena'), isNull);
      expect(overrideValue('   ', 'Sheena'), isNull);
    });
    test('equals MB value (trimmed) → null', () {
      expect(overrideValue('Sheena', 'Sheena'), isNull);
      expect(overrideValue('  Sheena  ', 'Sheena'), isNull);
    });
    test('differs from MB → trimmed value', () {
      expect(overrideValue('Shiina', 'Sheena'), 'Shiina');
      expect(overrideValue('  Shiina  ', 'Sheena'), 'Shiina');
    });
    test('MB null + non-empty → value', () {
      expect(overrideValue('Shiina', null), 'Shiina');
    });
  });

  testWidgets('dialog prefills fields and Save submits computed overrides',
      (tester) async {
    String? gotReading = 'unset';
    String? gotSort = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArtistReadingDialog(
          reading: _reading,
          onSubmit: (r, s) async {
            gotReading = r;
            gotSort = s;
          },
        ),
      ),
    ));

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text,
        'Sheena Ringo');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text,
        'Sheena, Ringo');

    // Prefer "Shiina" for the reading; leave the sort as the MB value.
    await tester.enterText(fields.at(0), 'Shiina Ringo');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(gotReading, 'Shiina Ringo'); // differs from MB → persisted
    expect(gotSort, isNull); // equals MB → no override
  });

  testWidgets('showArtistReadingDialog wires the FFI seam', (tester) async {
    final calls = <(String, String?, String?)>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbPathProvider.overrideWithValue(':memory:'),
        artistReadingFnProvider.overrideWithValue((mbid) async => _reading),
        setArtistReadingOverrideFnProvider
            .overrideWithValue((mbid, r, s) async => calls.add((mbid, r, s))),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () =>
                    showArtistReadingDialog(context, ref, 'm-ringo'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Shiina Ringo');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(calls, [('m-ringo', 'Shiina Ringo', null)]);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/artist_reading_dialog_test.dart`
Expected: FAIL to compile (`artist_reading_dialog.dart` doesn't exist).

- [ ] **Step 3: Create the dialog**

Create `lib/widgets/artist_reading_dialog.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

/// The value to persist for one override dimension: the trimmed field text,
/// unless it is empty or matches the MusicBrainz value, in which case `null`
/// (no override — fall back to MusicBrainz).
String? overrideValue(String field, String? mbValue) {
  final v = field.trim();
  if (v.isEmpty || v == (mbValue ?? '')) return null;
  return v;
}

/// Loads the artist's raw reading/sort, shows [ArtistReadingDialog], and on Save
/// persists the override and refreshes the artist list.
Future<void> showArtistReadingDialog(
  BuildContext context,
  WidgetRef ref,
  String mbid,
) async {
  final reading = await ref.read(artistReadingFnProvider)(mbid);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => ArtistReadingDialog(
      reading: reading,
      onSubmit: (r, s) async {
        await ref.read(setArtistReadingOverrideFnProvider)(mbid, r, s);
        ref.invalidate(artistsProvider);
      },
    ),
  );
}

/// Edit dialog for one artist's reading + sort overrides. Pure: the parent
/// supplies the loaded [reading] and an [onSubmit] that persists the result, so
/// it can be pumped directly in tests.
class ArtistReadingDialog extends StatefulWidget {
  const ArtistReadingDialog({
    super.key,
    required this.reading,
    required this.onSubmit,
  });

  final ArtistReading reading;
  final Future<void> Function(String? reading, String? sort) onSubmit;

  @override
  State<ArtistReadingDialog> createState() => _ArtistReadingDialogState();
}

class _ArtistReadingDialogState extends State<ArtistReadingDialog> {
  late final TextEditingController _reading = TextEditingController(
    text: widget.reading.transliterationOverride ??
        widget.reading.mbTransliteration ??
        '',
  );
  late final TextEditingController _sort = TextEditingController(
    text: widget.reading.sortNameOverride ?? widget.reading.mbSortName,
  );

  @override
  void dispose() {
    _reading.dispose();
    _sort.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final r = overrideValue(_reading.text, widget.reading.mbTransliteration);
    final s = overrideValue(_sort.text, widget.reading.mbSortName);
    await widget.onSubmit(r, s);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final original = widget.reading.nameOriginal ?? widget.reading.name;
    return AlertDialog(
      title: Text('Set reading — $original'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _reading,
              decoration: InputDecoration(
                labelText: 'Reading',
                helperText:
                    'MusicBrainz: ${widget.reading.mbTransliteration ?? '—'}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sort,
              decoration: InputDecoration(
                labelText: 'Sort as',
                helperText: 'MusicBrainz: ${widget.reading.mbSortName}',
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/artist_reading_dialog_test.dart`
Expected: PASS (all 6).

- [ ] **Step 5: Format + commit**

```bash
cd /home/autarch/projects/olivier
mise exec -- dart format lib/widgets/artist_reading_dialog.dart test/artist_reading_dialog_test.dart
git add lib/widgets/artist_reading_dialog.dart test/artist_reading_dialog_test.dart
git commit -m "Add Set-reading dialog + overrideValue helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Context-menu "Set reading…" item

**Files:**
- Modify: `lib/widgets/context_menu.dart`
- Test: `test/context_menu_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/context_menu_test.dart`:

```dart
  testWidgets('shows Set reading… and invokes onSetReading', (tester) async {
    QueueEntityRef? reading;
    const entity = QueueEntityRef.artist('m-1');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RowContextMenu(
          entity: entity,
          onSetReading: (e) => reading = e,
          child: const SizedBox(width: 200, height: 40, child: Text('row')),
        ),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Set reading…'), findsOneWidget);
    await tester.tap(find.text('Set reading…'));
    await tester.pumpAndSettle();
    expect(reading, entity);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/context_menu_test.dart`
Expected: FAIL to compile (`onSetReading` is not a parameter of `RowContextMenu`).

- [ ] **Step 3: Add the callback + item**

In `lib/widgets/context_menu.dart`:

Add the constructor param (after `this.onRefetch,`):

```dart
    this.onSetReading,
```

Add the field (after `final ValueChanged<QueueEntityRef>? onRefetch;`):

```dart
  final ValueChanged<QueueEntityRef>? onSetReading;
```

Add the menu item inside `items: [` (after the `onRefetch` item):

```dart
        if (onSetReading != null)
          const PopupMenuItem<String>(
              value: 'reading', child: Text('Set reading…')),
```

Add the switch case (after `case 'refetch':`):

```dart
      case 'reading':
        onSetReading?.call(entity);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/context_menu_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/autarch/projects/olivier
git add lib/widgets/context_menu.dart test/context_menu_test.dart
git commit -m "Add Set reading… context-menu item

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Wire the dialog into the artist column

**Files:**
- Modify: `lib/catalog/artist_column.dart`
- Test: `test/catalog/artist_column_test.dart`

- [ ] **Step 1: Write the failing test**

`test/catalog/artist_column_test.dart` already has a `_artistApp(QueueController qc,
{EntityPathFns? pathFns})` helper that renders `ArtistColumn` over a single fixed `_artist`
(`Artist(mbid: 'mbid-1', name: 'Test Artist', sortName: 'Artist, Test')`) with `artistsProvider`
and the queue/path seams overridden. Reuse it. First widen the existing gestures import so
`kSecondaryButton` is available — change its `show` list:

```dart
import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout, kSecondaryButton;
```

Add the test (`QueueController` and `FakeQueuePlayer` are already imported by this file):

```dart
  testWidgets('artist row context menu offers Set reading…', (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    await tester.pumpWidget(_artistApp(qc));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Test Artist')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Set reading…'), findsOneWidget);
  });
```

> The menu-presence check needs no FFI — it never opens the dialog, so no
> `artistReadingFnProvider` override is required.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/catalog/artist_column_test.dart`
Expected: FAIL (`Set reading…` not found — the artist row's `RowContextMenu` has no `onSetReading`).

- [ ] **Step 3: Wire `onSetReading`**

In `lib/catalog/artist_column.dart`:

Add the import:

```dart
import 'package:olivier/widgets/artist_reading_dialog.dart';
```

Add to the `RowContextMenu` in the artist row (after `onRefetch: (_) { … },`):

```dart
            onSetReading: (_) =>
                showArtistReadingDialog(context, ref, artist.mbid),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/catalog/artist_column_test.dart`
Expected: PASS.

- [ ] **Step 5: Full verification**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test 2>&1 | tail -1`
Expected: All tests passed.

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test 2>&1 | tail -5`
Expected: all Rust tests pass.

Run: `cd /home/autarch/projects/olivier && mise exec -- dart format lib/catalog/artist_column.dart && mise exec -- flutter analyze lib 2>&1 | tail -3`
Expected: No issues.

> LINT NOTE: `mise exec -- precious lint --all` may report a pre-existing `typos` failure
> (`Yoru`) in the untracked `TODO` file — that is the user's note, not this change. Confirm any
> typos failure is only in `TODO`, and never stage `TODO`.

- [ ] **Step 6: Commit**

```bash
cd /home/autarch/projects/olivier
git add lib/catalog/artist_column.dart test/catalog/artist_column_test.dart
git commit -m "Wire Set reading… into the artist column

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Migration / two columns → Task 1. ✓
- `artists_page` COALESCE (display + sort + keyset) → Task 3. ✓
- `artist_reading` + `set_artist_reading_override` + `ArtistReading` → Task 2. ✓
- Enrich isolation (survives re-enrich + clear falls back) → Task 3 (`override_survives_reenrichment`). ✓
- FFI + bridge regen → Task 4. ✓
- Dart seams → Task 5. ✓
- `overrideValue` + dialog (Reading + Sort as, MB hints, Save) → Task 6. ✓
- Context-menu `onSetReading` + item → Task 7. ✓
- Wire into artist column; display unchanged (effective value flows through) → Task 8. ✓
- Tests: Rust round-trip/order/survive/clear (Tasks 2-3), `overrideValue` + dialog + seam (Task 6), menu item (Tasks 7-8). ✓

**Type consistency:** Rust `ArtistReading` fields (`mb_transliteration`, `transliteration_override`, `mb_sort_name`, `sort_name_override`, `name`, `name_original`) map to Dart `mbTransliteration`, `transliterationOverride`, `mbSortName`, `sortNameOverride`, `name`, `nameOriginal` and are used consistently in the dialog + tests. `set_artist_reading_override(mbid, reading, sort)` signature matches the seam `SetArtistReadingOverrideFn(mbid, reading, sort)` and the dialog's `onSubmit(reading, sort)`. `mb_sort_name`/`mbSortName` is non-nullable (`sort_name` is `NOT NULL`); `mb_transliteration`/`name_original` are nullable. ✓

**Placeholders:** none — every code step shows the exact code. The one adaptation note (Task 8's `_app` helper) is explicit about the fallback. ✓
