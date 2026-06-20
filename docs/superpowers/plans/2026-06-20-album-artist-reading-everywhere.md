# Album-Artist + Reading Everywhere Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display the album-artist (name + effective, overridable reading) in place of the raw tag artist across the queue, now-playing bar, and Info popups, refreshing live when an artist's reading override changes.

**Architecture:** Carry the album-artist's `name`/`name_original`/effective reading (`COALESCE(transliteration_override, transliteration)`) into the `Album`/`Track`/`QueueTrack` DTOs via the catalog queries (new `release → artist` LEFT JOINs); render them with the existing `BilingualText`; and trigger a `QueueController.revision` bump on override change to re-resolve every surface.

**Tech Stack:** Rust (rusqlite), flutter_rust_bridge 2.x, Flutter + Riverpod 3.x, audio_service/just_audio.

**Spec:** `docs/superpowers/specs/2026-06-20-album-artist-reading-everywhere-design.md`

**Conventions (every task):**
- Rust tests: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test`. Dart tests: `cd /home/autarch/projects/olivier && mise exec -- flutter test`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- NEVER `git add` the `TODO` file or `#TODO#`. The repo has no remote — don't push.
- All new struct fields are `Option<String>` → optional named params in Dart, so existing test fixtures that omit them keep compiling. Ignore stale rust-analyzer `<new-diagnostics>`; trust `cargo`/`flutter test`.

---

## File Structure

- `rust/src/catalog/schema.rs` — add album-artist fields to `Album` (+2), `Track` (+3), `QueueTrack` (+3).
- `rust/src/catalog/query.rs` — `albums_for_artist`, `tracks_for_album`, `tracks_for_paths`.
- `rust/src/frb_generated.rs`, `lib/src/rust/**` — regenerated bridge.
- `lib/catalog/queue_panel.dart` — queue artist cell → bilingual album-artist.
- `lib/audio/playback_controller.dart` — `mediaItemsForQueueTracks` album-artist + reading.
- `lib/widgets/now_playing_bar.dart` — bilingual artist.
- `lib/widgets/info_dialog.dart` — album/track/queue artist + reading.
- `lib/audio/queue_controller.dart` — `refreshMetadata()`.
- `lib/widgets/artist_reading_dialog.dart` — `onSubmit` refreshes all surfaces.
- `rust/tests/catalog_test.rs`, several `test/**` files — tests.

---

### Task 1: Album — album-artist original + reading

**Files:**
- Modify: `rust/src/catalog/schema.rs` (the `Album` struct)
- Modify: `rust/src/catalog/query.rs` (`albums_for_artist`)
- Test: `rust/tests/catalog_test.rs`

- [ ] **Step 1: Write the failing test**

Add to `rust/tests/catalog_test.rs` (it already imports `albums_for_artist`, `set_artist_reading_override`, `open`):

```rust
#[test]
fn albums_for_artist_returns_album_artist_reading_with_override() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name, transliteration, name_original)
         VALUES ('m', '椎名林檎', 'Sheena, Ringo', 'Sheena Ringo', '椎名林檎')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title, date) VALUES ('r', 'm', 'Album', '1999')",
        [],
    )
    .unwrap();

    // MB reading flows through; original is name_original.
    let albums = albums_for_artist(&conn, "m").unwrap();
    assert_eq!(albums[0].album_artist, "椎名林檎");
    assert_eq!(albums[0].album_artist_original.as_deref(), Some("椎名林檎"));
    assert_eq!(albums[0].album_artist_reading.as_deref(), Some("Sheena Ringo"));

    // Override wins; clearing falls back to MB.
    set_artist_reading_override(&conn, "m", Some("Shiina Ringo"), None).unwrap();
    let albums = albums_for_artist(&conn, "m").unwrap();
    assert_eq!(albums[0].album_artist_reading.as_deref(), Some("Shiina Ringo"));
    set_artist_reading_override(&conn, "m", None, None).unwrap();
    let albums = albums_for_artist(&conn, "m").unwrap();
    assert_eq!(albums[0].album_artist_reading.as_deref(), Some("Sheena Ringo"));
}
```

