# Olivier — Music Player Design Spec

- **Date:** 2026-06-13
- **Status:** Approved (brainstorming complete) — ready for implementation planning
- **Owner:** autarch (autarch@urth.org)

---

## 1. Overview

Olivier is a personal music player for a local collection of tagged audio files, running on **Linux desktop** and **Android**. It browses a library by artist → album → track (grouped by *album artist*), plays audio with OS-integrated background playback, and enriches metadata from **MusicBrainz** — notably to show **multi-language** data (original script plus romaji transliteration and English translation) for a large Japanese-music collection.

The collection is already **MusicBrainz Picard-tagged**, so files carry embedded MBIDs; matching is exact MBID lookup, not fuzzy search.

### Goals (v1, delivered in phases)

- Play MP3, FLAC, AAC/M4A, ALAC, Ogg Vorbis, Opus. Basic transport: play/pause, seek (advance/rewind within a track), next/previous.
- Browse the library: Artists → Albums (grouped by album artist) → Tracks.
- Display per album/track: album artist, album name, **original** release year and **reissue** year, track number + title, track length, last-played date, added-to-catalog date.
- **Multi-language display:** original script plus transliteration (for names) and/or translation (for titles), where MusicBrainz has it. Default layout "Latin-leads" (reading/translation primary, original secondary), with a per-user toggle to flip to original-leads.
- Full **search** across artists/albums/tracks, matching original *and* romaji/translation.
- **Playlists:** create, browse, edit, play.
- **Play queue:** add individual tracks or whole albums; "play now" / "play next" / "add to queue"; **shuffle** the queue; **shuffle-all** (enqueue the entire library shuffled).
- **Background playback** with OS media controls (Android notification/lockscreen/Bluetooth; Linux MPRIS / media keys).
- Per-device, **local-only**: each device scans its own files and enriches independently; no cross-device sync in v1.

### Non-goals (explicitly deferred past v1)

Gapless playback, ReplayGain/volume normalization, crossfade, automatic folder-watching, manual MusicBrainz match UI for un-tagged files, and any cross-device sync. The architecture must **not preclude** gapless later.

---

## 2. Key decisions & rationale

These were settled during brainstorming and are grounded in verified research (sources in Appendix C).

