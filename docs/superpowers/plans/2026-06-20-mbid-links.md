# Clickable MusicBrainz Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the release / album-artist / recording MBIDs in the Info popups as clickable (and still selectable) links to musicbrainz.org — real UUIDs only.

**Architecture:** Carry the needed MBIDs into the `Album`/`Track`/`QueueTrack` DTOs via the catalog queries; add a `url_launcher` dependency; a pure `mbUrl` helper builds a musicbrainz.org URL only for real UUIDs (synth keys/null → no link); `showInfoDialog` renders url-bearing fields as `SelectableText.rich` links via a `launchMbUrl` seam, with gesture recognizers pre-built and disposed on close.

**Tech Stack:** Rust (rusqlite), flutter_rust_bridge 2.x, Flutter, url_launcher.

**Spec:** `docs/superpowers/specs/2026-06-20-mbid-links-design.md`

**Conventions (every task):**
- Rust tests: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test`. Dart tests: `cd /home/autarch/projects/olivier && mise exec -- flutter test`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- NEVER `git add` `TODO`/`#TODO#`. No remote — don't push.
- New DTO fields are `Option<String>` (optional in Dart → existing fixtures unaffected).
- **Each Rust struct change breaks `rust/src/frb_generated.rs`**, so each Rust task regenerates the bridge (`mise exec -- flutter_rust_bridge_codegen generate` from the repo root) and commits it together with the source so the commit compiles. Ignore stale rust-analyzer diagnostics; trust `cargo`/`flutter test`.

---

## File Structure

- `rust/src/catalog/schema.rs` — `Album` (+1), `Track` (+2), `QueueTrack` (+2).
- `rust/src/catalog/query.rs` — `albums_for_artist`, `tracks_for_album`, `tracks_for_paths`.
- `rust/src/frb_generated.rs`, `lib/src/rust/**` — regenerated bridge.
- `pubspec.yaml` (+ `pubspec.lock`) — `url_launcher`.
- `lib/widgets/info_dialog.dart` — `mbUrl`, `launchMbUrl`, field model, render, builders.
- `rust/tests/catalog_test.rs`, `test/info_dialog_test.dart` — tests.

---

### Task 1: Album — album_artist_mbid

**Files:** `rust/src/catalog/schema.rs`, `rust/src/catalog/query.rs`, `rust/tests/catalog_test.rs`, regenerated bridge.

- [ ] **Step 1: Write the failing test** — add to `rust/tests/catalog_test.rs` (`albums_for_artist`, `open` already imported):

```rust
#[test]
fn albums_for_artist_returns_album_artist_mbid() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('11111111-2222-3333-4444-555555555555', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('r', '11111111-2222-3333-4444-555555555555', 'Album')",
        [],
    )
    .unwrap();

    let albums = albums_for_artist(&conn, "11111111-2222-3333-4444-555555555555").unwrap();
    assert_eq!(
        albums[0].album_artist_mbid.as_deref(),
        Some("11111111-2222-3333-4444-555555555555")
    );
}
```

- [ ] **Step 2: Run it, verify FAILS to compile** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test albums_for_artist_returns_album_artist_mbid`

- [ ] **Step 3: Add the struct field** — in `rust/src/catalog/schema.rs`, in `Album`, after `pub album_artist_reading: Option<String>,` add:
```rust
    pub album_artist_mbid: Option<String>,
```

- [ ] **Step 4: Update `albums_for_artist`** — in `rust/src/catalog/query.rs`, add a column after the `COALESCE(a.transliteration_override, a.transliteration)` line (currently the last SELECT column, index 9):
```sql
                a.name_original,
                COALESCE(a.transliteration_override, a.transliteration),
                r.album_artist_mbid
         FROM release r
```
Closure (after `album_artist_reading: r.get(9)?,`):
```rust
            album_artist_mbid: r.get(10)?,
```

- [ ] **Step 5: Run it, verify PASS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test albums_for_artist`

- [ ] **Step 6: Regenerate the bridge + confirm** — `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`, then `grep -n 'albumArtistMbid' lib/src/rust/catalog/schema.dart | head` (should show it on `Album`).

