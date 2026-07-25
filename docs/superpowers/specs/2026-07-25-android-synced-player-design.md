# Olivier on Android — Read-Only Player for a Syncthing-Synced Library — Design

**Date:** 2026-07-25
**Status:** Phases 0–4 done and verified on hardware: the desktop exports a rebased snapshot,
Syncthing carries it, the phone imports it, browses it, and plays from it. Phase 5 (phone UI) is
partly done — the responsive drill-down layout landed (see the responsive-browse-layout spec) — but
playback cannot yet be started by touch. See the gap noted under phase 3.

## Goal

Run Olivier on an Android phone (Pixel 8) as a **read-only player** over a music library that
Syncthing already replicates to the device. The phone browses and plays; it never scans, never
enriches, and never writes catalog changes back to the desktop.

This is a platform port, not a feature. It is specified in phases because phase 0 (does the Rust
crate cross-compile?) gates everything after it, and a failure there changes the cost of the whole
effort. Each phase is independently committable.

## Decisions (agreed)

- **Scope:** phone is a player for an already-built catalog. No scanning, no MusicBrainz enrichment,
  no tag editing on the device.
- **Write-back:** none. Plays recorded on the phone are lost; the phone's queue and settings are
  local to the device and never sync. This keeps the synced DB strictly one-way and avoids Syncthing
  conflict files on a SQLite database.
- **DB transport:** the desktop exports a **rebased snapshot** (`olivier-sync.db`) into a Syncthing
  folder. On launch the phone notices a newer snapshot and copies it into its own app-private DB.
  Syncthing never touches a live, open SQLite file.
- **Music location on the phone:** shared storage (the existing Syncthing music folder, e.g.
  `/storage/emulated/0/Music`). Requires the `READ_MEDIA_AUDIO` runtime permission; real filesystem
  paths continue to work for both playback and embedded-cover extraction.

## Background: why paths are the central problem

Every music path in the catalog is stored **absolute**, in four places:

| Table | Column | Ref |
| --- | --- | --- |
| `file` | `path` (UNIQUE) | `rust/src/db.rs:52` |
| `queue_item` | `path` | `rust/src/db.rs:8` |
| `playlist_item` | `path` (FK → `file.path`) | `rust/src/db.rs:139` |
| `root` | `path` (PK) | `rust/src/db.rs:70` |

Nothing is stored relative to a root. The absolute string is minted by the scan walker
(`rust/src/catalog/scan.rs:68`) and flows out unchanged to `AudioSource.file(path)`
(`lib/audio/queue_controller.dart:109`, `:246`) and to MediaItem ids
(`lib/audio/playback_controller.dart:31`).

The saving grace: **root membership is already pure string-prefix matching** — `roots.rs:31-41` and
`scan.rs:160-182` both select by `substr(path,1,N) = '<root>/'`. Every stored path begins with
exactly one registered root plus `/`. So rebasing a library to a new location is a prefix rewrite,
not a re-scan.

The desktop path (`/home/autarch/Music/…`) and the phone path (`/storage/emulated/0/Music/…`) differ,
so the snapshot must be rewritten. This is the enabling primitive for the entire port.

## Phase 0 — Prove the Rust crate cross-compiles (gate) — **done, passed**

**Result: the Rust side was never the problem.** Every crate — `lofty`, `ignore`, `rusqlite`
(bundled), `reqwest`/rustls/ring, `jiff`, `tokio` — cross-compiled for `aarch64-linux-android`,
`i686-linux-android` and `x86_64-linux-android` with **no source changes**. cargokit drove it
automatically. `librust_lib_olivier.so` (19.7 MB, arm64-v8a) ships in `app-debug.apk`.

The real obstacle was the **stale `android/` scaffold**, which had never been touched since the
project was generated:

- Groovy *and* Kotlin Gradle files coexisted at every level (`android/build.gradle` +
  `build.gradle.kts`, `settings.gradle` + `.kts`, `app/build.gradle` + `.kts`). Gradle prefers the
  Groovy ones, which were the legacy template — AGP 4.1.0, Kotlin 1.3.50, compileSdk 30, Gradle 6.7 —
  while the `.kts` set was current. Fixed by deleting the Groovy trio.