| Decision | Choice | Why |
|---|---|---|
| **Stack** | **Flutter UI + audio, Rust core via `flutter_rust_bridge`** | Flutter gives turnkey, *proven* background audio on Android (`audio_service`) + Linux libmpv playback (validated by [Harmonoid](https://github.com/harmonoid/harmonoid)); Rust owns the correctness-critical core (tag reading, MusicBrainz, catalog) where the user is strongest and where `lofty` reads embedded MBIDs flawlessly. Retires the one real risk of pure-Flutter (uncertain MBID extraction in Dart tag libs). |
| **Rejected: Tauri/Dioxus all-Rust** | No | Both render via WebView on Android → web audio suspends in background (OS policy, unfixable from web layer). No mature cross-platform Rust audio engine; pure-Rust Opus/HE-AAC decode still incomplete. Would require owning a Kotlin Media3 foreground-service plugin. |
| **Metadata source** | MusicBrainz `ws/2`, keyed by embedded MBIDs | Files are Picard-tagged. Aliases give artist transliterations; pseudo-releases give translated/transliterated titles. "Local-only" = no cross-device sync, *not* airgapped — network at scan/enrich time is fine. |
| **Catalog DB** | SQLite (`rusqlite`, bundled), owned by Rust | Single source of truth; 5–20k tracks is trivial for SQLite; FTS5 for search. |
| **Multi-language default** | Layout "A — Latin-leads" + per-user toggle | User reads by romaji/English primarily; original always shown. Toggle (default A) allows original-leads without redesign. |
| **Search** | Full, bilingual (FTS5) | A 5–20k library needs global search across original + romaji + translation. |
| **Play tracking** | Record a play when the user reaches the **first of**: track finishes, ≥50% elapsed, or 4:00 elapsed. Store stats per track (§4). | Matches the brief's "last played" display plus useful history. The 50% and 4:00 values are the configurable `play_threshold_*` settings. |
| **Scanning** | Manual incremental rescan of root folders | Simplest, predictable; watch-folders deferred (and limited on Android). |
| **Grouping** | By **album-artist MBID** | The brief requires album-artist grouping, not track-artist. Various Artists via the canonical VA MBID `89ad4ac3-39f7-470e-963a-56509c546377`. |

---

## 3. Architecture

One application, two layers, split along the boundary each language serves best.

### 3.1 `olivier_core` — Rust library (compiled into the app via `flutter_rust_bridge`)

Owns **all persistence and domain logic**:

- **Scanner** — incremental walk of configured root folders; detects new/changed files by `(mtime, size)`; resumable; streams progress.
- **Tag reader** (`lofty`) — extracts embedded MBIDs and tags per the Picard mapping (Appendix A). Must drop to per-format raw APIs for the recording MBID (`UFID:http://musicbrainz.org` in ID3, `MUSICBRAINZ_TRACKID` in Vorbis, `----:com.apple.iTunes:MusicBrainz Track Id` in MP4) and for arbitrary `TXXX`/`----` freeform keys. Also extracts embedded cover art.
- **Catalog** (`rusqlite` + bundled SQLite, FTS5 enabled) — the single source of truth (schema §4).
- **MusicBrainz client** — single-threaded rate-limited queue (≥1.05 s spacing, exponential backoff on HTTP 503), required User-Agent `Olivier/<version> ( autarch@urth.org )`, `fmt=json`, MBID-keyed response cache stored in the catalog. De-dups to unique entities (a 20k-track library is only a few thousand unique releases / few hundred album-artists).
- **API surface** to Dart — queries (list artists; albums for artist; tracks for album; global search; now-playing detail) and commands (rescan; enrich; create/rename/delete playlist; add/remove/reorder playlist items; enqueue; reorder/clear queue; set shuffle; record play; read/write settings). Returns plain DTOs; **no shared mutable state**.

### 3.2 `olivier` — Flutter/Dart app

Owns **UI + audio**:

- **UI** — column browser (§6), now-playing bar, queue, playlists, search, settings; Material 3; virtualized lists.
- **Audio** — `just_audio` (ExoPlayer/Media3 on Android; libmpv via `just_audio_media_kit` on Linux) + `audio_service` for background playback and OS media controls (§7). Holds the runtime player, fed by the queue that Rust persists.

### 3.3 FFI boundary

- Dart calls Rust for **all** data and mutations; Rust returns DTOs.
- **Large lists are paged across the bridge** (keyset or offset+limit) to feed virtualized lists cheaply — never marshal 20k rows at once.
- **Long-running operations** (scan, enrich) run on Rust threads and **stream progress/state events** to Dart via `flutter_rust_bridge` streams.
- A **contract test** pins the DTO/command surface so both sides evolve together.

```
┌────────────────────────── olivier (Flutter / Dart) ──────────────────────────┐
│  Column browser · Now-playing · Queue · Playlists · Search · Settings (UI)     │
│  just_audio (+ just_audio_media_kit) + audio_service  ── runtime player        │
└───────────────▲───────────────────────────────────────────────┬───────────────┘
                │ DTOs / streams (flutter_rust_bridge)            │ commands
┌───────────────┴───────────────────────────────────────────────▼───────────────┐
│  olivier_core (Rust):  Scanner · lofty Tag reader · MusicBrainz client          │
│                        SQLite Catalog (single source of truth, FTS5)            │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

### 3.4 Runtime queue ↔ persistence

The single most load-bearing integration, defined explicitly:

- **Runtime authority:** the **Dart/`audio_service` layer is authoritative** for queue order, current index, and playback position. The Rust `queue_item` / `playback_state` tables are a **persistence sink**, not a live mirror.
- **Write-back to Rust** happens on every structural change (enqueue, reorder, remove, clear, shuffle toggle) and as a **throttled position write** (~every 5 s, and on pause/stop).
- **Restart hydration:** Rust loads `queue_item` + `playback_state` → Dart builds the `AudioSource` list via `AudioPlayer.setAudioSources(...)` and seeks to `current_index` + `position_ms`.
- **Stale entries:** a `queue_item.track_id` that no longer resolves to an existing file after a rescan is **skipped** on hydration and pruned.
- **Shuffle is an app-side permutation** (not engine shuffle — `just_audio_media_kit` ignores engine shuffle on Linux): toggling shuffle computes a permutation stored in `queue_item.shuffled_position` and rebuilds the source list; toggling off restores `position` order. Same mechanism on both platforms.

This round-trip is a **Phase-0 deliverable**, not just a skeleton.

---

## 4. Data model (catalog)

MBID-keyed, mirroring MusicBrainz so enrichment slots in. SQLite. (Names indicative; final column names at implementation.)

**Core entities**
- `artist(mbid PK, name, sort_name)`
- `artist_alias(artist_mbid FK, name, sort_name, locale, primary BOOL, type)` — the chosen display **transliteration** is derived from these (§5.1).
- `release_group(mbid PK, title, first_release_date)` — `first_release_date` → **original** year.
- `release(mbid PK, release_group_mbid FK, title, date, album_artist_mbid FK)` — `date` → **this edition / reissue** year.
- `track(id PK, release_mbid FK NULL, recording_mbid NULL, position, disc, title, length_ms)` — a **release-track**, unique per `(release_mbid, recording_mbid, position)`. `recording_mbid` is intentionally **non-unique** (the same recording appears on many releases). MBIDs are `NULL` for unmatched files.
- `file(id PK, path UNIQUE, mtime, size, codec, recording_mbid NULL, release_mbid NULL, track_id FK, added_at, has_cover BOOL, enriched BOOL)` — the physical file. **Every cataloged file (matched or not) maps to exactly one `track` row**, so `track_id` is the universal identity used by playlists, the queue, and play history. `codec` ∈ {mp3, flac, aac, alac, vorbis, opus}.

**File↔track grain.** A file resolves to the one `track` row matching its tagged `(release_mbid, recording_mbid, position)` (disambiguated via `MUSICBRAINZ_RELEASETRACKID` when present). Unmatched files get a synthetic `track` row built from plain tags (MBIDs `NULL`). If the same recording is owned on two albums, that is two distinct `track` rows — **no cross-release de-duplication** — so play counts and dates never silently merge across albums. The **displayed "added-to-catalog date"** for a track is its file's `added_at`; for an album it is `MIN(added_at)` over the album's files.

**Title translations** (populated from pseudo-releases; nullable — most releases have none)
- `release_title_alt(release_mbid FK, kind ENUM('translit','translate'), title)`
- `track_title_alt(recording_mbid FK, kind ENUM('translit','translate'), title)` — joined to files by recording MBID.
- *Why different keys:* release alts key on `release_mbid`; track alts key on `recording_mbid` so a transliteration/translation captured from one release's pseudo-release **carries to every owned release of the same recording** (intended).

**Play history**
- `play(track_id FK, played_at)` — one row per qualifying play, keyed on **`track_id`** (always exists, incl. unmatched files; never collapses the same recording across two owned albums).
- `track_stats(track_id PK, last_played, play_count, first_played)` — the **single** home for these aggregates, updated on each `play` insert. Recording-level aggregates, if ever needed, are computed on demand by joining `track.recording_mbid`.

**Playlists & queue**
- `playlist(id PK, name, created_at)`, `playlist_item(playlist_id FK, position, track_id FK)`.
- `queue_item(position, track_id FK, shuffled_position)` + `playback_state(current_index, position_ms, shuffle BOOL)` — persisted so the queue/position survive restart.

**Settings & cache**
- `setting(key PK, value)` — keys & defaults: `root_folders` (list, empty), `language_leads` (`A`), `mb_contact_email` (`autarch@urth.org`), `play_threshold_percent` (`50`), `play_threshold_seconds` (`240`).
- `mb_cache(entity_type, mbid, inc_set, json, fetched_at)` — MBID-keyed MusicBrainz response cache. Entries **never auto-expire** (MBID data is effectively immutable); refresh is **manual only** (a Settings action). One **canonical `inc_set` per entity type** (the full bundle in §5.1) is used, so the cache key is effectively per-entity.

**Search**
- FTS5 virtual table over **all** title/name forms — original, romaji transliteration, English translation, and sort names — so `Ringo`, `Shiina`, and `椎名` all match the same artist. Original-script columns use the FTS5 **`trigram`** tokenizer (SQLite ≥3.34) so CJK substrings (`椎名`) match; Latin columns use `unicode61`. (Confirm the bundled SQLite includes `trigram` in the Phase-0 catalog spike.)

**Grouping rule:** albums are grouped under their **album artist** (`release.album_artist_mbid`); compilations group under Various Artists (`89ad4ac3-…`).

---

## 5. Scan → enrich pipeline

### 5.1 Multi-language enrichment from MusicBrainz

Files carry MBIDs, so every call is a direct **lookup by MBID** (Appendix B has exact endpoints).

**Per album, ~2–3 cached GETs:**
1. `GET /ws/2/release/<release-mbid>?inc=recordings+release-rels+release-groups+artist-credits&fmt=json` → original titles, track `recording.id`s, release-group `first-release-date` (original year), release `date` (reissue year), and any `transl-tracklisting` pseudo-release link(s). (`release-rels` returns the `transl-tracklisting` relation — type-id `fc399d47-…` — whose `release.id` is the pseudo-release MBID used in step 2.)
2. If a pseudo-release link exists: `GET /ws/2/release/<pseudo-mbid>?inc=recordings&fmt=json` → translated/transliterated **album** title (the pseudo-release's own `title`) and **track** titles (`media[].tracks[].title`), joined to your files by **recording MBID**.
3. `GET /ws/2/artist/<album-artist-mbid>?inc=aliases&fmt=json` → artist **transliteration**.

**Artist transliteration selection** (from `aliases`):
1. Keep `type == "Artist name"` (skip `"Legal name"`, `"Search hint"`).
2. Prefer `locale == "en"` **and** `primary == true`; else any `locale == "en"`; else the entity `sort-name`.
3. **Tie-break** when multiple en/primary "Artist name" candidates exist: sort by `name` ascending and take the first — deterministic and stable (e.g., 椎名林檎 → "Ringo Sheena" before "Sheena Ringo").

**Title alternates:** a release may have a transliteration pseudo-release *and* a translation pseudo-release (e.g., *Muzai Moratorium* + *Innocence Moratorium*). Store **both** kinds when present. Pseudo-releases attach at the **release** level; if the tagged release has none, **fall back** to browsing the release-group's other releases (`/ws/2/release?release-group=<mbid>&inc=release-rels&limit=100&offset=…`, paging when needed). Select the release whose relations include `transl-tracklisting` (`fc399d47-…`) and whose tracks align by recording MBID. These extra requests count against the 1 req/s budget, so reissue/VA-heavy libraries enrich more slowly.

**Caching:** MBID + inc-set keyed, stored in `mb_cache`, effectively permanent. De-dup at the entity level. One-time enrichment of a 20k-track library is a few thousand requests (~tens of minutes at 1 req/s), then cheap forever. **No local MusicBrainz mirror** — the rate-limited public API + cache is sufficient at this scale.

### 5.2 Scan

Incremental, resumable, streams progress:
1. Walk root folders; for each new/changed audio file (by mtime+size) read tags via `lofty`.
2. Upsert `file`; derive `artist` / `release_group` / `release` / `track` rows from embedded MBIDs + tags; stamp `added_at` on first sight; extract cover art.
3. Flag pruned/removed files.

### 5.3 Unmatched files

Files without MBIDs are still cataloged from plain tags, flagged `enriched = false`, fully browsable/playable, just without transliteration. Each gets a **synthetic `track` row** (MBIDs `NULL`), so it can be queued, added to playlists, and accrue play history exactly like matched files. (Manual-match UI is post-v1; the schema leaves room.)

---

## 6. UI / UX

**Top-level sections** (icon rail on desktop / bottom nav on mobile): **Library · Playlists · Queue · Search · Settings.**

- **Library — column browser (layout "A"):** **Artists | Albums | Tracks**, resizable columns. Albums grouped by album artist, with original/reissue year; track rows show #, **bilingual title (Latin-leads)**, length, and (on demand) last-played / added-date columns. Context menu on artist/album/track: **Play now · Play next · Add to queue · Add to playlist**. A global **Shuffle all** action lives here. *(Optional, non-critical: a flat "All Albums" first-column mode.)*
- **Multi-language rows (layout A, default):** reading/translation primary, original secondary beneath. Names get a *reading* only (椎名林檎 → Ringo Sheena); titles may get romaji *and* an English translation (無罪モラトリアム → *Muzai Moratorium* · "Innocence Moratorium"). Latin-only releases show a single title. A per-user **toggle** flips to original-leads (layout B).
- **Now-playing:** persistent bottom bar (cover, bilingual title, artist, transport, seek, time, queue toggle). On mobile, a mini-player above the nav expands to a full now-playing screen.
- **Queue:** upcoming tracks; drag-reorder, remove, clear; **shuffle** toggle (a reversible app-side permutation, §3.4); "Play now" replaces, "Play next" inserts; **shuffle-all** enqueues the whole library shuffled.
- **Playlists:** create/rename/delete; open to a bilingual tracklist; add tracks/albums via context menu; reorder; play or enqueue.
- **Search:** global box; results grouped Artists / Albums / Tracks; matches original **and** romaji/translation.
- **Settings:** root folders (+ rescan), language-leads toggle (default A), MusicBrainz contact email (default autarch@urth.org), play threshold, about.
- **Adaptive:** one Flutter codebase, breakpoint-driven — desktop = rail + columns + bottom bar; mobile = bottom nav + drill-down (Artists → Albums → Album detail) + mini-player. **Embedded cover art** shows in now-playing, album headers, and mobile.

### 6.1 Default sort orders

- **Artists** (album-artist headers) — by **sort name**: people sort *Last, First* (`Nina Simone` → `Simone, Nina`); groups sort by their name (`Living Colour`); leading articles are moved to the end so they're effectively ignored (`The Beatles` → `Beatles, The`, under **B**; `A Perfect Circle` → `Perfect Circle, A`, under **P**; `An Pierle` → `Pierlé, An`). Non-Latin artists sort by their **transliterated** sort name in the same *Last, First* order (椎名林檎 → `Sheena, Ringo`). These are the MusicBrainz `sort-name` conventions — **verified against the live API** (Person → "Last, First"; Group → leading article moved to the end) — so no client-side person/band classification or article-stripping is needed for MB-matched artists.
  - **Sort-key source**, in priority: (1) the chosen display-transliteration alias's `sort-name` (when §5.1 selected one); (2) the MusicBrainz entity `sort-name` (this is also tier 1's value whenever §5.1 fell back to the entity sort-name); (3) the embedded `albumartistsort`/`artistsort` tag (ID3 `TSO2`/`TSOP`, Vorbis `ALBUMARTISTSORT`/`ARTISTSORT`, MP4 `soaa`/`soar`) for un-enriched files; (4) the display name with a leading `A`/`An`/`The` stripped, as a last resort for files with no sort tag at all.
  - The sort key is **distinct from the §5.1 display transliteration**: 椎名林檎 *displays* as `Ringo Sheena` (First Last) but *sorts* as `Sheena, Ringo` (Last, First). The sort key is always a Latin string (transliterated for non-Latin artists) and is compared **case-insensitively**.
- **Albums** (within an artist) — by **original release year** ascending (release-group `first-release-date`), then by the original `release.title` as a tie-break.
- **Tracks** (within an album) — by **disc number**, then **track number**, ascending.

Sorting is computed in the **Rust query layer** (one ordering, consistent across desktop and mobile), with the artist sort key stored/indexed for fast ordered queries. *A manual per-artist sort-name/transliteration override (e.g., to prefer `Shiina` over MusicBrainz's `Sheena`) is a post-v1 enhancement the schema can accommodate via an editable column.*

---

## 7. Cross-platform / OS integration

- **Android:** `audio_service` → `MediaSessionService` + foreground service (`foregroundServiceType="mediaPlayback"`), notification/lockscreen transport, Bluetooth/headset buttons, audio focus, Android-13+ `POST_NOTIFICATIONS`. ExoPlayer/Media3 decodes all six formats.
- **Linux:** libmpv (via `just_audio_media_kit`) decodes all six formats (verify ALAC/Opus coverage of the *packaged* libmpv in the Phase-0 spike). Engine-level shuffle is **not** supported by `just_audio_media_kit`, so shuffle is done app-side (§3.4). **MPRIS2** over D-Bus via **`audio_service_mpris`** (primary) for GNOME/KDE controls + media keys (play/pause/next/prev; Seek/Volume gaps acceptable for v1); raw **`dbus`** is the single fallback if those gaps bite.
- **Gapless not precluded:** both engines support it; deferred, but the queue/player design leaves room.
- **Packaging:** Android APK/AAB; Linux native build first (Flatpak later — bundle/locate libmpv carefully; a known risk tested early in Phase 0).

---

## 8. Testing

TDD throughout.
- **Rust core:** fixture audio clips per format for tag parsing (incl. Opus/Ogg and the `UFID` recording-MBID path); the **real recorded MusicBrainz JSON** captured in research (Shiina Ringo artist `9e414497-…`, release-group 無罪モラトリアム, pseudo-release) for the enrichment client; temp/in-memory SQLite for catalog queries and FTS search; property tests for alias-selection and pseudo-release joins.
- **Dart:** widget tests for the bilingual browser rows and adaptive layout; view-model unit tests; playback/queue integration against a fake core.
- **Boundary:** a thin **FFI contract test** over the DTO/command surface.

---

## 9. Phasing (one spec → phased plan)

- **Phase 0 — Foundations & spikes:** scaffold (Flutter + `flutter_rust_bridge`), CI, and de-risking spikes: (1) `lofty` tag-read incl. MBIDs across all six formats; (2) libmpv playback on the target Linux distro — confirm ALAC/Opus coverage and that app-side shuffle works; (3) `audio_service` background-playback skeleton **plus** the queue-persistence round-trip (§3.4: write-back + restart hydration); (4) catalog spike confirming the bundled SQLite ships FTS5 `trigram` for CJK search.
- **Phase 1 — Catalog + browse + play (Linux first):** Rust scanner/tags/catalog + FFI queries; column browser; basic play/pause/seek/next/prev; now-playing bar; MPRIS. *(Embedded tags only — single language.)* Note: MP4/ALAC files carry no original-date atom, so original year is unavailable pre-enrichment — Phase 1 shows reissue year (`©day`) for those; original year arrives with Phase 2.
- **Phase 2 — Enrichment + multi-language:** MB client + cache; transliterations (aliases) + translations (pseudo-releases) + original/reissue dates; Latin-leads bilingual display + toggle; play tracking (last-played / counts / added date).
- **Phase 3 — Search, playlists, queue/shuffle:** FTS5 bilingual search; playlists CRUD; persistent queue with shuffle + shuffle-all.
- **Phase 4 — Android:** build/packaging; ExoPlayer; `audio_service` background + MediaSession; adaptive mobile UI; on-device scan.
- **Later (post-v1):** gapless, ReplayGain, crossfade, watch-folders, manual MB-match UI, cross-device sync.

---

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| libmpv packaging/codec parity on Linux distros (known fragility) | Spike in Phase 0 on the actual target distro; pin a known-good packaging approach before building UI on top. |
| `audio_service` ↔ `just_audio` ↔ Rust-persisted-queue wiring for background playback | §3.4 defines runtime-authority + write-back + restart-hydration; the Phase-0 queue round-trip proves it end-to-end before feature work. |
| Linux MPRIS package incomplete (no Seek/Volume) | Acceptable for v1 (play/pause/next/prev); raw `dbus` fallback if needed. |
| Pseudo-releases sparse / attached to a different release in the group | Fallback browse across the release-group; always treat transliteration/translation as nullable/optional. |
| MusicBrainz rate limit (1 req/s) | Single-threaded queue, ≥1.05 s spacing, backoff on 503, permanent MBID cache, entity-level de-dup. |
| Two-language build complexity (FFI) | Mirror the proven `metadata_god` pattern (Lofty over `flutter_rust_bridge`); contract-test the boundary. |

---

## Appendix A — Picard tag mapping (fields Olivier reads)

| Field | ID3v2.4 (MP3) | Vorbis (FLAC/Ogg/Opus) | MP4 (M4A/ALAC) |
|---|---|---|---|
| Recording MBID | `UFID:http://musicbrainz.org` | `MUSICBRAINZ_TRACKID` | `----:com.apple.iTunes:MusicBrainz Track Id` |
| Release/Album MBID | `TXXX:MusicBrainz Album Id` | `MUSICBRAINZ_ALBUMID` | `----:…:MusicBrainz Album Id` |
| Release Group MBID | `TXXX:MusicBrainz Release Group Id` | `MUSICBRAINZ_RELEASEGROUPID` | `----:…:MusicBrainz Release Group Id` |
| Artist MBID | `TXXX:MusicBrainz Artist Id` | `MUSICBRAINZ_ARTISTID` | `----:…:MusicBrainz Artist Id` |
| Album Artist MBID | `TXXX:MusicBrainz Album Artist Id` | `MUSICBRAINZ_ALBUMARTISTID` | `----:…:MusicBrainz Album Artist Id` |
| Title / Artist / Album | `TIT2` / `TPE1` / `TALB` | `TITLE` / `ARTIST` / `ALBUM` | `©nam` / `©ART` / `©alb` |
| Album Artist | `TPE2` | `ALBUMARTIST` | `aART` |
| Artist / Album-artist sort | `TSOP` / `TSO2` | `ARTISTSORT` / `ALBUMARTISTSORT` | `soar` / `soaa` |
| Track # / total | `TRCK` (`n/total`) | `TRACKNUMBER` + `TRACKTOTAL`\|`TOTALTRACKS` | `trkn` |
| Disc # / total | `TPOS` (`n/total`) | `DISCNUMBER` + `DISCTOTAL`\|`TOTALDISCS` | `disk` |
| **Original** release date | `TDOR` | `ORIGINALDATE` / `ORIGINALYEAR` | *(none — Picard writes no original-date atom on MP4)* |
| **Reissue** (this edition) date | `TDRC` | `DATE` | `©day` |

Notes: number+total are packed in one ID3/MP4 frame but split in Vorbis (accept both total spellings). Read **both** recording MBID (`UFID`/`MUSICBRAINZ_TRACKID`) and release-track MBID (`MUSICBRAINZ_RELEASETRACKID`). Don't rely on `cpil` for grouping — use `albumartist` + album-artist MBID.

## Appendix B — MusicBrainz API quick reference

- Base: `https://musicbrainz.org/ws/2/` · JSON via `&fmt=json`.
- **User-Agent (required):** `Olivier/<version> ( autarch@urth.org )`.
- **Rate limit:** 1 req/s per IP (averaged); HTTP 503 on exceed → backoff.
- Lookups: `/ws/2/{artist|release|release-group|recording}/<mbid>?inc=…`.
- Useful `inc`: artist `aliases`; release `recordings`, `release-rels`, `release-groups`, `artist-credits` (all combine on a single `/release` lookup with `+`).
- `transl-tracklisting` relationship type-id: `fc399d47-23a7-4c28-bfcf-0607a562b644`. `release-rels` on a `/release` lookup returns this relation incl. the pseudo-release target MBID. Browse with `&limit=100&offset=…` and page when a release-group has many releases.
- Original year = release-group `first-release-date`; reissue year = release `date`.

## Appendix C — Candidate packages (verify latest at implementation)

- **Rust:** `lofty` (tags), `rusqlite` (bundled SQLite + FTS5), `reqwest` (MB client), `flutter_rust_bridge`.
- **Flutter:** `just_audio` + `just_audio_media_kit` (libmpv, Linux), `audio_service` + `audio_service_mpris`, `dio`/`http` (if any Dart-side HTTP), Material 3. Build the player queue with `AudioPlayer.setAudioSources(...)` (not the deprecated `ConcatenatingAudioSource`).
- **Reference app proving the stack:** Harmonoid (Flutter, Linux + Android, mpv + MPRIS).

Full cited research is in the workflow outputs from the brainstorming session (stack comparison, MusicBrainz data model, Picard mapping, OS integration, Dioxus assessment).