- [ ] **Step 7: Commit**
```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/tests/catalog_test.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "albums_for_artist: carry album_artist_mbid

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Track — recording_mbid + album_artist_mbid

**Files:** `rust/src/catalog/schema.rs`, `rust/src/catalog/query.rs`, `rust/tests/catalog_test.rs`, regenerated bridge.

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn tracks_for_album_returns_recording_and_album_artist_mbids() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('aaaaaaaa-2222-3333-4444-555555555555', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'aaaaaaaa-2222-3333-4444-555555555555', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, recording_mbid, disc, position, title)
         VALUES (1, 'rel', 'bbbbbbbb-2222-3333-4444-555555555555', 1, 1, 'Song')",
        [],
    )
    .unwrap();

    let tracks = tracks_for_album(&conn, "rel").unwrap();
    assert_eq!(
        tracks[0].recording_mbid.as_deref(),
        Some("bbbbbbbb-2222-3333-4444-555555555555")
    );
    assert_eq!(
        tracks[0].album_artist_mbid.as_deref(),
        Some("aaaaaaaa-2222-3333-4444-555555555555")
    );
}
```

- [ ] **Step 2: Run it, verify FAILS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test tracks_for_album_returns_recording`

- [ ] **Step 3: Add the struct fields** — in `Track`, after `pub album_artist_reading: Option<String>,` (the last field) add:
```rust
    pub recording_mbid: Option<String>,
    pub album_artist_mbid: Option<String>,
```

- [ ] **Step 4: Update `tracks_for_album`** — add two columns after the `COALESCE(aa.transliteration_override, aa.transliteration)` line (currently col 12):
```sql
                aa.name, aa.name_original,
                COALESCE(aa.transliteration_override, aa.transliteration),
                t.recording_mbid, r.album_artist_mbid
         FROM track t
```
Closure (after `album_artist_reading: r.get(12)?,`):
```rust
            recording_mbid: r.get(13)?,
            album_artist_mbid: r.get(14)?,
```

- [ ] **Step 5: Run it, verify PASS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test tracks_for_album`

- [ ] **Step 6: Regenerate the bridge + confirm** — `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`, then `grep -n 'recordingMbid' lib/src/rust/catalog/schema.dart | head`.

- [ ] **Step 7: Commit**
```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/tests/catalog_test.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "tracks_for_album: carry recording + album-artist MBIDs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: QueueTrack — recording_mbid + album_artist_mbid

**Files:** `rust/src/catalog/schema.rs`, `rust/src/catalog/query.rs`, `rust/tests/catalog_test.rs`, regenerated bridge.

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn tracks_for_paths_returns_recording_and_album_artist_mbids() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name) VALUES ('aaaaaaaa-2222-3333-4444-555555555555', 'A', 'A')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'aaaaaaaa-2222-3333-4444-555555555555', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, recording_mbid, disc, position, title)
         VALUES (1, 'rel', 'bbbbbbbb-2222-3333-4444-555555555555', 1, 1, 'Song')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES ('/m/a.flac', 0, 0, 1, 0)",
        [],
    )
    .unwrap();

    let got = tracks_for_paths(
        &conn,
        &["/m/a.flac".to_string(), "/m/missing.mp3".to_string()],
    )
    .unwrap();
    assert_eq!(
        got[0].recording_mbid.as_deref(),
        Some("bbbbbbbb-2222-3333-4444-555555555555")
    );
    assert_eq!(
        got[0].album_artist_mbid.as_deref(),
        Some("aaaaaaaa-2222-3333-4444-555555555555")
    );
    // placeholder for the catalog-miss path
    assert_eq!(got[1].recording_mbid, None);
    assert_eq!(got[1].album_artist_mbid, None);
}
```

- [ ] **Step 2: Run it, verify FAILS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test tracks_for_paths_returns_recording`

- [ ] **Step 3: Add the struct fields** — in `QueueTrack`, after `pub title_translate: Option<String>,` (the last field) add:
```rust
    pub recording_mbid: Option<String>,
    pub album_artist_mbid: Option<String>,