- The Gradle wrapper was pinned to 6.7. Flutter 3.44.4 expects 9.1.0; we run 8.12 (see below).
- `AndroidManifest.xml` predated Android 12 and lacked `android:exported` on `MainActivity`.
- A stale `GeneratedPluginRegistrant.java` was checked into `android/app/src/main/java/`; Flutter
  regenerates it, so the checked-in copy was deleted.

**AGP is pinned to 8.9.1, not the template's 9.0.1**, because two dependencies disagree under AGP 9:
`audio_service` 0.18.18 applies `kotlin-android` unconditionally, which AGP 9 rejects unless
`android.builtInKotlin=false`; `file_picker` 11.0.2 detects AGP 9 and *skips* applying KGP, expecting
built-in Kotlin to compile it, which needs `builtInKotlin=true`. There is no setting satisfying both.
On AGP 8 each plugin applies its own KGP and both work. Revisit when `audio_service` migrates.

**Verified on a Pixel 8a**, not just built: the app launches, `RustLib.init()` succeeds
(`rusqlite_migration` reports the catalog at schema version 9), a media session registers, and the
full desktop UI paints. Two bugs had to be fixed to get there, both of which also affect the desktop
or would have blocked any Android work:

- `ResizableSplit` called `clamp(minFirst, avail)`, and `double.clamp` throws when its lower limit
  exceeds the upper. Any viewport narrower than `minFirst` — a phone, or a sufficiently narrow
  desktop window — threw during layout and left the app on a blank frame.
- `MainActivity` extended `FlutterActivity`. audio_service resolves the running `FlutterEngine`
  through the manifest's activity and requires `AudioServiceActivity`; without it the plugin threw on
  the platform side, `AudioService.init()` never returned, and `main()` blocked before `runApp()`.
  This one is invisible from Dart — no exception, no error, just zero frames rendered forever.

Still unverified: playback itself, and background/lock-screen behaviour.

Original plan follows.

Nothing else is worth doing until an `aarch64-linux-android` build of `rust_lib_olivier` links.

Assets in our favour:

- `rust_builder/android/` already exists with cargokit Gradle wiring from the flutter_rust_bridge
  template — the `.so` build is automated once an NDK is present.
- `rustls 0.22` resolves to **ring 0.17**, not `aws-lc-rs` (confirmed in `rust/Cargo.lock`). ring has
  solid Android support; aws-lc-rs would have been a materially harder fight.
- `rusqlite` is `bundled`, so SQLite's C is compiled by the `cc` crate through NDK clang — routine.

Work: install the Android SDK + NDK, add the `aarch64-linux-android` Rust target, and get
`flutter build apk --debug` to produce a loadable library. Every dependency compiles for Android or
the phase fails: `lofty`, `ignore`, `reqwest`/rustls/ring, `rusqlite` bundled, `jiff`, `tokio`.

**Exit criterion:** the app launches on the device and `RustLib.init()` returns. The UI will be
unusable and the catalog empty; that is expected and fine. *(Partially met: the APK builds and
contains the library. Launching on hardware is still untested.)*

## Phase 1 — `rebase_root` in Rust — **done** (Rust layer only)

The FFI/Dart entry point is deliberately deferred to phase 2, which is its first caller; exposing it
now would mean committing regenerated bridge code with no consumer.

A new operation that rewrites one root prefix to another across all four tables in a single
transaction. Independently useful on the desktop: moving a library folder currently orphans the
entire catalog.

Shape (in `rust/src/catalog/roots.rs`, exposed via `rust/src/api/catalog.rs`):

```rust
pub fn rebase_root(conn: &Connection, old_root: &str, new_root: &str) -> anyhow::Result<usize>
```

- Trim trailing slashes on both arguments, matching `add_root`'s normalization (`roots.rs:5-8`).
- Error if `old_root` is not a registered root; if `new_root` is not a non-empty absolute path (`""`
  and `"/"` both trim to the empty string, whose `"{root}/"` prefix would match the entire catalog);
  or if `new_root` collides with or *nests inside* another registered root — a merge would violate
  `file.path`'s UNIQUE constraint, and overlapping roots confuse `remove_root`'s pruning rule.
