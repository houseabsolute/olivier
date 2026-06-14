# Olivier

A personal music player for a local, MusicBrainz-tagged collection, targeting **Linux desktop** and
**Android**. Flutter (UI + audio) with a Rust core via
[`flutter_rust_bridge`](https://cjycode.com/flutter_rust_bridge/): Rust owns file scanning, tag
reading (`lofty`), MusicBrainz enrichment, and the SQLite catalog; Dart drives the UI and the audio
engine (`just_audio` / `audio_service`).

Design spec:
[docs/superpowers/specs/2026-06-13-olivier-design.md](docs/superpowers/specs/2026-06-13-olivier-design.md).
This branch implements **Phase 0** (foundations & spikes) —
[plan](docs/superpowers/plans/2026-06-14-olivier-phase0-foundations.md),
[results](docs/superpowers/spikes/phase0-results.md).

## Prerequisites

Tools are pinned in `mise.toml` (Flutter, ninja, `flutter_rust_bridge_codegen`, and the precious
lint stack). Install [mise](https://mise.jdx.dev), then from the repo root:

```sh
mise install
```

Rust (via rustup) is managed outside mise. System libraries for the Linux desktop build
(Ubuntu/Debian):

```sh
sudo apt-get install -y clang cmake pkg-config libgtk-3-dev liblzma-dev \
    libstdc++-14-dev libmpv-dev
```

## Common tasks

```sh
# Rust core tests
cd rust && cargo test

# Run the app (Linux desktop)
mise exec -- flutter run -d linux

# Lint / auto-format everything (clippy, rustfmt, dart, prettier, taplo, typos, ...)
just lint --all
just tidy --all

# Regenerate the Dart<->Rust bindings after changing the Rust API
mise exec -- flutter_rust_bridge_codegen generate

# Regenerate the test audio fixtures (needs ffmpeg + python mutagen)
./scripts/make-fixtures.sh
```