```

- [ ] **Step 4: Update `tracks_for_paths`** — add two columns after the `COALESCE(aa.transliteration_override, aa.transliteration)` line (currently col 11):
```sql
                aa.name, aa.name_original,
                COALESCE(aa.transliteration_override, aa.transliteration),
                t.recording_mbid, r.album_artist_mbid
         FROM file f JOIN track t ON t.id = f.track_id
```
Found closure (after `album_artist_reading: r.get(11)?,`):
```rust
                    recording_mbid: r.get(12)?,
                    album_artist_mbid: r.get(13)?,
```
Placeholder closure (after `album_artist_reading: None,`):
```rust
            recording_mbid: None,
            album_artist_mbid: None,
```

- [ ] **Step 5: Run the full catalog suite, verify PASS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test`

- [ ] **Step 6: Regenerate the bridge + confirm** — `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`, then confirm Dart still analyzes + the existing Dart suite passes (new fields optional): `mise exec -- flutter analyze lib/src/rust 2>&1 | tail -2` and `mise exec -- flutter test 2>&1 | tail -2`.

- [ ] **Step 7: Commit**
```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/tests/catalog_test.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "tracks_for_paths: carry recording + album-artist MBIDs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Add the url_launcher dependency

**Files:** `pubspec.yaml`, `pubspec.lock`.

- [ ] **Step 1: Add it** — `cd /home/autarch/projects/olivier && mise exec -- flutter pub add url_launcher`

- [ ] **Step 2: Verify it resolved** — `grep -n 'url_launcher' pubspec.yaml` (a `url_launcher: ^…` line under `dependencies:`) and `mise exec -- flutter pub get 2>&1 | tail -2`.

- [ ] **Step 3: Commit**
```bash
cd /home/autarch/projects/olivier
git add pubspec.yaml pubspec.lock
git commit -m "Add url_launcher dependency

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `mbUrl` helper

**Files:** `lib/widgets/info_dialog.dart`, `test/info_dialog_test.dart`.

- [ ] **Step 1: Write the failing test** — add to `test/info_dialog_test.dart` (it already imports `package:olivier/widgets/info_dialog.dart`):

```dart
  group('mbUrl', () {
    test('builds a musicbrainz URL for a real UUID', () {
      const uuid = '11111111-2222-3333-4444-555555555555';
      expect(mbUrl('release', uuid), 'https://musicbrainz.org/release/$uuid');
      expect(mbUrl('artist', uuid), 'https://musicbrainz.org/artist/$uuid');
      expect(
          mbUrl('recording', uuid), 'https://musicbrainz.org/recording/$uuid');
    });
    test('returns null for a synth key or null/empty', () {
      expect(mbUrl('artist', 'synth:aa:foo'), isNull);
      expect(mbUrl('release', 'synth:rel:x|y'), isNull);
      expect(mbUrl('release', null), isNull);
      expect(mbUrl('release', ''), isNull);
      expect(mbUrl('release', 'not-a-uuid'), isNull);
    });
  });
```

- [ ] **Step 2: Run it, verify FAILS** — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/info_dialog_test.dart`

- [ ] **Step 3: Add the helper** — in `lib/widgets/info_dialog.dart`, add at top level (e.g. just below the imports):

```dart
final _mbidUuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// The musicbrainz.org URL for an entity, or null when [mbid] is not a real
/// MBID (a synth key like `synth:aa:…`, or null/empty). [entityType] is one of
/// `release`, `artist`, `recording`.
String? mbUrl(String entityType, String? mbid) {
  if (mbid == null || !_mbidUuid.hasMatch(mbid)) return null;
  return 'https://musicbrainz.org/$entityType/$mbid';
}
```

- [ ] **Step 4: Run it, verify PASS** — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/info_dialog_test.dart`