- Callers must be at autocommit level: the function issues a bare `BEGIN`, so phase 2 cannot wrap its
  per-root calls in one outer transaction. Sequence them instead, or refactor to take a `&Transaction`.
- In one transaction, for `file`, `queue_item`, and `playlist_item`:
  `UPDATE … SET path = :new || substr(path, length(:old) + 1) WHERE substr(path, 1, N) = :old || '/'`
  then update the `root` row itself.
- `playlist_item.path` is `REFERENCES file(path) ON DELETE CASCADE`. **Resolved during
  implementation:** foreign keys *are* enforced — rusqlite enables them by default, independently of
  anything `db::open` sets. There is no `ON UPDATE` clause, so it defaults to NO ACTION and *both*
  update orders violate the constraint mid-transaction (rewrite `file` first and referencing rows
  dangle; rewrite `playlist_item` first and it points at rows that don't exist yet). The fix is
  `PRAGMA defer_foreign_keys` inside the transaction, which SQLite resets at commit or rollback.
- Return the number of `file` rows rewritten.

Tests (`rust/tests/rebase_root_test.rs`): rewrites files, queue items and playlist items together;
leaves paths under a *different* root untouched; rejects an unregistered old root; rejects a
colliding new root; handles a non-ASCII path (the `substr` char-vs-byte concern already noted at
`scan.rs:160-163`).

## Phase 2 — Snapshot export on the desktop

A desktop-only action (Settings) that writes a phone-ready copy of the catalog into a chosen folder.

1. `VACUUM INTO` the live DB to a temp file — a consistent copy without stopping playback.
2. Open the copy and run `rebase_root(old, new)` for each root, mapping the desktop prefix to the
   phone prefix.
3. Clear device-local state from the copy: `queue_item` and any playback-position settings. The
   phone's queue is its own.
4. Atomically rename into place as `olivier-sync.db` in the target folder, alongside a small
   `olivier-sync.json` carrying a schema version and an export timestamp.

New settings, stored via the existing `settings` table (`rust/src/api/settings.rs`): the export
folder, and the phone-side root prefix to rewrite to.

The MBID-keyed cover cache (`olivier-caa-{mbid}.jpg`, `rust/src/cover.rs:34-38`) is **path-independent**
and should be synced too — copy it into the same folder so the phone starts warm instead of
re-fetching every cover over mobile data.

## Phase 3 — Snapshot import on the phone — **done, verified end to end**

Verified on a Pixel 8a with the real 10,830-track library: exported into `~/mnt/music`, carried over
by Syncthing (66 MB), imported on launch, browsed, and played. `state=PLAYING`, position advancing,
`error=null`.

**The permission analysis in phase 4 below was wrong.** `READ_MEDIA_AUDIO` grants access to *audio
files only* — it cannot read the snapshot, which is a `.db`. This needs `MANAGE_EXTERNAL_STORAGE`
(all-files access), which covers both. Acceptable here because the app is sideloaded and never goes
near the Play Store, where that permission is restricted.

Two things worked better than expected:

- **Cover art renders on the device** even though the `covers/` folder had not finished syncing —
  lofty extracts embedded art from the audio files directly, which also proves the app has genuine
  path-based read access to the music.
- **audio_service works**: a media session registers, audio focus is granted, and an `AudioTrack`
  opens with `USAGE_MEDIA`.

**Gap found, not yet fixed: nothing can be played by touch.** Track and album rows expose their
actions through a right-click context menu (`RowContextMenu`), and long-press is already consumed by
`LongPressDraggable` for drag-to-queue. On a phone there is no right-click, so the only way to start
playback is the queue screen's shuffle-entire-library button. A tap-to-play affordance — or a
long-press menu that doesn't collide with the drag — is the first thing phase 5 needs.

## Phase 3 (original plan) — Snapshot import on the phone

On launch, before `RustLib` opens the catalog:

- Look for `olivier-sync.db` in the configured Syncthing folder. If its mtime is newer than the last
  import recorded in local settings, copy it over the app-private DB
  (`getApplicationSupportDirectory()`, already the Android branch of `_resolveDbPath` at
  `lib/main.dart:143`) and record the new import time.
- Copy the cover cache alongside it.
- Never open the synced file directly.

**Open question:** `getApplicationSupportDirectory()` returns *internal* app storage, while the music
lives in shared storage. That is fine — they are independent — but it means the phone-side root
prefix in phase 2 must be the *music* location, not the DB location. Worth stating explicitly in the
export UI so the two aren't confused.

Import must be robust to a half-synced file: Syncthing writes to a temp name and renames, so a
torn read is unlikely, but the import should still validate the copy opens as SQLite and carries the
expected schema version before swapping it in.

## Phase 4 — Platform gating — partly done

Done: the `MANAGE_EXTERNAL_STORAGE` permission (not `READ_MEDIA_AUDIO` — see phase 3), the
`permission_handler` dependency, and a Settings section on Android for the import.

Still to do: scanning, enrichment and tag editing are not yet hidden on Android. They are reachable
and will fail or misbehave against a synced catalog.

## Phase 4 (original plan) — Platform gating

Scanning, enrichment and tag editing must be **absent** on Android, not merely failing at runtime.
Call sites to gate: `lib/state/scan_controller.dart`, `lib/state/enrich_controller.dart`,
`lib/settings/settings_page.dart` (roots management, scan and enrich controls),
`lib/widgets/title_override_dialog.dart`, and the scan-progress bar in `lib/catalog/browser_page.dart`.

Prefer a single `platformCapabilitiesProvider` over scattered `Platform.isAndroid` checks, so the
capability set is testable and the desktop behaviour is provably unchanged.

Also required: `READ_MEDIA_AUDIO` in `android/app/src/main/AndroidManifest.xml` (plus
`READ_EXTERNAL_STORAGE` for API ≤ 32), a runtime permission request, and therefore a new dependency —
`permission_handler` — which does not exist in `pubspec.yaml` today. A denied permission needs a real
empty state, not a crash.

Release signing is still the debug key (`android/app/build.gradle.kts:31`). Adequate for sideloading
over USB; must change before the APK goes anywhere else.

## Phase 5 — Phone UI

The largest open design question, and deliberately the last phase. The current shell assumes a
desktop: the `ResizableSplit` artist | (album / track) cascade (`lib/catalog/browser_page.dart:143`),
the expandable queue panel, and keyboard-driven search and shortcuts.

A phone shell needs drill-down navigation (artists → albums → tracks) over the *same* Riverpod
providers, a full-screen now-playing view, and a queue screen. The `state/` layer should need no
changes — the recent extraction of queue view state into `lib/state/queue_view.dart` is the right
precedent for keeping view state independent of any particular widget tree.

This phase is not specified further here; it deserves its own spec once phases 0–4 land.

## Risks and unknowns

- **Phase 0 is genuinely unproven.** No cross-compile has been attempted. The dependency review is
  encouraging but is not a build.
- **Foreign-key behaviour during rebase** (phase 1) could cascade-delete playlist entries if the
  update order is wrong. Must be verified against the actual schema pragmas before implementing.
- **Android background playback** is a different world from MPRIS. `audio_service` is already a
  dependency and the manifest already declares the service, receiver and foreground-service
  permissions — but this path has never been exercised and the notification/lock-screen behaviour is
  untested.
- **`just_audio` backend divergence:** `JustAudioMediaKit.ensureInitialized` sets `android: false`
  (`lib/main.dart:49`), so Android uses just_audio's native ExoPlayer backend rather than media_kit.
  Playback semantics the desktop relies on — notably the mpv error-stream behaviour used for skipping
  bad tracks — do not carry over and will need separate handling.
- **Library size.** A full collection on a phone is a storage question Syncthing already answers;
  no work here, but selective sync is the user's lever, not the app's.

## Out of scope

Write-back of plays or ratings; scanning or enriching on the device; iOS; a control protocol between
phone and desktop; Play Store distribution; selective/partial library sync managed by Olivier.
