# Phase 0 spike results (2026-06-14)

Phase 0 (Foundations & Spikes) for [the Olivier design](../specs/2026-06-13-olivier-design.md),
plan: [phase0-foundations](../plans/2026-06-14-olivier-phase0-foundations.md).

## Automated outcomes (proven by tests / CI)

- **Tag + MBID + date reading (lofty) across all six formats** — `rust/tests/tags_test.rs`
  passes for MP3, FLAC, Ogg Vorbis, Opus, AAC/M4A, ALAC: common fields, all six embedded
  MusicBrainz IDs (UFID/TXXX, Vorbis comments, MP4 freeform), and original-vs-reissue dates
  (with MP4 correctly yielding no original date).
- **FTS5 trigram CJK search** — `rust/tests/db_test.rs`: bundled SQLite ships FTS5; 3-char CJK
  via `MATCH`, 1–2-char CJK via `LIKE` fallback, and Latin substrings all match.
- **FFI bridge** — `integration_test/tags_ffi_test.dart` reads tags from a fixture through the
  Dart↔Rust bridge. Run **in CI** headless under xvfb (`flutter test integration_test/ -d linux`),
  so a bridge regression is caught — not just locally.
- **Persisted-queue round-trip (spec §3.4 core)** — `rust/tests/db_test.rs::queue_round_trips`
  saves and reloads a `QueueSnapshot` (paths + index + position + shuffle).
- **Builds + links** — `flutter build linux --debug` produces the app and the linked
  `librust_lib_olivier.so` (cargokit compiles the Rust cdylib and Flutter links it).
- **Lint/tidy** — `precious lint --all` is green (clippy, rustfmt, dart-format, flutter-analyze,
  prettier, taplo, shellcheck, shfmt, omegasort, typos). CI runs it.

## libmpv codec coverage on Linux (the spike's key question)

**Basic playback CONFIRMED working (2026-06-14).** Per-codec decode coverage still to tick off below.
The fixtures are 1 s of silence (valid per-codec audio), so the build proves linking but not decode.
To confirm libmpv decodes each codec on this machine:
`mise exec -- flutter run -d linux`, then point the **Play** button's `_playTest()` at a real
library file of each codec.

- [ ] MP3 — plays:
- [ ] FLAC — plays:
- [ ] AAC / M4A — plays:
- [ ] ALAC — plays:
- [ ] Ogg Vorbis — plays:
- [ ] Opus — plays:
- [ ] Any libmpv packaging issues (discovery, Flatpak):

## audio_service background + MPRIS

**PENDING manual check.**

- Linux MPRIS (run the app, then in another terminal):
  - [ ] `playerctl -l` lists `OlivierMusicPlayer`:
  - [ ] `playerctl play-pause` / `playerctl next` control playback (the `canControl`/`can*`
        flags are set in `main.dart`):
  - Known gap: `audio_service_mpris` 1.0.0-beta.2 has no Seek/Volume; `init()` is synchronous.
- Android (needs a device; otherwise defer to Phase 4):
  - [ ] media notification appears, controls work, audio continues when backgrounded:

## App-side shuffle

**PENDING manual check.** ("Queue 3" then toggle the Shuffle switch.)

- [ ] Queue plays in order; shuffle-on reorders; shuffle-off restores order; playback continues:

## Persisted-queue quit/relaunch hydration

**PENDING manual check.**

- [ ] "Queue 3" → quit → relaunch → UI shows `queue: 3 tracks (restored)`:

## Decisions / adjustments carried into Phase 1

- **rust-lld linker:** the earlier `rust-lld` link failure was a **snap-Flutter** artifact. With
  the non-snap (mise) toolchain the default linker links the Rust cdylib cleanly — **no `.cargo`
  linker workaround is needed**.
- **System build deps (non-snap):** Flutter Linux needs `libstdc++-14-dev` (clang selects gcc-14
  on Ubuntu 24.04), `libmpv-dev`, and a real `ninja` (provided via mise). Captured in CI.
- **Toolchain via mise:** Flutter 3.44.2, ninja, `flutter_rust_bridge_codegen` (binary), and the
  precious lint toolchain are all pinned in `mise.toml`.
- **`read_tags` double-parses** the file (Probe for common fields, format-specific reader for
  MBIDs). Accepted for Phase 0; optimize to a single parse in Phase 1.
- **Phase-0 queue persistence is by file path**; the spec's `track_id`-keyed `queue_item` and
  `shuffled_position` land in Phase 3 with the real catalog.
- **Queue position offset:** Phase 0 persists/restores queue + current index + shuffle, and the
  restore mechanism seeks to the saved offset (`restoreFromSnapshot`). The **throttled mid-track
  write-back** (a periodic / on-pause capture of `player.position`, per spec §3.4) is deferred to
  Phase 3 — for now position is only captured at structural changes, so it's typically 0.
- **`crate-type` includes `rlib`** (added so integration tests can link the crate) alongside
  `cdylib`/`staticlib`.
- **Lint/tidy is precious** (`just lint` / `just tidy`); subagents and CI use it.