- [ ] **Step 5: Format + commit**
```bash
cd /home/autarch/projects/olivier
mise exec -- dart format lib/widgets/info_dialog.dart test/info_dialog_test.dart
git add lib/widgets/info_dialog.dart test/info_dialog_test.dart
git commit -m "Add mbUrl helper (real-UUID MusicBrainz URLs)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Render MBIDs as links + wire the builders

**Files:** `lib/widgets/info_dialog.dart`, `test/info_dialog_test.dart`.

- [ ] **Step 1: Write the failing tests** — add to `test/info_dialog_test.dart`. Also add these imports at the top of the file if missing: `import 'package:flutter/gestures.dart';`.

```dart
  test('albumInfoFields links a real Release MBID and adds the album-artist MBID',
      () {
    const rel = '11111111-2222-3333-4444-555555555555';
    const art = 'aaaaaaaa-2222-3333-4444-555555555555';
    final a = Album(
      releaseMbid: rel,
      title: 'Album',
      albumArtist: 'A',
      albumArtistMbid: art,
      addedAt: 0,
    );
    final fields = albumInfoFields(a);
    final release = fields.firstWhere((f) => f.$1 == 'Release MBID');
    expect(release.$2, rel);
    expect(release.$3, 'https://musicbrainz.org/release/$rel');
    final artist = fields.firstWhere((f) => f.$1 == 'Album artist MBID');
    expect(artist.$3, 'https://musicbrainz.org/artist/$art');
  });

  test('synth release MBID is shown but not linked', () {
    final a = Album(
      releaseMbid: 'synth:rel:a|b',
      title: 'Album',
      albumArtist: 'A',
      addedAt: 0,
    );
    final release = albumInfoFields(a).firstWhere((f) => f.$1 == 'Release MBID');
    expect(release.$2, 'synth:rel:a|b'); // still shown
    expect(release.$3, isNull); // not linked
  });

  testWidgets('a linked MBID launches its musicbrainz URL when tapped',
      (tester) async {
    final launched = <String>[];
    final orig = launchMbUrl;
    launchMbUrl = (url) async => launched.add(url);
    addTearDown(() => launchMbUrl = orig);

    const uuid = '11111111-2222-3333-4444-555555555555';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showInfoDialog(context, title: 'Album', fields: [
              ('Release MBID', uuid, mbUrl('release', uuid)),
              ('Note', 'plain', null),
            ]),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The linked field renders as SelectableText.rich (has a textSpan); the
    // plain field does not. Fire the link's recognizer directly (robust vs
    // hit-testing a TextSpan).
    final link = tester.widget<SelectableText>(find.byWidgetPredicate(
        (w) => w is SelectableText && w.textSpan != null));
    final recognizer =
        (link.textSpan! as TextSpan).recognizer! as TapGestureRecognizer;
    recognizer.onTap!();
    await tester.pump();

    expect(launched, ['https://musicbrainz.org/release/$uuid']);
  });
```

- [ ] **Step 2: Run them, verify FAIL** (`launchMbUrl`/`Album artist MBID`/the 3-tuple don't exist yet) — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/info_dialog_test.dart`

- [ ] **Step 3: Implement** — in `lib/widgets/info_dialog.dart`:

(a) Add imports at the top:
```dart
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
```

(b) Add the launch seam (top level, near `mbUrl`):
```dart
/// Opens a MusicBrainz URL. Overridable in tests; defaults to the external
/// browser.
Future<void> Function(String url) launchMbUrl = (url) =>
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
```

(c) Change `_add` to carry an optional URL:
```dart
void _add(List<(String, String, String?)> out, String label, String? value,
    [String? url]) {
  final v = (value ?? '').trim();
  if (v.isNotEmpty) out.add((label, v, url));
}
```

