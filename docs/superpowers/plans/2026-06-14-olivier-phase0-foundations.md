# Olivier Phase 0 — Foundations & Spikes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Olivier project skeleton (Flutter UI + Rust core via `flutter_rust_bridge`) and de-risk the four hardest unknowns — cross-format tag/MBID reading, SQLite FTS5 trigram (CJK) search, libmpv playback on Linux, and `audio_service` background playback with the persisted-queue round-trip — leaving a tested foundation Phase 1 builds on.

**Architecture:** One Flutter app at the repo root with a Rust crate at `rust/` (crate name `rust_lib_olivier`, created by `integrate` — the project's core; the spec refers to this conceptually as `olivier_core`) wired via `flutter_rust_bridge` v2 (cargokit auto-builds the `.so`/jniLibs). Rust owns scanning/tags/catalog logic and exposes typed DTOs + streams to Dart; Dart owns UI and the audio engine (`just_audio` → libmpv on Linux / ExoPlayer on Android) with `audio_service` for OS media controls. This plan implements only the foundations and spikes; Phases 1–4 (full catalog/browse/play, enrichment, search/playlists/queue, Android) are separate plans.

**Tech Stack:** Flutter (Dart) · Rust 1.85+ · `flutter_rust_bridge` 2.12.0 · `lofty` 0.24 · `rusqlite` 0.40 (bundled SQLite 3.53, FTS5) · `rusqlite_migration` 2.5 · `just_audio` 0.10 + `just_audio_media_kit` 2.1 (libmpv) · `audio_service` 0.18 + `audio_service_mpris` 1.0.0-beta.2.

**Spec:** [docs/superpowers/specs/2026-06-13-olivier-design.md](../specs/2026-06-13-olivier-design.md) — this plan implements §9 "Phase 0".

---

## Prerequisites (developer machine)

Before Task 1, confirm these are installed (do **not** automate; just verify and report versions):

- Flutter SDK (stable 3.x): `flutter --version`
- Rust ≥ 1.85 (lofty 0.24 MSRV): `rustc --version`
- Flutter Linux desktop deps: `clang cmake ninja-build pkg-config libgtk-3-dev`
- libmpv (Linux audio backend): `sudo apt-get install -y libmpv-dev mpv` (Fedora: `mpv-libs mpv-libs-devel`; Arch: `mpv`)
- `ffmpeg` and Python `mutagen` (for test fixtures only): `ffmpeg -version`; `python3 -c "import mutagen, sys; print(mutagen.version_string)"` (install with `pip install --user mutagen`)
- The frb codegen CLI, pinned to match the Dart/Rust package versions:
  ```bash
  cargo install flutter_rust_bridge_codegen --version 2.12.0
  ```
- Android NDK r27+ is **only** needed in Phase 4; not required for Phase 0.

If any are missing, stop and report — don't guess substitutes.

---

## File structure (created across this plan)

```
olivier/                                   # repo root == Flutter app "olivier" (already has .git, docs/)
  pubspec.yaml                             # Flutter deps (Task 1, 7, 9, 11)
  flutter_rust_bridge.yaml                 # codegen config (Task 1)
  lib/
    main.dart                              # app entry: RustLib.init + audio init (Task 1, 9, 11)
    audio/
      audio_handler.dart                   # BaseAudioHandler wiring just_audio (Task 11)
      queue_controller.dart               # app-side queue + shuffle + persistence round-trip (Task 10, 12)
    src/rust/                              # GENERATED Dart bindings — never hand-edit (Task 1+)
  rust/                                     # Rust core crate (rust_lib_olivier)
    Cargo.toml                             # deps (Task 1, 4, 8)
    src/
      lib.rs                               # `mod api; mod tags; mod db; mod frb_generated;`
      frb_generated.rs                     # GENERATED — never hand-edit
      tags.rs                              # tag/MBID reading logic (Task 4–6)
      db.rs                                # catalog open + migrations + FTS5 search (Task 8)
      api/
        mod.rs                             # `pub mod tags; pub mod queue;`
        tags.rs                            # FFI surface for read_tags (Task 7)
        queue.rs                           # FFI surface for queue persistence (Task 12)
    tests/
      tags_test.rs                         # tag-reading integration tests (Task 4–6)
      db_test.rs                           # FTS5 trigram tests (Task 8)
      fixtures/                            # committed test audio (Task 3)
  rust_builder/                            # cargokit glue (generated, Task 1) — don't edit
  android/app/src/main/AndroidManifest.xml # audio_service service + perms (Task 11)
  scripts/
    make-fixtures.sh                       # ffmpeg + mutagen fixture generator (Task 3)
    make_fixtures.py                       # mutagen tagging (Task 3)
  .github/workflows/ci.yml                 # CI (Task 2)
  docs/superpowers/spikes/phase0-results.md# recorded spike outcomes (Task 13)
```

---

## Task 1: Scaffold the Flutter app + Rust core

**Files:**
- Create (via tooling): `pubspec.yaml`, `lib/main.dart`, `rust/`, `rust_builder/`, `flutter_rust_bridge.yaml`, `lib/src/rust/**`
- Modify: `rust/src/api/simple.rs` (rename/adjust to a smoke function), `lib/main.dart`

- [ ] **Step 1: Scaffold Flutter into the existing repo**

The repo root already contains `.git` and `docs/`. Create the Flutter app in place:

```bash
cd /home/autarch/projects/olivier
flutter create --org org.urth --project-name olivier --platforms=linux,android .
```

Expected: Flutter files created (`lib/main.dart`, `pubspec.yaml`, `android/`, `linux/`); existing `docs/` and `.git` untouched.

- [ ] **Step 2: Integrate flutter_rust_bridge**

```bash
cd /home/autarch/projects/olivier
flutter_rust_bridge_codegen integrate
```

Expected: creates `rust/` (crate `rust_lib_olivier`), `rust_builder/`, `flutter_rust_bridge.yaml`, `lib/src/rust/`, and adds `flutter_rust_bridge` + `rust_lib_olivier` to `pubspec.yaml`. Answer "yes" if it offers to modify `main.dart`.

- [ ] **Step 3: Pin the Rust bridge crate version**

Edit `rust/Cargo.toml` so the bridge dep is exact and add `anyhow` for error propagation:

```toml
[dependencies]
flutter_rust_bridge = "=2.12.0"
anyhow = "1"
```

Confirm `[lib] crate-type = ["cdylib", "staticlib"]` is present (the integrate step adds it).

- [ ] **Step 4: Add a smoke function in Rust**

Replace the body of `rust/src/api/simple.rs` with:

```rust
#[flutter_rust_bridge::frb(sync)]
pub fn olivier_version() -> String {
    format!("{} {}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"))
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
```

- [ ] **Step 5: Regenerate bindings**

```bash
cd /home/autarch/projects/olivier
flutter_rust_bridge_codegen generate
```

Expected: `lib/src/rust/api/simple.dart` now exposes `olivierVersion()`; no errors.

- [ ] **Step 6: Call it from Dart**

Set `lib/main.dart` to a minimal app that initializes Rust and shows the version:

```dart
import 'package:flutter/material.dart';
import 'package:olivier/src/rust/api/simple.dart';
import 'package:olivier/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const OlivierApp());
}

class OlivierApp extends StatelessWidget {
  const OlivierApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Olivier',
      home: Scaffold(
        appBar: AppBar(title: const Text('Olivier')),
        body: Center(child: Text(olivierVersion())),
      ),
    );
  }
}
```

- [ ] **Step 7: Run on Linux and verify the bridge works**

```bash
flutter pub get
flutter run -d linux
```

Expected: window opens showing `rust_lib_olivier 0.1.0` (the crate name `integrate` created; cargokit compiled `rust/` and bundled the `.so`). Close the app.

- [ ] **Step 8: Commit**

```bash
cd /home/autarch/projects/olivier
printf '/build/\n.dart_tool/\nrust/target/\n*.iml\n.gradle/\n' >> .gitignore
git add .
git commit -m "chore: scaffold Flutter app + Rust core via flutter_rust_bridge"
```

---

## Task 2: Continuous integration

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the CI workflow**

```yaml
name: CI
on:
  push:
  pull_request:

jobs:
  rust:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: rust
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy, rustfmt
      - run: cargo fmt --all -- --check
      - run: cargo clippy --all-targets -- -D warnings
      - run: cargo test --all

  flutter:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - name: Linux build deps
        run: sudo apt-get update && sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test
      - run: flutter build linux --debug
```

- [ ] **Step 2: Verify Rust jobs pass locally**

```bash
cd /home/autarch/projects/olivier/rust
cargo fmt --all -- --check && cargo clippy --all-targets -- -D warnings && cargo test --all
```

Expected: all succeed (only the smoke fn exists so far).

- [ ] **Step 3: Verify Flutter checks pass locally**

```bash
cd /home/autarch/projects/olivier
flutter analyze && flutter test
```

Expected: analyze clean; the default widget test passes (or remove `test/widget_test.dart` if `flutter create` left a stale one that references the old counter app — replace it with a trivial passing test).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml test/
git commit -m "ci: add Rust + Flutter CI workflow"
```

---

## Task 3: Test fixtures (six tagged audio files)

**Files:**
- Create: `scripts/make-fixtures.sh`, `scripts/make_fixtures.py`, `rust/tests/fixtures/*.{mp3,flac,m4a,alac.m4a,ogg,opus}`

These fixtures carry Picard-equivalent tags (mutagen is the same library Picard uses), with synthetic-but-well-formed MBIDs so tests can assert exact values.

- [ ] **Step 1: Write the audio generator script**

`scripts/make-fixtures.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=rust/tests/fixtures
mkdir -p "$OUT"

# 1s of silence as the base audio for each container/codec.
ff() { ffmpeg -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 1 "$@"; }

ff -codec:a libmp3lame      "$OUT/sample.mp3"
ff -codec:a flac            "$OUT/sample.flac"
ff -codec:a aac             "$OUT/sample.m4a"
ff -codec:a alac            "$OUT/sample.alac.m4a"
ff -codec:a libvorbis       "$OUT/sample.ogg"
ff -codec:a libopus         "$OUT/sample.opus"

python3 scripts/make_fixtures.py
echo "fixtures written to $OUT"
```

- [ ] **Step 2: Write the tagging script**

`scripts/make_fixtures.py` (writes Picard-style tags incl. UFID, TXXX, Vorbis, MP4 freeform):

```python
#!/usr/bin/env python3
"""Stamp Picard-equivalent MusicBrainz tags onto the fixture audio files."""
from pathlib import Path
from mutagen.id3 import ID3, TIT2, TPE1, TALB, TPE2, TRCK, TPOS, TDOR, TDRC, TXXX, UFID
from mutagen.flac import FLAC
from mutagen.oggvorbis import OggVorbis
from mutagen.oggopus import OggOpus
from mutagen.mp4 import MP4

F = Path("rust/tests/fixtures")

REC  = "aaaaaaaa-0000-0000-0000-000000000001"  # recording MBID
ALB  = "bbbbbbbb-0000-0000-0000-000000000001"  # release/album MBID
RG   = "cccccccc-0000-0000-0000-000000000001"  # release-group MBID
ART  = "dddddddd-0000-0000-0000-000000000001"  # artist MBID
AART = "dddddddd-0000-0000-0000-000000000001"  # album-artist MBID
RTRK = "eeeeeeee-0000-0000-0000-000000000001"  # release-track MBID

TITLE, ARTIST, ALBUM = "正しい街", "椎名林檎", "無罪モラトリアム"
ORIG, REISSUE = "1999-02-24", "2008-11-28"

def tag_id3(path):
    t = ID3()
    t.add(TIT2(encoding=3, text=TITLE)); t.add(TPE1(encoding=3, text=ARTIST))
    t.add(TALB(encoding=3, text=ALBUM));  t.add(TPE2(encoding=3, text=ARTIST))
    t.add(TRCK(encoding=3, text="1/10")); t.add(TPOS(encoding=3, text="1/1"))
    t.add(TDOR(encoding=3, text=ORIG));   t.add(TDRC(encoding=3, text=REISSUE))
    t.add(UFID(owner="http://musicbrainz.org", data=REC.encode()))
    for desc, val in [("MusicBrainz Album Id", ALB),
                      ("MusicBrainz Release Group Id", RG),
                      ("MusicBrainz Artist Id", ART),
                      ("MusicBrainz Album Artist Id", AART),
                      ("MusicBrainz Release Track Id", RTRK)]:
        t.add(TXXX(encoding=3, desc=desc, text=val))
    t.save(path)

def tag_vorbis(obj):
    obj["TITLE"]=TITLE; obj["ARTIST"]=ARTIST; obj["ALBUM"]=ALBUM; obj["ALBUMARTIST"]=ARTIST
    obj["TRACKNUMBER"]="1"; obj["TRACKTOTAL"]="10"; obj["DISCNUMBER"]="1"; obj["DISCTOTAL"]="1"
    obj["ORIGINALDATE"]=ORIG; obj["DATE"]=REISSUE
    obj["MUSICBRAINZ_TRACKID"]=REC; obj["MUSICBRAINZ_ALBUMID"]=ALB
    obj["MUSICBRAINZ_RELEASEGROUPID"]=RG; obj["MUSICBRAINZ_ARTISTID"]=ART
    obj["MUSICBRAINZ_ALBUMARTISTID"]=AART; obj["MUSICBRAINZ_RELEASETRACKID"]=RTRK
    obj.save()

def tag_mp4(path):
    m = MP4(path)
    m["\xa9nam"]=[TITLE]; m["\xa9ART"]=[ARTIST]; m["\xa9alb"]=[ALBUM]; m["aART"]=[ARTIST]
    m["trkn"]=[(1,10)]; m["disk"]=[(1,1)]; m["\xa9day"]=[REISSUE]
    def ff(name, val): m[f"----:com.apple.iTunes:{name}"]=[val.encode()]
    ff("MusicBrainz Track Id", REC); ff("MusicBrainz Album Id", ALB)
    ff("MusicBrainz Release Group Id", RG); ff("MusicBrainz Artist Id", ART)
    ff("MusicBrainz Album Artist Id", AART); ff("MusicBrainz Release Track Id", RTRK)
    # NB: Picard writes NO original-date atom for MP4/ALAC, so we don't either —
    # original year for these formats comes from MusicBrainz enrichment (Phase 2).
    m.save()

tag_id3(F/"sample.mp3")
tag_vorbis(FLAC(F/"sample.flac"))
tag_vorbis(OggVorbis(F/"sample.ogg"))
tag_vorbis(OggOpus(F/"sample.opus"))
tag_mp4(F/"sample.m4a")
tag_mp4(F/"sample.alac.m4a")
print("tagged 6 fixtures")
```

- [ ] **Step 3: Generate the fixtures**

```bash
chmod +x scripts/make-fixtures.sh
./scripts/make-fixtures.sh
ls -la rust/tests/fixtures
```

Expected: six small files present.

- [ ] **Step 4: Commit**

```bash
git add scripts/make-fixtures.sh scripts/make_fixtures.py rust/tests/fixtures
git commit -m "test: add six tagged audio fixtures + generator scripts"
```

---

## Task 4: Rust — `TrackTags` + common-field reading (TDD)

**Files:**
- Create: `rust/src/tags.rs`, `rust/tests/tags_test.rs`
- Modify: `rust/src/lib.rs` (add `pub mod tags;`), `rust/Cargo.toml`

- [ ] **Step 1: Add lofty dependency**

In `rust/Cargo.toml` `[dependencies]`:

```toml
lofty = "0.24"
```

- [ ] **Step 2: Declare the module and DTO**

Add `pub mod tags;` to `rust/src/lib.rs`. Create `rust/src/tags.rs` with the struct and an empty function so tests compile:

```rust
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TrackTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_no: Option<u32>,
    pub track_total: Option<u32>,
    pub disc_no: Option<u32>,
    pub disc_total: Option<u32>,
    pub length_ms: u64,
    pub recording_mbid: Option<String>,
    pub release_mbid: Option<String>,
    pub release_group_mbid: Option<String>,
    pub artist_mbid: Option<String>,
    pub album_artist_mbid: Option<String>,
    pub release_track_mbid: Option<String>,
    pub original_date: Option<String>,
    pub reissue_date: Option<String>,
    pub has_cover: bool,
}

pub fn read_tags(_path: &Path) -> anyhow::Result<TrackTags> {
    anyhow::bail!("not implemented")
}
```

- [ ] **Step 3: Write the failing test (common fields, all six formats)**

`rust/tests/tags_test.rs`:

```rust
use rust_lib_olivier::tags::read_tags;
use std::path::Path;

const FILES: &[&str] = &[
    "sample.mp3", "sample.flac", "sample.ogg",
    "sample.opus", "sample.m4a", "sample.alac.m4a",
];

fn fixture(name: &str) -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
}

#[test]
fn reads_common_fields_for_all_formats() {
    for name in FILES {
        let t = read_tags(&fixture(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(t.title.as_deref(), Some("正しい街"), "{name} title");
        assert_eq!(t.artist.as_deref(), Some("椎名林檎"), "{name} artist");
        assert_eq!(t.album.as_deref(), Some("無罪モラトリアム"), "{name} album");
        assert_eq!(t.album_artist.as_deref(), Some("椎名林檎"), "{name} album_artist");
        assert_eq!(t.track_no, Some(1), "{name} track_no");
        assert_eq!(t.disc_no, Some(1), "{name} disc_no");
        assert!(t.length_ms >= 900 && t.length_ms <= 1200, "{name} length {}", t.length_ms);
    }
}
```

> Note on crate name: tests import `rust_lib_olivier::...` (the crate name `integrate` created). If your crate is named differently, check `rust/Cargo.toml` `[package] name` and adjust the `use` path in every test.

- [ ] **Step 4: Run the test, verify it fails**

```bash
cd rust && cargo test --test tags_test reads_common_fields_for_all_formats
```

Expected: FAIL ("not implemented").

- [ ] **Step 5: Implement `read_tags` common fields**

Replace `read_tags` in `rust/src/tags.rs`:

```rust
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::{Accessor, ItemKey};
use lofty::probe::Probe;

pub fn read_tags(path: &Path) -> anyhow::Result<TrackTags> {
    let tagged = Probe::open(path)?.read()?;
    let length_ms = tagged.properties().duration().as_millis() as u64;

    let mut out = TrackTags { length_ms, ..Default::default() };
    if let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) {
        out.title = tag.title().map(|c| c.to_string());
        out.artist = tag.artist().map(|c| c.to_string());
        out.album = tag.album().map(|c| c.to_string());
        out.album_artist = tag.get_string(ItemKey::AlbumArtist).map(|s| s.to_string());
        out.track_no = tag.track();
        out.track_total = tag.track_total();
        out.disc_no = tag.disk();
        out.disc_total = tag.disk_total();
        out.has_cover = !tag.pictures().is_empty();
    }
    Ok(out)
}
```

- [ ] **Step 6: Run the test, verify it passes**

```bash
cd rust && cargo test --test tags_test reads_common_fields_for_all_formats
```

Expected: PASS. If `album_artist` is `None` for some format, the generic `ItemKey::AlbumArtist` mapping is the cause — check the fixture wrote the right atom/field; do **not** weaken the assertion.

- [ ] **Step 7: Commit**

```bash
git add rust/Cargo.toml rust/src/lib.rs rust/src/tags.rs rust/tests/tags_test.rs
git commit -m "feat(core): read common audio tag fields across six formats"
```

---

## Task 5: Rust — MusicBrainz ID extraction across formats (TDD)

**Files:**
- Modify: `rust/src/tags.rs`, `rust/tests/tags_test.rs`

- [ ] **Step 1: Write the failing test**

Append to `rust/tests/tags_test.rs`:

```rust
#[test]
fn reads_musicbrainz_ids_for_all_formats() {
    for name in FILES {
        let t = read_tags(&fixture(name)).unwrap();
        assert_eq!(t.recording_mbid.as_deref(),
                   Some("aaaaaaaa-0000-0000-0000-000000000001"), "{name} recording");
        assert_eq!(t.release_mbid.as_deref(),
                   Some("bbbbbbbb-0000-0000-0000-000000000001"), "{name} release");
        assert_eq!(t.release_group_mbid.as_deref(),
                   Some("cccccccc-0000-0000-0000-000000000001"), "{name} rg");
        assert_eq!(t.album_artist_mbid.as_deref(),
                   Some("dddddddd-0000-0000-0000-000000000001"), "{name} albumartist");
        assert_eq!(t.release_track_mbid.as_deref(),
                   Some("eeeeeeee-0000-0000-0000-000000000001"), "{name} releasetrack");
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

```bash
cd rust && cargo test --test tags_test reads_musicbrainz_ids_for_all_formats
```

Expected: FAIL (all MBIDs `None`).

- [ ] **Step 3: Implement per-format ID extraction**

Add to `rust/src/tags.rs` — a `read_ids` helper dispatched by file type, and call it from `read_tags`:

```rust
use lofty::file::FileType;

#[derive(Default)]
struct Ids {
    recording_mbid: Option<String>,
    release_mbid: Option<String>,
    release_group_mbid: Option<String>,
    artist_mbid: Option<String>,
    album_artist_mbid: Option<String>,
    release_track_mbid: Option<String>,
}

fn read_ids(path: &Path, ft: FileType) -> anyhow::Result<Ids> {
    use lofty::config::ParseOptions;
    let mut f = std::fs::File::open(path)?;
    let mut ids = Ids::default();

    match ft {
        FileType::Mpeg => {
            use lofty::id3::v2::Frame;
            use lofty::mpeg::MpegFile;
            let file = MpegFile::read_from(&mut f, ParseOptions::new())?;
            if let Some(tag) = file.id3v2() {
                ids.release_mbid = tag.get_user_text("MusicBrainz Album Id").map(str::to_owned);
                ids.release_group_mbid =
                    tag.get_user_text("MusicBrainz Release Group Id").map(str::to_owned);
                ids.artist_mbid = tag.get_user_text("MusicBrainz Artist Id").map(str::to_owned);
                ids.album_artist_mbid =
                    tag.get_user_text("MusicBrainz Album Artist Id").map(str::to_owned);
                ids.release_track_mbid =
                    tag.get_user_text("MusicBrainz Release Track Id").map(str::to_owned);
                ids.recording_mbid = tag.into_iter().find_map(|frame| match frame {
                    Frame::UniqueFileIdentifier(u) if u.owner == "http://musicbrainz.org" =>
                        Some(String::from_utf8_lossy(&u.identifier).into_owned()),
                    _ => None,
                });
            }
        }
        FileType::Flac | FileType::Vorbis | FileType::Opus => {
            use lofty::ogg::VorbisComments;
            // Read the six MBID keys out of a VorbisComments into `ids`.
            fn from_vc(vc: &VorbisComments, ids: &mut Ids) {
                let g = |k: &str| vc.get(k).map(str::to_owned);
                ids.recording_mbid = g("MUSICBRAINZ_TRACKID");
                ids.release_mbid = g("MUSICBRAINZ_ALBUMID");
                ids.release_group_mbid = g("MUSICBRAINZ_RELEASEGROUPID");
                ids.artist_mbid = g("MUSICBRAINZ_ARTISTID");
                ids.album_artist_mbid = g("MUSICBRAINZ_ALBUMARTISTID");
                ids.release_track_mbid = g("MUSICBRAINZ_RELEASETRACKID");
            }
            match ft {
                FileType::Flac => {
                    let file = lofty::flac::FlacFile::read_from(&mut f, ParseOptions::new())?;
                    if let Some(vc) = file.vorbis_comments() { from_vc(vc, &mut ids); }
                }
                FileType::Vorbis => {
                    let file = lofty::ogg::VorbisFile::read_from(&mut f, ParseOptions::new())?;
                    from_vc(file.vorbis_comments(), &mut ids);
                }
                FileType::Opus => {
                    let file = lofty::ogg::OpusFile::read_from(&mut f, ParseOptions::new())?;
                    from_vc(file.vorbis_comments(), &mut ids);
                }
                _ => unreachable!(),
            }
        }
        FileType::Mp4 => {
            use lofty::mp4::{AtomData, AtomIdent, Mp4File};
            use std::borrow::Cow;
            let file = Mp4File::read_from(&mut f, ParseOptions::new())?;
            if let Some(ilst) = file.ilst() {
                let ff = |name: &str| -> Option<String> {
                    let ident = AtomIdent::Freeform {
                        mean: Cow::Borrowed("com.apple.iTunes"),
                        name: Cow::Borrowed(name),
                    };
                    ilst.get(&ident)
                        .and_then(|a| a.data().next())
                        .and_then(|d| match d { AtomData::UTF8(s) => Some(s.clone()), _ => None })
                };
                ids.recording_mbid = ff("MusicBrainz Track Id");
                ids.release_mbid = ff("MusicBrainz Album Id");
                ids.release_group_mbid = ff("MusicBrainz Release Group Id");
                ids.artist_mbid = ff("MusicBrainz Artist Id");
                ids.album_artist_mbid = ff("MusicBrainz Album Artist Id");
                ids.release_track_mbid = ff("MusicBrainz Release Track Id");
            }
        }
        _ => {}
    }
    Ok(ids)
}
```

Then in `read_tags`, after computing `length_ms`, capture the file type and merge:

```rust
    let ft = tagged.file_type();
    // ... existing common-field block ...
    let ids = read_ids(path, ft)?;
    out.recording_mbid = ids.recording_mbid;
    out.release_mbid = ids.release_mbid;
    out.release_group_mbid = ids.release_group_mbid;
    out.artist_mbid = ids.artist_mbid;
    out.album_artist_mbid = ids.album_artist_mbid;
    out.release_track_mbid = ids.release_track_mbid;
```

> Verified for lofty 0.24: the OGG Vorbis type is `lofty::ogg::VorbisFile` (there is no `OggVorbisFile`). `VorbisFile`/`OpusFile::vorbis_comments()` return `&VorbisComments`, while `FlacFile::vorbis_comments()` returns `Option<&VorbisComments>` — hence the `if let Some(vc)` guard appears only on the FLAC arm.

- [ ] **Step 4: Run it, verify it passes**

```bash
cd rust && cargo test --test tags_test reads_musicbrainz_ids_for_all_formats
```

Expected: PASS for all six formats.

- [ ] **Step 5: Commit**

```bash
git add rust/src/tags.rs rust/tests/tags_test.rs
git commit -m "feat(core): extract embedded MusicBrainz IDs (ID3 UFID/TXXX, Vorbis, MP4 freeform)"
```

---

## Task 6: Rust — original vs reissue date (TDD)

**Files:**
- Modify: `rust/src/tags.rs`, `rust/tests/tags_test.rs`

- [ ] **Step 1: Write the failing test**

Append to `rust/tests/tags_test.rs`:

```rust
const MP4_FILES: &[&str] = &["sample.m4a", "sample.alac.m4a"];

#[test]
fn reads_original_and_reissue_dates() {
    for name in FILES {
        let t = read_tags(&fixture(name)).unwrap();
        // Reissue date (TDRC / DATE / ©day) is present in all six formats.
        assert!(t.reissue_date.as_deref().unwrap_or("").starts_with("2008"),
                "{name} reissue_date = {:?}", t.reissue_date);
        if MP4_FILES.contains(name) {
            // MP4/ALAC carry no standard original-date atom (Picard writes none);
            // original year arrives via MusicBrainz enrichment in Phase 2 (spec Appendix A).
            assert_eq!(t.original_date, None, "{name} original_date should be None for MP4");
        } else {
            assert!(t.original_date.as_deref().unwrap_or("").starts_with("1999"),
                    "{name} original_date = {:?}", t.original_date);
        }
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

```bash
cd rust && cargo test --test tags_test reads_original_and_reissue_dates
```

Expected: FAIL (dates `None`).

- [ ] **Step 3: Implement date reading**

In `read_tags`, inside the `if let Some(tag)` block, add (using the generic `ItemKey` mapping):

```rust
        out.reissue_date = tag.get_string(ItemKey::RecordingDate).map(|s| s.to_string());
        out.original_date = tag.get_string(ItemKey::OriginalReleaseDate).map(|s| s.to_string());
```

> Verified for lofty 0.24: `ItemKey::RecordingDate` maps to TDRC / DATE / ©day and `ItemKey::OriginalReleaseDate` maps to TDOR / ORIGINALDATE for the ID3 and Vorbis formats. MP4/ALAC have no standard original-date atom, so `original_date` is `None` for those — which is exactly what the test above asserts.

- [ ] **Step 4: Run it, verify it passes**

```bash
cd rust && cargo test --test tags_test reads_original_and_reissue_dates
```

Expected: PASS.

- [ ] **Step 5: Run the whole tags suite + clippy**

```bash
cd rust && cargo test --test tags_test && cargo clippy --all-targets -- -D warnings
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add rust/src/tags.rs rust/tests/tags_test.rs
git commit -m "feat(core): read original vs reissue dates"
```

---

## Task 7: FFI — expose `read_tags` to Dart

**Files:**
- Create: `rust/src/api/tags.rs`, `integration_test/tags_ffi_test.dart` (or `test/`)
- Modify: `rust/src/api/mod.rs`, regenerate bindings

- [ ] **Step 1: Write the FFI wrapper**

`rust/src/api/tags.rs`:

```rust
use crate::tags::{self, TrackTags};

/// FFI-facing tag read. Returns the typed DTO straight to Dart.
pub fn read_track_tags(path: String) -> anyhow::Result<TrackTags> {
    tags::read_tags(std::path::Path::new(&path))
}
```

Add `pub mod tags;` to `rust/src/api/mod.rs`. (flutter_rust_bridge can mirror the `TrackTags` struct directly since its fields are all FFI-translatable.)

- [ ] **Step 2: Regenerate bindings**

```bash
cd /home/autarch/projects/olivier && flutter_rust_bridge_codegen generate
```

Expected: `lib/src/rust/api/tags.dart` exposes `readTrackTags(path: ...)` returning a generated `TrackTags` class.

- [ ] **Step 3: Write a Dart integration test that drives the bridge**

`integration_test/tags_ffi_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:olivier/src/rust/api/tags.dart';
import 'package:olivier/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => RustLib.init());

  test('reads tags from a flac fixture through the bridge', () async {
    final t = await readTrackTags(path: 'rust/tests/fixtures/sample.flac');
    expect(t.title, '正しい街');
    expect(t.albumArtist, '椎名林檎');
    expect(t.recordingMbid, 'aaaaaaaa-0000-0000-0000-000000000001');
  });
}
```

Add `integration_test:` to `dev_dependencies` in `pubspec.yaml`:

```yaml
dev_dependencies:
  integration_test:
    sdk: flutter
```

- [ ] **Step 4: Run the integration test on Linux**

```bash
cd /home/autarch/projects/olivier
flutter pub get
flutter test integration_test/tags_ffi_test.dart -d linux
```

Expected: PASS (relative fixture path resolves from the project root where the test host runs).

- [ ] **Step 5: Commit**

```bash
git add rust/src/api/ lib/src/rust/ integration_test/ pubspec.yaml
git commit -m "feat(ffi): expose read_track_tags to Dart"
```

---

> **FFI contract test (spec §8/§3.3):** the *full* contract test pinning the entire DTO/command surface is deferred to Phase 1, once the catalog query/command API exists. Phase 0 covers the bridge with the `readTrackTags` integration test (Task 7) plus the Rust-side queue round-trip (Task 12); the regenerated `saveQueue`/`loadQueue` bindings are exercised by the Task 12 manual spike.

---

## Task 8: Rust — catalog DB: open, migrations, FTS5 trigram search

**Files:**
- Create: `rust/src/db.rs`, `rust/tests/db_test.rs`
- Modify: `rust/src/lib.rs` (`pub mod db;`), `rust/Cargo.toml`

This proves spike (4): bundled SQLite ships FTS5 with the `trigram` tokenizer and CJK substring search works. (DB-infra tasks here write their tests alongside the schema/implementation — the schema is the unit under test — rather than strict red-first.)

- [ ] **Step 1: Add dependencies**

In `rust/Cargo.toml`:

```toml
rusqlite = { version = "0.40", features = ["bundled"] }
rusqlite_migration = "2.5"
```

- [ ] **Step 2: Declare the module + minimal API**

Add `pub mod db;` to `rust/src/lib.rs`. Create `rust/src/db.rs`:

```rust
use rusqlite::Connection;
use rusqlite_migration::{Migrations, M};

const MIGRATION_SLICE: &[M<'_>] = &[
    M::up("CREATE VIRTUAL TABLE search USING fts5(text, tokenize='trigram');"),
];
const MIGRATIONS: Migrations<'_> = Migrations::from_slice(MIGRATION_SLICE);

pub fn open(path: &str) -> anyhow::Result<Connection> {
    let mut conn = Connection::open(path)?;
    if path != ":memory:" {
        // WAL only applies to file-backed DBs; it's a silent no-op for :memory:.
        conn.pragma_update(None, "journal_mode", "WAL")?;
    }
    MIGRATIONS.to_latest(&mut conn)?;
    Ok(conn)
}

/// CJK-aware contains: the trigram tokenizer's MATCH requires >=3 chars, so for
/// 1-2 char queries fall back to LIKE (a correctness fallback the trigram table
/// still supports; treat its cost as a scan for such short patterns).
pub fn search_contains(conn: &Connection, query: &str) -> anyhow::Result<Vec<String>> {
    let char_len = query.chars().count();
    let mut out = Vec::new();
    if char_len >= 3 {
        let mut stmt = conn.prepare("SELECT text FROM search WHERE search MATCH ?1")?;
        let rows = stmt.query_map([query], |r| r.get::<_, String>(0))?;
        for r in rows { out.push(r?); }
    } else {
        let mut stmt = conn.prepare("SELECT text FROM search WHERE text LIKE '%' || ?1 || '%'")?;
        let rows = stmt.query_map([query], |r| r.get::<_, String>(0))?;
        for r in rows { out.push(r?); }
    }
    Ok(out)
}
```

- [ ] **Step 3: Write the tests**

`rust/tests/db_test.rs`:

```rust
use rust_lib_olivier::db::{open, search_contains};

fn seed() -> rusqlite::Connection {
    let conn = open(":memory:").unwrap();
    conn.execute("INSERT INTO search(text) VALUES (?1)", ["椎名林檎の歌"]).unwrap();
    conn.execute("INSERT INTO search(text) VALUES (?1)", ["Ringo Sheena live"]).unwrap();
    conn
}

#[test]
fn cjk_two_char_substring_matches_via_like() {
    let conn = seed();
    let hits = search_contains(&conn, "椎名").unwrap();   // 2 chars -> LIKE path
    assert_eq!(hits, ["椎名林檎の歌"]);
}

#[test]
fn cjk_three_char_substring_matches_via_match() {
    let conn = seed();
    let hits = search_contains(&conn, "名林檎").unwrap();  // 3 chars -> MATCH path
    assert_eq!(hits, ["椎名林檎の歌"]);
}

#[test]
fn latin_substring_matches() {
    let conn = seed();
    let hits = search_contains(&conn, "Ringo").unwrap();
    assert_eq!(hits, ["Ringo Sheena live"]);
}
```

- [ ] **Step 4: Run the tests**

```bash
cd rust && cargo test --test db_test
```

The module is already implemented in Step 2, so these should PASS. If FTS5 is somehow unavailable you'll see `no such module: fts5` — that means the `bundled` feature didn't take; re-check `Cargo.toml`. (Per research, `bundled` always compiles `-DSQLITE_ENABLE_FTS5`.)

- [ ] **Step 5: Commit**

```bash
git add rust/Cargo.toml rust/src/lib.rs rust/src/db.rs rust/tests/db_test.rs
git commit -m "feat(core): catalog DB with FTS5 trigram CJK-aware search"
```

---

## Task 9: Flutter — play a local file on Linux (manual spike)

> Tasks 9–12 wire audio/playback, which need a real audio device/desktop and (for Task 11) an Android phone. These are **manual-verification spikes**, not unit tests — each has an explicit acceptance checklist. Be honest in the commit/notes about what was actually verified.

**Files:**
- Modify: `pubspec.yaml`, `lib/main.dart`; Create: `lib/audio/queue_controller.dart` (stub used here, expanded in Task 10/12)

- [ ] **Step 1: Add audio deps**

In `pubspec.yaml` `dependencies`:

```yaml
  just_audio: ^0.10.5
  just_audio_media_kit: ^2.1.0
  media_kit_libs_linux: any
```

Run `flutter pub get`.

- [ ] **Step 2: Initialize the libmpv backend in `main()`**

Edit `lib/main.dart` `main()`:

```dart
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(
    linux: true, windows: false, android: false, iOS: false, macOS: false,
  );
  await RustLib.init();
  runApp(const OlivierApp());
}
```

- [ ] **Step 3: Add a play button wired to a fixture**

Replace the `body:` of the scaffold with a button that plays a fixture (use an absolute path to one of the longer files in your library for an audible test, or the 1s fixture to confirm playback starts):

```dart
import 'package:just_audio/just_audio.dart';
// ... in a StatefulWidget:
final _player = AudioPlayer();
Future<void> _playTest() async {
  await _player.setFilePath('/home/autarch/Music/<pick-a-real-song>.flac');
  await _player.play();
}
// body: Center(child: ElevatedButton(onPressed: _playTest, child: const Text('Play')))
```

- [ ] **Step 4: Run and verify audio (manual acceptance)**

```bash
flutter run -d linux
```

Acceptance checklist — **record results in Task 13's spike doc**:
- [ ] App launches; pressing Play produces audio.
- [ ] Test one file of **each** codec from your library (MP3, FLAC, AAC/M4A, **ALAC**, Ogg Vorbis, **Opus**) — note any that fail (this is the libmpv codec-coverage spike).

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml lib/main.dart
git commit -m "feat(audio): libmpv playback on Linux (spike)"
```

---

## Task 10: Flutter — app-side shuffle via `setAudioSources` (manual spike)

**Files:**
- Create/Modify: `lib/audio/queue_controller.dart`

- [ ] **Step 1: Implement an ordered queue with app-side shuffle**

`lib/audio/queue_controller.dart`:

```dart
import 'package:just_audio/just_audio.dart';

/// Holds the canonical ordered list and rebuilds the player's sources on
/// shuffle (engine shuffle is ignored by the media_kit backend on Linux).
class QueueController {
  QueueController(this.player);
  final AudioPlayer player;

  List<String> _orderedPaths = [];
  bool _shuffled = false;

  Future<void> setQueue(List<String> paths, {int initialIndex = 0}) async {
    _orderedPaths = List.of(paths);
    _shuffled = false;
    await _rebuild(initialIndex);
  }

  Future<void> setShuffle(bool on, {int? keepIndexAtPath}) async {
    _shuffled = on;
    await _rebuild(0);
  }

  Future<void> _rebuild(int initialIndex) async {
    final order = _shuffled ? (List.of(_orderedPaths)..shuffle()) : _orderedPaths;
    await player.setAudioSources(
      [for (final p in order) AudioSource.file(p)],
      initialIndex: order.isEmpty ? null : initialIndex.clamp(0, order.length - 1),
      initialPosition: Duration.zero,
    );
  }
}
```

- [ ] **Step 2: Wire a temporary "shuffle" button + 3 fixtures and verify (manual acceptance)**

Temporarily build a 3-track queue (use three real songs) and a button toggling `setShuffle`. Run `flutter run -d linux`.

Acceptance — record in Task 13:
- [ ] Setting a 3-track queue plays them in order; `skipToNext` advances.
- [ ] Toggling shuffle **on** rebuilds the order (observe a different sequence) and playback continues.
- [ ] Toggling shuffle **off** restores original order.

- [ ] **Step 3: Commit**

```bash
git add lib/audio/queue_controller.dart lib/main.dart
git commit -m "feat(audio): app-side shuffle via setAudioSources (spike)"
```

---

## Task 11: Flutter — `audio_service` background + MPRIS skeleton (manual spike)

**Files:**
- Create: `lib/audio/audio_handler.dart`
- Modify: `pubspec.yaml`, `lib/main.dart`, `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Add deps**

```yaml
  audio_service: ^0.18.18
  audio_service_mpris: ^1.0.0-beta.2
```

Run `flutter pub get`.

- [ ] **Step 2: Android manifest**

In `android/app/src/main/AndroidManifest.xml`, add permissions inside `<manifest>` and the service/receiver inside `<application>`:

```xml
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```
```xml
        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true" tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true" tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON" />
            </intent-filter>
        </receiver>
```

Ensure the `<manifest>` tag has `xmlns:tools="http://schemas.android.com/tools"`.

- [ ] **Step 3: Implement the handler**

`lib/audio/audio_handler.dart`:

```dart
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

class OlivierAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer player = AudioPlayer();

  OlivierAudioHandler() {
    player.playbackEventStream.map(_toState).pipe(playbackState);
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> stop() => player.stop();
  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> skipToNext() => player.seekToNext();
  @override
  Future<void> skipToPrevious() => player.seekToPrevious();

  PlaybackState _toState(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: player.playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
    );
  }
}
```

- [ ] **Step 4: Initialize in `main()`**

In `lib/main.dart` `main()`, after `JustAudioMediaKit.ensureInitialized(...)` and before `runApp`:

```dart
import 'dart:io' show Platform;
import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:olivier/audio/audio_handler.dart';

late final OlivierAudioHandler audioHandler;
// ... inside main(), after RustLib.init():
if (Platform.isLinux) {
  await AudioServiceMpris.init(
    dBusName: 'OlivierMusicPlayer',
    identity: 'Olivier',
  );
}
audioHandler = await AudioService.init(
  builder: () => OlivierAudioHandler(),
  config: const AudioServiceConfig(
    androidNotificationChannelId: 'org.urth.olivier.channel.audio',
    androidNotificationChannelName: 'Music playback',
    androidNotificationOngoing: true,
  ),
);
```

> Confirm `AudioServiceMpris.init` parameter names against the installed `1.0.0-beta.2` (the API is pre-release). If a named param differs, the analyzer will flag it — adjust to the installed signature.

- [ ] **Step 5: Verify (manual acceptance)**

Linux:
```bash
flutter run -d linux
# in another terminal:
playerctl -l        # should list Olivier
playerctl play-pause; playerctl next
```
- [ ] Desktop MPRIS shows Olivier; play/pause/next from `playerctl` (and the GNOME/KDE media widget) control playback.

Android (if a device is available; otherwise defer to Phase 4 and note it):
```bash
flutter run -d <android-device-id>
```
- [ ] A media notification appears; controls work from the notification/lockscreen; **audio continues when the app is backgrounded**.

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml lib/audio/audio_handler.dart lib/main.dart android/app/src/main/AndroidManifest.xml
git commit -m "feat(audio): audio_service background + MPRIS skeleton (spike)"
```

---

## Task 12: Flutter + Rust — persisted-queue round-trip (§3.4) (manual spike)

**Files:**
- Create: `rust/src/api/queue.rs`
- Modify: `rust/src/db.rs` (queue tables), `rust/src/api/mod.rs`, `lib/audio/queue_controller.dart`, regenerate bindings

Proves the §3.4 protocol: Dart is runtime-authoritative; Rust persists; on restart the queue + index + position rehydrate.

> **Phase-0 scope:** the queue is persisted by file **path** (no `track` table exists yet). The spec's `track_id`-keyed `queue_item` and `shuffled_position` persistence land in Phase 3 with the real catalog, so the `shuffled_position` column created here is reserved/unused for now — this divergence is intentional, not an oversight.

- [ ] **Step 1: Add queue persistence to the DB (migration)**

Append a migration to `MIGRATION_SLICE` in `rust/src/db.rs`:

```rust
    M::up(
        "CREATE TABLE queue_item (
            position INTEGER PRIMARY KEY,
            path TEXT NOT NULL,
            shuffled_position INTEGER
         );
         CREATE TABLE playback_state (
            id INTEGER PRIMARY KEY CHECK (id = 0),
            current_index INTEGER NOT NULL,
            position_ms INTEGER NOT NULL,
            shuffle INTEGER NOT NULL
         );",
    ),
```

> Migrations are append-only — add this as a **new** `M::up`, never edit the existing one.

- [ ] **Step 2: Implement save/load functions + FFI**

Add to `rust/src/db.rs`:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueSnapshot {
    pub paths: Vec<String>,
    pub current_index: u32,
    pub position_ms: u64,
    pub shuffle: bool,
}

pub fn save_queue(conn: &Connection, snap: &QueueSnapshot) -> anyhow::Result<()> {
    conn.execute("DELETE FROM queue_item", [])?;
    for (i, p) in snap.paths.iter().enumerate() {
        conn.execute("INSERT INTO queue_item(position, path) VALUES (?1, ?2)",
                     rusqlite::params![i as i64, p])?;
    }
    conn.execute(
        "INSERT INTO playback_state(id, current_index, position_ms, shuffle)
         VALUES (0, ?1, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET current_index=?1, position_ms=?2, shuffle=?3",
        rusqlite::params![snap.current_index as i64, snap.position_ms as i64, snap.shuffle as i64],
    )?;
    Ok(())
}

pub fn load_queue(conn: &Connection) -> anyhow::Result<Option<QueueSnapshot>> {
    let mut stmt = conn.prepare("SELECT path FROM queue_item ORDER BY position")?;
    let paths: Vec<String> = stmt.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?;
    if paths.is_empty() { return Ok(None); }
    let st = conn.query_row(
        "SELECT current_index, position_ms, shuffle FROM playback_state WHERE id = 0",
        [], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)),
    );
    let (ci, pos, sh) = st.unwrap_or((0, 0, 0));
    Ok(Some(QueueSnapshot {
        paths, current_index: ci as u32, position_ms: pos as u64, shuffle: sh != 0,
    }))
}
```

`rust/src/api/queue.rs`:

```rust
use crate::db::{self, QueueSnapshot};

pub fn save_queue(db_path: String, snapshot: QueueSnapshot) -> anyhow::Result<()> {
    let conn = db::open(&db_path)?;
    db::save_queue(&conn, &snapshot)
}

pub fn load_queue(db_path: String) -> anyhow::Result<Option<QueueSnapshot>> {
    let conn = db::open(&db_path)?;
    db::load_queue(&conn)
}
```

Add `pub mod queue;` to `rust/src/api/mod.rs`.

- [ ] **Step 3: Test the round-trip in Rust**

Append to `rust/tests/db_test.rs`:

```rust
use rust_lib_olivier::db::{save_queue, load_queue, QueueSnapshot};

#[test]
fn queue_round_trips() {
    let conn = rust_lib_olivier::db::open(":memory:").unwrap();
    let snap = QueueSnapshot {
        paths: vec!["/a.flac".into(), "/b.mp3".into(), "/c.opus".into()],
        current_index: 1, position_ms: 42_000, shuffle: true,
    };
    save_queue(&conn, &snap).unwrap();
    assert_eq!(load_queue(&conn).unwrap(), Some(snap));
}
```

Run:
```bash
cd rust && cargo test --test db_test queue_round_trips
```
Expected: PASS.

- [ ] **Step 4: Regenerate bindings + wire Dart write-back/hydration**

```bash
cd /home/autarch/projects/olivier && flutter_rust_bridge_codegen generate
```

Add `path_provider: ^2.1.0` to `pubspec.yaml` `dependencies` and `flutter pub get`. In `queue_controller.dart`, call `saveQueue(...)` after every structural change and a throttled `saveQueue` (~5s / on pause) for position; on app start call `loadQueue(...)` and rebuild via `setAudioSources(..., initialIndex:, initialPosition:)`. Use the app's documents dir (`getApplicationDocumentsDirectory()` from `path_provider`, e.g. `<dir>/olivier.db`) for the db path.

- [ ] **Step 5: Verify (manual acceptance)**

Run on Linux, enqueue 3 tracks, play to mid-track, **quit**, relaunch.
- [ ] On relaunch the same queue is present, positioned at the same track and ~same offset.
- [ ] Record result in Task 13.

- [ ] **Step 6: Commit**

```bash
git add rust/src/db.rs rust/src/api/ lib/ lib/src/rust/ pubspec.yaml
git commit -m "feat: persisted-queue round-trip (spec §3.4) (spike)"
```

---

## Task 13: Record spike outcomes for Phase 1

**Files:**
- Create: `docs/superpowers/spikes/phase0-results.md`

- [ ] **Step 1: Write the results doc**

Capture concrete findings that shape Phase 1 (do not leave blanks — write what was actually observed):

```markdown
# Phase 0 spike results (YYYY-MM-DD)

## Tag/MBID reading (lofty)
- Automated tests pass for all six fixture formats.
- Spot-checked against N real Picard-tagged files from the library: <results, any frames missed>.

## libmpv codec coverage on <distro + libmpv version>
- MP3 / FLAC / AAC-M4A / ALAC / Ogg Vorbis / Opus: <play? yes/no each>.
- Any packaging issues (libmpv discovery, Flatpak): <notes>.

## audio_service background + MPRIS
- Linux MPRIS via playerctl/GNOME: <works? gaps — seek/volume as expected>.
- Android (if tested): notification + background playback <works? else deferred to Phase 4>.

## Persisted-queue round-trip (§3.4)
- Quit/relaunch restores queue + index + position: <result>.

## Decisions / adjustments for Phase 1
- <e.g., double-read in read_tags acceptable? optimize in Phase 1? any codec needing a fallback?>
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/spikes/phase0-results.md
git commit -m "docs: record Phase 0 spike outcomes"
```

---

## Done criteria for Phase 0

- `flutter run -d linux` shows the app and a Rust-sourced string (bridge works).
- `cd rust && cargo test --all` green: common fields, MBIDs, dates across six formats; FTS5 trigram CJK search; queue round-trip.
- `flutter test integration_test/tags_ffi_test.dart -d linux` green (FFI surface works).
- CI green on Rust + Flutter jobs.
- Manual spikes recorded in `docs/superpowers/spikes/phase0-results.md`: libmpv codec coverage, background playback/MPRIS, queue round-trip.
- No `audio_service_mpris`/`ItemKey`/Vorbis-comment API surprises left unresolved (each flagged note either confirmed or adjusted).
