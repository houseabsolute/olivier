# Album Release Year in the Queue — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each track's album release year (original, falling back to reissue) appended to the album cell of each expanded-queue row, e.g. `Dark Side of the Moon (1973)`.

**Architecture:** The year is already in the catalog DB (`release_group.first_release_date`, `release.date`) but not on `QueueTrack`. Add two fields to the `QueueTrack` Rust struct, extend the `tracks_for_paths` query with a `release_group` join + two `substr(...,1,4)` selects (the exact expressions the browser queries use), regenerate the flutter_rust_bridge bindings, then compose `originalYear ?? reissueYear` into the album `Text` in the queue panel.

**Tech Stack:** Rust (rusqlite) + flutter_rust_bridge 2.12.0 codegen + Dart/Flutter/Riverpod.

---

## Background the implementer needs

- `QueueTrack` is defined in `rust/src/catalog/schema.rs` (~line 99) and built by
  `tracks_for_paths` in `rust/src/catalog/query.rs` (~line 376). Its Dart mirror is generated into
  `lib/src/rust/catalog/schema.dart`.
- Relevant tables (`rust/src/db.rs`): `release(mbid, release_group_mbid, album_artist_mbid, title,
  date)`, `release_group(mbid, title, first_release_date)`, `track(id, release_mbid, …)`,
  `file(path, …, track_id, added_at)`.
- **Codegen ordering matters:** adding fields to the `QueueTrack` struct makes `rust/src/frb_generated.rs`
  (which encodes/decodes every field) out of sync, so the Rust crate will NOT compile until you
  regenerate. Do struct edit → query edit → `flutter_rust_bridge_codegen generate` → *then* run
  `cargo test`. The codegen command is `mise exec -- flutter_rust_bridge_codegen generate` (run from
  the repo root).
- Rust tests: `cd rust && cargo test --test <name>`. Flutter tests: `mise exec -- flutter test <path>`.
  Lint/format gate: `just lint --all`.

---

## Task 1: Carry original/reissue year on `QueueTrack` (Rust + bridge regen)

**Files:**
- Create: `rust/tests/queue_release_year_test.rs`
- Modify: `rust/src/catalog/schema.rs` (`QueueTrack`)
- Modify: `rust/src/catalog/query.rs` (`tracks_for_paths`)
- Regenerate: `rust/src/frb_generated.rs`, `lib/src/rust/**`

- [ ] **Step 1: Write the failing Rust test**

Create `rust/tests/queue_release_year_test.rs`:

```rust
use rust_lib_olivier::catalog::query::tracks_for_paths;
use rust_lib_olivier::db::open;

fn seed(conn: &rusqlite::Connection) {
    conn.execute(
        "INSERT INTO artist(mbid,name,sort_name) VALUES ('m-a','Artist','Artist')",
        [],
    )
    .unwrap();
    // Release WITH a release_group (original year) and its own reissue date.
    conn.execute(
        "INSERT INTO release_group(mbid,title,first_release_date) \
         VALUES ('rg','Album','1973-03-01')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid,release_group_mbid,album_artist_mbid,title,date) \
         VALUES ('r','rg','m-a','Album','2011-09-26')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,title,length_ms) VALUES (1,'r','Song',1000)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at) VALUES ('/p.flac',0,0,1,0)",
        [],
    )
    .unwrap();

    // Release with NO release_group and NO date.
    conn.execute(
        "INSERT INTO release(mbid,album_artist_mbid,title) VALUES ('r2','m-a','NoYear')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id,release_mbid,title) VALUES (2,'r2','Song2')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path,mtime,size,track_id,added_at) VALUES ('/p2.flac',0,0,2,0)",
        [],
    )
    .unwrap();
}

#[test]
fn tracks_for_paths_carries_original_and_reissue_year() {
    let conn = open(":memory:").unwrap();
    seed(&conn);

    let got = tracks_for_paths(&conn, &["/p.flac".to_string()]).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].original_year.as_deref(), Some("1973"));
    assert_eq!(got[0].reissue_year.as_deref(), Some("2011"));
}

#[test]
fn tracks_for_paths_year_is_none_without_release_group_or_date() {
    let conn = open(":memory:").unwrap();
    seed(&conn);

    let got = tracks_for_paths(&conn, &["/p2.flac".to_string()]).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].original_year, None);
    assert_eq!(got[0].reissue_year, None);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd rust && cargo test --test queue_release_year_test`
Expected: FAIL — compile error, `no field 'original_year' on type ... QueueTrack`.

- [ ] **Step 3: Add the two fields to the `QueueTrack` struct**

In `rust/src/catalog/schema.rs`, in `pub struct QueueTrack`, after `pub album_artist_mbid:
Option<String>,` add:

```rust
    pub original_year: Option<String>,
    pub reissue_year: Option<String>,
```

- [ ] **Step 4: Extend the `tracks_for_paths` query**

In `rust/src/catalog/query.rs`, in `tracks_for_paths`:

(a) Add the two selected columns. Change the end of the SELECT list:

```rust
                t.recording_mbid, r.album_artist_mbid
         FROM file f JOIN track t ON t.id = f.track_id
         JOIN release r ON r.mbid = t.release_mbid
         LEFT JOIN artist aa ON aa.mbid = r.album_artist_mbid
         LEFT JOIN track_stats s ON s.track_id = t.id
         WHERE f.path = ?1",
```
to:
```rust
                t.recording_mbid, r.album_artist_mbid,
                substr(rg.first_release_date, 1, 4), substr(r.date, 1, 4)
         FROM file f JOIN track t ON t.id = f.track_id
         JOIN release r ON r.mbid = t.release_mbid
         LEFT JOIN release_group rg ON rg.mbid = r.release_group_mbid
         LEFT JOIN artist aa ON aa.mbid = r.album_artist_mbid
         LEFT JOIN track_stats s ON s.track_id = t.id
         WHERE f.path = ?1",
```

