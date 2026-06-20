# Per-Artist Reading + Sort Override — Design

**Status:** approved scope, ready for implementation plan
**Date:** 2026-06-20

## Goal

Let the user manually override an album-artist's **displayed reading** and its **sort
position** in the artist list, replacing MusicBrainz's romanization when it disagrees with
the user's preference (e.g. show/sort "Shiina" instead of MusicBrainz's "Sheena"). The
override is per-artist, persists across MusicBrainz re-enrichment and library re-scans, and
is editable from the artist column's right-click menu.

## Scope decision

The override affects **both** the displayed reading **and** the sort position (user choice,
2026-06-20). Because a free-text reading is not a sortable "Last, First" string, the dialog
exposes the two independently: a **Reading** field and a **Sort as** field.

The artist reading is displayed in exactly one place — `lib/catalog/artist_column.dart:86-91`
(`BilingualText(original: nameOriginal ?? name, translit: transliteration)`) — and SELECTed in
exactly one query — `artists_page` (`rust/src/catalog/query.rs:6-31`). Albums show a plain
`album_artist` string (`albums_for_artist`), not the artist's transliteration, so they are
unaffected. This keeps the change tightly bounded.

### Non-goals

- Overriding the artist's `name` / `name_original` (original script) — only the reading + sort.
- Overriding album-artist text on album rows, or track/queue artist text (those are plain tag
  strings, not the MB artist reading).
- Surviving an artist being pruned as an orphan. The override lives on the `artist` row; if the
  artist's last release is removed and the orphan sweep deletes the row, its override is dropped
  with it (re-adding the artist re-inserts with NULL overrides). This matches the existing
  cascade-delete behavior and is acceptable.

## Data model

One new migration appended to `MIGRATION_SLICE` in `rust/src/db.rs` (after the Phase 2b
`name_original` migration at line 102). The existing Phase 2 migration already bundles two
`ALTER`s in one `M::up`, so:

```rust
// ── Per-artist manual reading + sort override ────────────────────────
M::up(
    "ALTER TABLE artist ADD COLUMN transliteration_override TEXT;
     ALTER TABLE artist ADD COLUMN sort_name_override TEXT;",
),
```

Both columns are nullable; `NULL` means "no override, use the MusicBrainz value". They default
to `NULL` for existing and newly-scanned rows.

## Query changes (`rust/src/catalog/query.rs`)

### `artists_page` — return *effective* values

Return `COALESCE(override, mb_value)` for both the reading and the sort name, so display,
ordering, and the keyset cursor all stay consistent. The `Artist` DTO is **unchanged** — the
existing `transliteration` and `sort_name` fields simply carry the effective value.

```sql
SELECT a.mbid, a.name,
       COALESCE(a.sort_name_override, a.sort_name)            AS sort_name,
       COALESCE(a.transliteration_override, a.transliteration) AS transliteration,
       a.name_original
FROM artist a
WHERE a.mbid IN (SELECT DISTINCT album_artist_mbid FROM release)
  AND (?1 IS NULL OR COALESCE(a.sort_name_override, a.sort_name) > ?1 COLLATE NOCASE)
ORDER BY COALESCE(a.sort_name_override, a.sort_name) COLLATE NOCASE
LIMIT ?2
```