- [ ] **Step 2: Run it, verify it FAILS to compile** (`album_artist_original` etc. don't exist)

Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test albums_for_artist_returns_album_artist_reading_with_override`

- [ ] **Step 3: Add the struct fields**

In `rust/src/catalog/schema.rs`, in the `Album` struct, after `pub album_artist: String,` add:

```rust
    pub album_artist_original: Option<String>,
    pub album_artist_reading: Option<String>,
```

- [ ] **Step 4: Update `albums_for_artist`**

In `rust/src/catalog/query.rs`, in `albums_for_artist`, add two columns to the SELECT — after the
`(SELECT MIN(f.added_at) ...)` subquery (currently the last column, index 7), insert:

```sql
                a.name_original,
                COALESCE(a.transliteration_override, a.transliteration)
```

so the SELECT tail reads:

```sql
                (SELECT MIN(f.added_at) FROM track t JOIN file f ON f.track_id = t.id
                   WHERE t.release_mbid = r.mbid),
                a.name_original,
                COALESCE(a.transliteration_override, a.transliteration)
         FROM release r
```

Then add to the `Album { ... }` closure (after `added_at: ...`):

```rust
            album_artist_original: r.get(8)?,
            album_artist_reading: r.get(9)?,
```

- [ ] **Step 5: Run it, verify PASS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test albums_for_artist`

- [ ] **Step 6: Commit**

```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/tests/catalog_test.rs
git commit -m "albums_for_artist: carry album-artist original + effective reading

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Track — album-artist name + original + reading

**Files:**
- Modify: `rust/src/catalog/schema.rs` (the `Track` struct)
- Modify: `rust/src/catalog/query.rs` (`tracks_for_album`)
- Test: `rust/tests/catalog_test.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn tracks_for_album_returns_album_artist_fields_with_override() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name, transliteration, name_original)
         VALUES ('m', '椎名林檎', 'Sheena, Ringo', 'Sheena Ringo', '椎名林檎')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title, artist)
         VALUES (1, 'rel', 1, 1, 'Song', 'feat. Someone')",
        [],
    )
    .unwrap();

    let tracks = tracks_for_album(&conn, "rel").unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].album_artist.as_deref(), Some("椎名林檎"));
    assert_eq!(tracks[0].album_artist_original.as_deref(), Some("椎名林檎"));
    assert_eq!(tracks[0].album_artist_reading.as_deref(), Some("Sheena Ringo"));

    set_artist_reading_override(&conn, "m", Some("Shiina Ringo"), None).unwrap();
    let tracks = tracks_for_album(&conn, "rel").unwrap();
    assert_eq!(tracks[0].album_artist_reading.as_deref(), Some("Shiina Ringo"));
}
```

`tracks_for_album` is already imported in the test file.

- [ ] **Step 2: Run it, verify FAILS to compile** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test tracks_for_album_returns_album_artist`

- [ ] **Step 3: Add the struct fields**

In `rust/src/catalog/schema.rs`, in the `Track` struct, after `pub artist: Option<String>,` add:

```rust
    pub album_artist: Option<String>,
    pub album_artist_original: Option<String>,
    pub album_artist_reading: Option<String>,
```

- [ ] **Step 4: Update `tracks_for_album`**

In `rust/src/catalog/query.rs`, in `tracks_for_album`:

(a) Add three columns to the SELECT — after the two `MAX(CASE WHEN tta.kind = ...)` columns
(currently indices 8 and 9), insert:

```sql
                aa.name, aa.name_original,
                COALESCE(aa.transliteration_override, aa.transliteration)
```

(b) Add the joins — after `FROM track t`, before `LEFT JOIN track_stats s`:

```sql
         FROM track t
         JOIN release r ON r.mbid = t.release_mbid
         LEFT JOIN artist aa ON aa.mbid = r.album_artist_mbid
         LEFT JOIN track_stats s ON s.track_id = t.id
```

(`JOIN release` is safe — `track.release_mbid` is NOT NULL; the artist join is a `LEFT JOIN`
because `release.album_artist_mbid` is nullable, so a track is never dropped.)