(d) Change all three builders' return type to `List<(String, String, String?)>`
(`trackInfoFields`, `queueTrackInfoFields`, `albumInfoFields`) and their local `out`
declaration to `final out = <(String, String, String?)>[];`. Then attach the MBID links:
- In `albumInfoFields`, replace `_add(out, 'Release MBID', a.releaseMbid);` with:
```dart
  _add(out, 'Release MBID', a.releaseMbid, mbUrl('release', a.releaseMbid));
  _add(out, 'Album artist MBID', a.albumArtistMbid,
      mbUrl('artist', a.albumArtistMbid));
```
- In `trackInfoFields`, add (e.g. after the album-artist rows, before 'Disc / Track'):
```dart
  _add(out, 'Recording MBID', t.recordingMbid,
      mbUrl('recording', t.recordingMbid));
  _add(out, 'Album artist MBID', t.albumArtistMbid,
      mbUrl('artist', t.albumArtistMbid));
```
- In `queueTrackInfoFields`, add the same two lines (using `t.recordingMbid` / `t.albumArtistMbid`).

(e) Change `showInfoDialog`'s `fields` param type to `List<(String, String, String?)>`, pre-build
the recognizers, render link vs plain, and dispose on close. Replace the whole function body with:

```dart
Future<void> showInfoDialog(
  BuildContext context, {
  required String title,
  required List<(String, String, String?)> fields,
  Widget? header,
}) {
  final recognizers = <String, TapGestureRecognizer>{};
  for (final (_, _, url) in fields) {
    if (url != null && !recognizers.containsKey(url)) {
      recognizers[url] = TapGestureRecognizer()..onTap = () => launchMbUrl(url);
    }
  }
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (header != null) ...[
                Center(child: header),
                const SizedBox(height: 12),
              ],
              for (final (label, value, url) in fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context).textTheme.labelSmall),
                      if (url == null)
                        SelectableText(value)
                      else
                        SelectableText.rich(TextSpan(
                          text: value,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                          recognizer: recognizers[url],
                        )),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  ).whenComplete(() {
    for (final r in recognizers.values) {
      r.dispose();
    }
  });
}
```

- [ ] **Step 4: Run the info-dialog tests, verify PASS; then fix any caller** — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/info_dialog_test.dart`. The builders' return-type change is consumed by `showInfoDialog` (same file) and its callers pass `fields: <builder>(x)`, so no call-site change is needed. The existing `trackInfoFields includes ... Album artist` assertions still hold (`.$1`/`.$2` work on a 3-tuple).

- [ ] **Step 5: Full verification**
```bash
cd /home/autarch/projects/olivier && mise exec -- flutter test 2>&1 | tail -2
cd /home/autarch/projects/olivier && mise exec -- flutter analyze lib 2>&1 | tail -3
```
Expected: all pass; no analyzer issues. (A `precious lint --all` `typos` hit on the untracked `TODO` is the user's note — ignore.)

- [ ] **Step 6: Format + commit**
```bash
cd /home/autarch/projects/olivier
mise exec -- dart format lib/widgets/info_dialog.dart test/info_dialog_test.dart
git add lib/widgets/info_dialog.dart test/info_dialog_test.dart
git commit -m "Info popups: clickable MusicBrainz links for MBIDs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Album/Track/QueueTrack MBID fields + queries + bridge → Tasks 1/2/3. ✓
- `url_launcher` dependency → Task 4. ✓
- `mbUrl` (real-UUID-only) → Task 5 (+ synth/null unit tests). ✓
- Field model `(String,String,String?)` + `_add` + render (clickable+selectable, recognizers disposed) + `launchMbUrl` seam → Task 6. ✓
- Builders link Release + Album-artist (album) and Recording + Album-artist (track/queue) → Task 6. ✓
- Synth shown-but-unlinked → Task 6 test. ✓
- Tests: Rust round-trips (1-3), `mbUrl` unit (5), builder URL attach + synth + widget launch (6). ✓

**Type consistency:** Rust `album_artist_mbid`/`recording_mbid` (`Option<String>`) → Dart `albumArtistMbid`/`recordingMbid`. Column indices: Album +10; Track +13/14; QueueTrack +12/13 — each matches its SELECT order. `mbUrl` defined in Task 5, used in Task 6 builders. The `(String, String, String?)` record is introduced in Task 6 and consumed by `showInfoDialog` + tests via `.$1/.$2/.$3`.

**Placeholders:** none — every step has exact code. The bridge-regen-per-Rust-task is explicit (avoids the broken-intermediate-commit issue).