The caller passes the previous page's last `sort_name` (now the effective value) as `after`, so
keyset pagination remains correct. (`artistsProvider` currently fetches a single page of
`limit: 1000`, so pagination isn't exercised today, but the query stays correct if it is added.)

### New: `artist_reading` — raw values for the edit dialog

Returns the *raw* (non-coalesced) values so the dialog can show the current override alongside
what MusicBrainz says. New `ArtistReading` struct in `rust/src/catalog/schema.rs`:

```rust
pub struct ArtistReading {
    pub name: String,
    pub name_original: Option<String>,
    pub mb_transliteration: Option<String>,
    pub transliteration_override: Option<String>,
    pub mb_sort_name: String,
    pub sort_name_override: Option<String>,
}
```

```rust
pub fn artist_reading(conn: &Connection, mbid: &str) -> anyhow::Result<ArtistReading> {
    let r = conn.query_row(
        "SELECT name, name_original, transliteration, transliteration_override,
                sort_name, sort_name_override
         FROM artist WHERE mbid = ?1",
        [mbid],
        |r| Ok(ArtistReading {
            name: r.get(0)?,
            name_original: r.get(1)?,
            mb_transliteration: r.get(2)?,
            transliteration_override: r.get(3)?,
            mb_sort_name: r.get(4)?,
            sort_name_override: r.get(5)?,
        }),
    )?;
    Ok(r)
}
```

### New: `set_artist_reading_override` — write/clear the override

```rust
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

`None` clears that dimension's override (falls back to the MB value via the `COALESCE`).

## Enrichment isolation (survives re-enrich + re-scan)

`rust/src/enrich/store.rs:51` is the only writer of the MB columns:

```sql
UPDATE artist SET transliteration = ?1, sort_name = ?2, name_original = ?3 WHERE mbid = ?4
```

It never touches `transliteration_override` / `sort_name_override`, so re-enrichment updates the
MB values underneath while the override continues to win in `artists_page`. Scan inserts new
artists with the override columns defaulting to `NULL`. The override is written *only* through
`set_artist_reading_override`. A Rust test asserts this explicitly (set override → re-run the
enrich `UPDATE` → effective value still equals the override).

## FFI (`rust/src/api/catalog.rs`)

Two new sync functions, same shape as the existing catalog FFIs (open a connection, call the
query):

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
        &db::open(&db_path)?, &mbid, reading.as_deref(), sort.as_deref(),
    )
}
```

Add `ArtistReading` to the `schema` import. Regenerate the bridge with
`mise exec -- flutter_rust_bridge_codegen generate` and commit the regenerated
`lib/src/rust/**` + `rust/src/frb_generated.rs`.

## Dart

### Seams (`lib/state/providers.dart`)

Two new fn providers modeled on `rereadTrackTagsFnProvider` / `setSettingFnProvider`:

```dart
typedef ArtistReadingFn = Future<ArtistReading> Function(String mbid);
final artistReadingFnProvider = Provider<ArtistReadingFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid) => artistReading(dbPath: db, mbid: mbid);
});

typedef SetArtistReadingOverrideFn =
    Future<void> Function(String mbid, String? reading, String? sort);
final setArtistReadingOverrideFnProvider =
    Provider<SetArtistReadingOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid, reading, sort) => setArtistReadingOverride(
        dbPath: db, mbid: mbid, reading: reading, sort: sort);
});
```

(Imports reference the generated `artistReading` / `setArtistReadingOverride` bridge functions.)

### Pure override-value helper (testable without widgets)

```dart
/// The value to persist for one override dimension: the trimmed field text,
/// unless it is empty or matches the MusicBrainz value, in which case `null`
/// (no override — fall back to MusicBrainz).
String? overrideValue(String field, String? mbValue) {
  final v = field.trim();
  if (v.isEmpty || v == (mbValue ?? '')) return null;
  return v;
}
```

This keeps the DB free of redundant overrides and makes "revert" work by either clearing a
field or retyping the MusicBrainz value. Unit-tested directly.

### Dialog (`lib/widgets/artist_reading_dialog.dart`)

`Future<void> showArtistReadingDialog(BuildContext, WidgetRef, String mbid)`:

1. Fetch `final r = await ref.read(artistReadingFnProvider)(mbid)`.
2. Show an `AlertDialog`:
   - Title: `Set reading` with the original script (`r.nameOriginal ?? r.name`) as context.
   - **Reading** `TextField`, pre-filled with `r.transliterationOverride ?? r.mbTransliteration ?? ''`,
     helper `MusicBrainz: <r.mbTransliteration ?? '—'>`.
   - **Sort as** `TextField`, pre-filled with `r.sortNameOverride ?? r.mbSortName`,
     helper `MusicBrainz: <r.mbSortName>`.
   - Actions: **Cancel** (no change) and **Save**.
3. On **Save**:
   - `final reading = overrideValue(readingController.text, r.mbTransliteration);`
   - `final sort = overrideValue(sortController.text, r.mbSortName);`
   - `await ref.read(setArtistReadingOverrideFnProvider)(mbid, reading, sort);`
   - `ref.invalidate(artistsProvider);`
   - Close the dialog.

Clearing a field reverts that dimension to MusicBrainz (helper text shows what it reverts to).

### Context menu (`lib/widgets/context_menu.dart`)

Add an optional `onSetReading` callback and a "Set reading…" item, following the existing
optional-callback pattern:

```dart
final ValueChanged<QueueEntityRef>? onSetReading;
// ...in items:
if (onSetReading != null)
  const PopupMenuItem<String>(value: 'reading', child: Text('Set reading…')),
// ...in switch:
case 'reading':
  onSetReading?.call(entity);
```

### Wiring (`lib/catalog/artist_column.dart`)

Add to the artist row's `RowContextMenu`:

```dart
onSetReading: (_) => showArtistReadingDialog(context, ref, artist.mbid),
```

Display is otherwise unchanged: `BilingualText(translit: artist.transliteration, …)` now shows
the effective reading because `artists_page` returns the coalesced value.

## Testing

### Rust (`rust/tests/`)

A round-trip test (model after existing query tests; build a temp DB via `db::open`, insert an
artist + a release referencing it so it passes the `album_artist_mbid` filter):

1. Seed artist with `transliteration='Sheena Ringo'`, `sort_name='Sheena, Ringo'`.
2. `set_artist_reading_override(mbid, Some("Shiina Ringo"), Some("Shiina, Ringo"))`.
3. `artists_page` returns effective `transliteration == "Shiina Ringo"`, `sort_name == "Shiina, Ringo"`.
4. **Ordering**: with a second artist sorting between the MB and override positions, the
   override moves the row (assert the page order reflects the override sort, not the MB sort).
5. **Survives enrich**: run the enrich `UPDATE artist SET transliteration=…, sort_name=…` with
   new MB values; `artists_page` still returns the override values.
6. `artist_reading` returns the raw `mb_*` and `*_override` fields distinctly.
7. **Clear**: `set_artist_reading_override(mbid, None, None)` → `artists_page` falls back to the
   MB values.

### Dart (host-VM, no FFI)

- `overrideValue` unit tests: empty → null; whitespace → null; equals MB → null; differs → value;
  MB null + non-empty → value.
- Dialog widget test: override `artistReadingFnProvider` with a fake returning known values and
  `setArtistReadingOverrideFnProvider` with a recording fake. Assert the two fields pre-fill and
  the helper text shows the MB values; edit Reading to "Shiina Ringo", tap Save, assert the
  recording fake received `(mbid, "Shiina Ringo", <sort>)`. A second case: clear a field → Save
  passes `null` for that dimension.
- Context-menu test: a `RowContextMenu` with a non-null `onSetReading` shows the "Set reading…"
  item and invokes the callback.

## Touched files

- `rust/src/db.rs` — migration.
- `rust/src/catalog/schema.rs` — `ArtistReading` struct.
- `rust/src/catalog/query.rs` — `artists_page` COALESCE; `artist_reading`; `set_artist_reading_override`.
- `rust/src/api/catalog.rs` — two FFIs.
- `rust/src/frb_generated.rs`, `lib/src/rust/**` — regenerated bridge.
- `lib/state/providers.dart` — two seams.
- `lib/widgets/artist_reading_dialog.dart` — new dialog + `overrideValue`.
- `lib/widgets/context_menu.dart` — `onSetReading` + menu item.
- `lib/catalog/artist_column.dart` — wire `onSetReading`.
- `rust/tests/…`, `test/…` — tests above.