(c) Add to the `Track { ... }` closure (after `title_translate: r.get(9)?,`):

```rust
            album_artist: r.get(10)?,
            album_artist_original: r.get(11)?,
            album_artist_reading: r.get(12)?,
```

- [ ] **Step 5: Run it, verify PASS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test tracks_for_album`

- [ ] **Step 6: Commit**

```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/tests/catalog_test.rs
git commit -m "tracks_for_album: carry album-artist name + reading

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: QueueTrack — album-artist name + original + reading

**Files:**
- Modify: `rust/src/catalog/schema.rs` (the `QueueTrack` struct)
- Modify: `rust/src/catalog/query.rs` (`tracks_for_paths`)
- Test: `rust/tests/catalog_test.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn tracks_for_paths_returns_album_artist_fields_and_placeholder_none() {
    let conn = open(":memory:").unwrap();
    conn.execute(
        "INSERT INTO artist(mbid, name, sort_name, transliteration, name_original)
         VALUES ('m', '椎名林檎', 'Sheena, Ringo', 'Sheena Ringo', '椎名林檎')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO release(mbid, album_artist_mbid, title) VALUES ('rel', 'm', 'Album')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO track(id, release_mbid, disc, position, title) VALUES (1, 'rel', 1, 1, 'Song')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO file(path, mtime, size, track_id, added_at) VALUES ('/m/a.flac', 0, 0, 1, 0)",
        [],
    )
    .unwrap();
    set_artist_reading_override(&conn, "m", Some("Shiina Ringo"), None).unwrap();

    let got = tracks_for_paths(
        &conn,
        &["/m/a.flac".to_string(), "/m/missing.mp3".to_string()],
    )
    .unwrap();
    // Real track carries the (overridden) album-artist fields.
    assert_eq!(got[0].album_artist.as_deref(), Some("椎名林檎"));
    assert_eq!(got[0].album_artist_original.as_deref(), Some("椎名林檎"));
    assert_eq!(got[0].album_artist_reading.as_deref(), Some("Shiina Ringo"));
    // Catalog-miss placeholder defaults all three to None.
    assert_eq!(got[1].album_artist, None);
    assert_eq!(got[1].album_artist_original, None);
    assert_eq!(got[1].album_artist_reading, None);
}
```

`tracks_for_paths` is already imported in the test file.

- [ ] **Step 2: Run it, verify FAILS to compile** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test tracks_for_paths_returns_album_artist`

- [ ] **Step 3: Add the struct fields**

In `rust/src/catalog/schema.rs`, in the `QueueTrack` struct, after `pub album: String,` add:

```rust
    pub album_artist: Option<String>,
    pub album_artist_original: Option<String>,
    pub album_artist_reading: Option<String>,
```

- [ ] **Step 4: Update `tracks_for_paths`**

In `rust/src/catalog/query.rs`, in `tracks_for_paths`:

(a) Add three columns to the SELECT — after `f.added_at, s.last_played` insert:

```sql
                f.added_at, s.last_played,
                aa.name, aa.name_original,
                COALESCE(aa.transliteration_override, aa.transliteration)
```

(b) Add the join — after `JOIN release r ON r.mbid = t.release_mbid` add:

```sql
         JOIN release r ON r.mbid = t.release_mbid
         LEFT JOIN artist aa ON aa.mbid = r.album_artist_mbid
         LEFT JOIN track_stats s ON s.track_id = t.id
```

(c) In the **found** `QueueTrack { ... }` closure (after `title_translate: r.get(6)?,`) add:

```rust
                    album_artist: r.get(9)?,
                    album_artist_original: r.get(10)?,
                    album_artist_reading: r.get(11)?,
```

(d) In the **placeholder** `QueueTrack { ... }` (the `unwrap_or_else`, after `title_translate: None,`) add:

```rust
            album_artist: None,
            album_artist_original: None,
            album_artist_reading: None,
```

- [ ] **Step 5: Run the full catalog suite, verify PASS** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test --test catalog_test`

- [ ] **Step 6: Commit**