(b) Populate the fields in the FOUND branch. Change:

```rust
                    recording_mbid: r.get(12)?,
                    album_artist_mbid: r.get(13)?,
                })
```
to:
```rust
                    recording_mbid: r.get(12)?,
                    album_artist_mbid: r.get(13)?,
                    original_year: r.get(14)?,
                    reissue_year: r.get(15)?,
                })
```

(c) Populate the NOT-FOUND fallback. Change:

```rust
            album_artist_mbid: None,
        }));
```
to:
```rust
            album_artist_mbid: None,
            original_year: None,
            reissue_year: None,
        }));
```

- [ ] **Step 5: Regenerate the bridge**

Run (from repo root): `mise exec -- flutter_rust_bridge_codegen generate`
Expected: updates `rust/src/frb_generated.rs` and `lib/src/rust/**`; `lib/src/rust/catalog/schema.dart`
gains `final String? originalYear;` and `final String? reissueYear;` on `QueueTrack`.

- [ ] **Step 6: Run the Rust test to verify it passes**

Run: `cd rust && cargo test --test queue_release_year_test`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/src/frb_generated.rs lib/src/rust rust/tests/queue_release_year_test.rs
git commit -m "feat: carry original/reissue album year on QueueTrack"
```

---

## Task 2: Append the year to the album cell in the queue panel (Dart)

**Files:**
- Create: `test/queue_release_year_test.dart`
- Modify: `lib/catalog/queue_panel.dart` (expanded-row `itemBuilder`)

- [ ] **Step 1: Write the failing widget test**

Create `test/queue_release_year_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

class _StubQueue extends QueueNotifier {
  _StubQueue(this._v);
  final QueueView _v;
  @override
  Future<QueueView> build() async => _v;
}

QueueTrack _track({String? originalYear, String? reissueYear}) => QueueTrack(
      path: '/a.flac',
      title: 'Song',
      album: 'Dark Side',
      addedAt: 0,
      originalYear: originalYear,
      reissueYear: reissueYear,
    );

Future<void> _pumpExpanded(WidgetTester tester, QueueTrack track) async {
  final qc = QueueController.withPlayer(FakeQueuePlayer(),
      dbPath: ':memory:', saveQueue: (_) async {});
  await qc.append([track.path]);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((_) async => null),
      queueControllerProvider.overrideWithValue(qc),
      queueProvider.overrideWith(
        () => _StubQueue(
            QueueView(tracks: [track], currentIndex: 0, shuffled: false)),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  ));
  await tester.pump();
  await tester.pump();
  await tester.tap(find.byTooltip('Expand queue'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('appends the original year to the album', (tester) async {
    await _pumpExpanded(
        tester, _track(originalYear: '1973', reissueYear: '2011'));
    // Year-suffixed label is unique to the expanded row (the header, if it
    // shows the album at all, shows it without the year).
    expect(find.text('Dark Side (1973)'), findsOneWidget);
  });

  testWidgets('falls back to the reissue year when original is null',
      (tester) async {
    await _pumpExpanded(tester, _track(originalYear: null, reissueYear: '2011'));
    expect(find.text('Dark Side (2011)'), findsOneWidget);
  });

  testWidgets('shows the bare album when no year is known', (tester) async {
    await _pumpExpanded(tester, _track());
    // No parenthetical year was appended anywhere.
    expect(find.textContaining('Dark Side ('), findsNothing);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/queue_release_year_test.dart`
Expected: FAIL — first test can't find `Dark Side (1973)` (the row shows the bare album today).

- [ ] **Step 3: Compose the year into the album cell**

In `lib/catalog/queue_panel.dart`, in the expanded-list `itemBuilder`, add two locals next to the
existing `final t = view.tracks[i];` / `final selected = …` / `final muted = …` lines:

```dart
final year = t.originalYear ?? t.reissueYear ?? '';
final albumLabel = year.isEmpty ? t.album : '${t.album} ($year)';
```

Then change the album cell passed to `_queueRowLayout` from:

```dart
                            album: Text(
                              t.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muted,
                            ),
```
to:
```dart
                            album: Text(
                              albumLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muted,
                            ),
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- flutter test test/queue_release_year_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/catalog/queue_panel.dart test/queue_release_year_test.dart
git commit -m "feat: show album release year in the expanded queue rows"
```

---

## Task 3: Full verification gate

**Files:** none (verification only)

- [ ] **Step 1: Rust test suite**

Run: `cd rust && cargo test`
Expected: all pass (including the two new year tests; the extra SELECT columns don't affect other
`tracks_for_paths` callers).

- [ ] **Step 2: Flutter test suite**

Run: `mise exec -- flutter test`
Expected: all pass (existing `QueueTrack(...)` constructions still compile — the new fields are
nullable/optional).

- [ ] **Step 3: Lint/format gate**

Run: `just lint --all`
Expected: Clean (exit 0). If `cargo fmt`/`dart format` rewrite anything (e.g. the regenerated files
are already formatted, but the SQL string wrap may need `cargo fmt`), apply, `git add`, and add a
`style:` commit (or amend the relevant task commit), then re-run until clean.

---

## Manual verification (human, after merge)

Run the app, queue an album whose release year is known, expand the queue → each row's album shows
`Album (YYYY)`. Queue a track whose album has no year → the row shows the bare album. Confirm the
browser album column is unchanged.
</content>