```bash
cd /home/autarch/projects/olivier
git add rust/src/catalog/schema.rs rust/src/catalog/query.rs rust/tests/catalog_test.rs
git commit -m "tracks_for_paths: carry album-artist name + reading

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Regenerate the bridge

**Files:** Regenerate `lib/src/rust/**`, `rust/src/frb_generated.rs`.

- [ ] **Step 1: Confirm Rust builds + tests pass** — `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test 2>&1 | tail -8`

- [ ] **Step 2: Regenerate**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter_rust_bridge_codegen generate`
If it errors, capture the full output and STOP (report BLOCKED). Do not hand-edit generated files.

- [ ] **Step 3: Confirm the new Dart fields exist**

Run: `grep -rn "albumArtistReading\|albumArtistOriginal" lib/src/rust/catalog/schema.dart`
Expected: the three classes (`Album`, `Track`, `QueueTrack`) carry `albumArtist`/`albumArtistOriginal`/`albumArtistReading` (nullable).

- [ ] **Step 4: Confirm Dart still analyzes + the whole existing suite still passes** (new fields are optional, so nothing should break yet)

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter analyze lib/src/rust 2>&1 | tail -3`
Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test 2>&1 | tail -2`
Expected: no issues; all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/autarch/projects/olivier
git add rust/src/frb_generated.rs lib/src/rust
git commit -m "Regenerate bridge for album-artist DTO fields

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Queue rows show the bilingual album-artist

**Files:**
- Modify: `lib/catalog/queue_panel.dart`
- Test: `test/queue_panel_test.dart`

- [ ] **Step 1: Update the row + its test**

In `lib/catalog/queue_panel.dart`, in the expanded-list `itemBuilder`, DELETE the tag-artist line:

```dart
              final artist = (t.artist?.trim().isNotEmpty ?? false)
                  ? t.artist!.trim()
                  : '—';
```

and replace the `artist:` cell passed to `_queueRowLayout` (currently a `Text(artist, ...)`) with:

```dart
                        artist: BilingualText(
                          original:
                              t.albumArtistOriginal ?? t.albumArtist ?? '',
                          translit: t.albumArtistReading,
                          translate: null,
                          leads: leads,
                          primaryStyle: muted,
                        ),
```

(`leads` and `muted` are already in scope in the builder; `BilingualText` is already imported.)

- [ ] **Step 2: Update the existing queue test that asserted the tag artist**

In `test/queue_panel_test.dart`, the test `expanded panel shows a column header and artist/album
in their own columns` builds a `QueueTrack(... artist: '椎名林檎' ...)` and asserts
`find.text('椎名林檎')` as the artist. Change that fixture to drive the album-artist fields and
assert the bilingual album-artist instead. Set on that test's `QueueTrack`:

```dart
        albumArtist: '椎名林檎',
        albumArtistReading: 'Shiina Ringo',
```

and update the assertions so the artist column shows the original + reading:

```dart
    expect(find.text('椎名林檎'), findsOneWidget); // album-artist original
    expect(find.text('Shiina Ringo'), findsOneWidget); // its reading
```

- [ ] **Step 3: Run the queue tests; fix any other queue test that asserted the old tag artist**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/queue_panel_test.dart test/queue_row_info_test.dart test/queue_fullscreen_test.dart test/queue_panel_header_test.dart 2>&1 | tail -6`
For any failure caused by the artist cell no longer showing `QueueTrack.artist`, set the album-artist
fields on that test's `QueueTrack` fixture and update its assertion (same pattern as Step 2).
Expected after fixes: all pass.

- [ ] **Step 4: Analyze + format + commit**

```bash
cd /home/autarch/projects/olivier
mise exec -- dart format lib/catalog/queue_panel.dart test/queue_panel_test.dart
mise exec -- flutter analyze lib/catalog/queue_panel.dart
git add lib/catalog/queue_panel.dart test/queue_panel_test.dart
git commit -m "Queue rows: show bilingual album-artist instead of tag

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Now-playing bar shows the bilingual album-artist

**Files:**
- Modify: `lib/audio/playback_controller.dart` (`mediaItemsForQueueTracks`)
- Modify: `lib/widgets/now_playing_bar.dart`
- Test: `test/audio/media_items_for_queue_tracks_test.dart`

- [ ] **Step 1: Update the media-items test**

In `test/audio/media_items_for_queue_tracks_test.dart`, the first test builds a `QueueTrack(...
artist: 'Artist A' ...)` and asserts `item.artist == 'Artist A'`. Change it to drive the
album-artist: add to that `QueueTrack`:

```dart
        albumArtist: 'Album Artist A',
        albumArtistReading: 'Arutisuto A',
```

and change/add assertions:

```dart
    expect(item.artist, 'Album Artist A'); // album-artist, not the tag
    expect(item.extras?['artistReading'], 'Arutisuto A');
```

- [ ] **Step 2: Run it, verify it FAILS** (artist is still the tag) — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/audio/media_items_for_queue_tracks_test.dart`

- [ ] **Step 3: Update `mediaItemsForQueueTracks`**

In `lib/audio/playback_controller.dart`, in `mediaItemsForQueueTracks`, change `artist: qt.artist,` to:

```dart
        artist: qt.albumArtistOriginal ?? qt.albumArtist,
```

and add to the `extras: { ... }` map (alongside `titleTranslit`/`titleTranslate`):

```dart
          'artistReading': qt.albumArtistReading,
```

- [ ] **Step 4: Render the artist bilingually in the bar**

In `lib/widgets/now_playing_bar.dart`, replace the artist `Text` (the `if (item.artist != null) Text(item.artist!, ...)` block) with:

```dart
                        if (item.artist != null)
                          BilingualText(
                            original: item.artist!,
                            translit: item.extras?['artistReading'] as String?,
                            translate: null,
                            leads: leads,
                            primaryStyle:
                                Theme.of(context).textTheme.bodySmall,
                          ),
```

(`leads` is already obtained at the top of the bar's build; `BilingualText` is already imported.)

- [ ] **Step 5: Run it, verify PASS, then run the playback sync test for regressions**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/audio/media_items_for_queue_tracks_test.dart test/audio/playback_controller_sync_test.dart 2>&1 | tail -5`
If `playback_controller_sync_test` asserts on `MediaItem.artist`, set the album-artist fields on its
`QueueTrack` fixtures and update the assertion to the album-artist. Expected: all pass.

- [ ] **Step 6: Analyze + format + commit**

```bash
cd /home/autarch/projects/olivier
mise exec -- dart format lib/audio/playback_controller.dart lib/widgets/now_playing_bar.dart test/audio/media_items_for_queue_tracks_test.dart
mise exec -- flutter analyze lib/audio/playback_controller.dart lib/widgets/now_playing_bar.dart
git add lib/audio/playback_controller.dart lib/widgets/now_playing_bar.dart test/audio/media_items_for_queue_tracks_test.dart
git commit -m "Now-playing bar: bilingual album-artist via MediaItem extras

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Info popups show album-artist + reading

**Files:**
- Modify: `lib/widgets/info_dialog.dart`
- Test: `test/info_dialog_test.dart`

- [ ] **Step 1: Update the info-fields test**

In `test/info_dialog_test.dart`, the first test asserts `trackInfoFields` includes `'Artist'`.
Change the fixture + assertions so it expects the album-artist instead. On that test's `Track`,
add:

```dart
      albumArtist: '椎名林檎',
      albumArtistReading: 'Shiina Ringo',
```

and update the label assertions:

```dart
    expect(labels, contains('Album artist'));
    expect(labels, isNot(contains('Artist'))); // tag artist dropped
    expect(labels, contains('Album artist reading'));
    expect(fields.firstWhere((f) => f.$1 == 'Album artist').$2, '椎名林檎');
    expect(
        fields.firstWhere((f) => f.$1 == 'Album artist reading').$2,
        'Shiina Ringo');
```

- [ ] **Step 2: Run it, verify FAILS** — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/info_dialog_test.dart`

- [ ] **Step 3: Update the three field builders**

In `lib/widgets/info_dialog.dart`:

In `trackInfoFields`, replace `_add(out, 'Artist', t.artist);` with:

```dart
  _add(out, 'Album artist', t.albumArtistOriginal ?? t.albumArtist);
  _add(out, 'Album artist reading', t.albumArtistReading);
```

In `queueTrackInfoFields`, replace `_add(out, 'Artist', t.artist);` with:

```dart
  _add(out, 'Album artist', t.albumArtistOriginal ?? t.albumArtist);
  _add(out, 'Album artist reading', t.albumArtistReading);
```

In `albumInfoFields`, replace `_add(out, 'Album artist', a.albumArtist);` with:

```dart
  _add(out, 'Album artist', a.albumArtistOriginal ?? a.albumArtist);
  _add(out, 'Album artist reading', a.albumArtistReading);
```

(Distinct `'Album artist reading'` label avoids colliding with the title's existing `'Reading'`
row. `_add` already omits null/empty values.)

- [ ] **Step 4: Run it, verify PASS; fix any other info test that asserted the tag 'Artist'**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/info_dialog_test.dart test/queue_row_info_test.dart 2>&1 | tail -5`
For any failure that asserted the old `'Artist'` field, update its fixture/assertion to the
album-artist (same pattern). Expected: all pass.

- [ ] **Step 5: Analyze + format + commit**

```bash
cd /home/autarch/projects/olivier
mise exec -- dart format lib/widgets/info_dialog.dart test/info_dialog_test.dart
mise exec -- flutter analyze lib/widgets/info_dialog.dart
git add lib/widgets/info_dialog.dart test/info_dialog_test.dart
git commit -m "Info popups: show album-artist + reading instead of tag artist

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Refresh every surface on override change

**Files:**
- Modify: `lib/audio/queue_controller.dart` (`refreshMetadata`)
- Modify: `lib/widgets/artist_reading_dialog.dart` (`onSubmit`)
- Test: `test/artist_reading_dialog_test.dart`

- [ ] **Step 1: Add `refreshMetadata` to QueueController**

In `lib/audio/queue_controller.dart`, after the `revision` field declaration
(`final ValueNotifier<int> revision = ValueNotifier(0);`) add:

```dart
  /// Re-resolve the now-playing/queue metadata without changing the queue
  /// order — used when an artist's reading override changes so the displayed
  /// album-artist (and its reading) refreshes in the queue panel, the
  /// now-playing bar, and MPRIS.
  void refreshMetadata() => revision.value++;
```

- [ ] **Step 2: Write the failing test**

In `test/artist_reading_dialog_test.dart`, add (the existing `showArtistReadingDialog wires the FFI
seam` test is the template — reuse `_reading`). This uses a real `QueueController` and listens to
its `revision` to detect the refresh, and **watches** the three providers so that
`ref.invalidate(...)` actually triggers a rebuild it can count (an `invalidate` on an unwatched
provider is a no-op):

```dart
  testWidgets('showArtistReadingDialog refreshes queue + invalidates providers',
      (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    var refreshes = 0;
    qc.revision.addListener(() => refreshes++); // refreshMetadata bumps revision

    final builds = <String, int>{};
    int bump(String k) => builds[k] = (builds[k] ?? 0) + 1;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbPathProvider.overrideWithValue(':memory:'),
        artistReadingFnProvider.overrideWithValue((mbid) async => _reading),
        setArtistReadingOverrideFnProvider
            .overrideWithValue((mbid, r, s) async {}),
        queueControllerProvider.overrideWithValue(qc),
        artistsProvider.overrideWith((ref) {
          bump('artists');
          return <Artist>[];
        }),
        albumsProvider.overrideWith((ref) {
          bump('albums');
          return <Album>[];
        }),
        tracksProvider.overrideWith((ref) {
          bump('tracks');
          return <Track>[];
        }),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            // Keep the providers alive so invalidate() triggers a rebuild.
            ref.watch(artistsProvider);
            ref.watch(albumsProvider);
            ref.watch(tracksProvider);
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showArtistReadingDialog(context, ref, 'm-ringo'),
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    ));
    await tester.pumpAndSettle(); // initial builds = 1 each

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(refreshes, greaterThanOrEqualTo(1), reason: 'queue refreshed');
    expect(builds['artists'], greaterThanOrEqualTo(2)); // invalidated → rebuilt
    expect(builds['albums'], greaterThanOrEqualTo(2));
    expect(builds['tracks'], greaterThanOrEqualTo(2));
  });
```

Add the imports this test needs at the top of the file:

```dart
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/playback_controller.dart'; // queueControllerProvider
import 'support/fake_queue_player.dart';
```

- [ ] **Step 3: Run it, verify FAILS** (onSubmit only invalidates `artistsProvider` today)

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test test/artist_reading_dialog_test.dart`

- [ ] **Step 4: Update `onSubmit`**

In `lib/widgets/artist_reading_dialog.dart`, add the import for `queueControllerProvider`:

```dart
import 'package:olivier/audio/playback_controller.dart';
```

and change the dialog's `onSubmit` body from:

```dart
      onSubmit: (r, s) async {
        await ref.read(setArtistReadingOverrideFnProvider)(mbid, r, s);
        ref.invalidate(artistsProvider);
      },
```

to:

```dart
      onSubmit: (r, s) async {
        await ref.read(setArtistReadingOverrideFnProvider)(mbid, r, s);
        ref.read(queueControllerProvider).refreshMetadata();
        ref.invalidate(artistsProvider);
        ref.invalidate(albumsProvider);
        ref.invalidate(tracksProvider);
      },
```

- [ ] **Step 5: Run it, verify PASS** — `cd /home/autarch/projects/olivier && mise exec -- flutter test test/artist_reading_dialog_test.dart`

- [ ] **Step 6: Full verification**

Run: `cd /home/autarch/projects/olivier && mise exec -- flutter test 2>&1 | tail -2`
Run: `cd /home/autarch/projects/olivier/rust && mise exec -- cargo test 2>&1 | tail -5`
Run: `cd /home/autarch/projects/olivier && mise exec -- flutter analyze lib 2>&1 | tail -3`
Expected: all green. (A `precious lint --all` `typos` failure on the untracked `TODO` is the user's
note — ignore; never stage `TODO`.)

- [ ] **Step 7: Format + commit**

```bash
cd /home/autarch/projects/olivier
mise exec -- dart format lib/audio/queue_controller.dart lib/widgets/artist_reading_dialog.dart test/artist_reading_dialog_test.dart
git add lib/audio/queue_controller.dart lib/widgets/artist_reading_dialog.dart test/artist_reading_dialog_test.dart
git commit -m "Refresh queue + popups when an artist reading override changes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Album/Track/QueueTrack album-artist fields → Tasks 1/2/3. ✓
- `albums_for_artist`/`tracks_for_album`/`tracks_for_paths` joins + effective reading + override survival + clear → Tasks 1/2/3 tests. ✓ (LEFT JOIN for nullable FK in 2/3.)
- Bridge regen → Task 4. ✓
- Queue rows bilingual album-artist → Task 5. ✓
- Now-playing bar (MediaItem + bar render) → Task 6. ✓
- Info popups (3 builders, replacing tag) → Task 7. ✓
- Live refresh (`refreshMetadata` bump + invalidations) → Task 8. ✓
- Tests: Rust round-trips (1-3), queue render (5), media mapping (6), info fields (7), refresh wiring (8). ✓

**Type consistency:** Rust `album_artist`/`album_artist_original`/`album_artist_reading` (all `Option<String>`) → Dart `albumArtist`/`albumArtistOriginal`/`albumArtistReading`, used consistently in every display task. Column indices: Album adds 8/9; Track adds 10/11/12; QueueTrack adds 9/10/11 — each matches the SELECT order in its task. `refreshMetadata()` defined in Task 8 Step 1, called in Step 4.

**Placeholders:** none — every step shows exact code. Existing-fixture ripples are handled by the
display tasks (Steps that update the specific asserting tests + a run-and-fix instruction for the
rest).
