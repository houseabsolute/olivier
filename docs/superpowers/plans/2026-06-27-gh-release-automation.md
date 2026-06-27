# GitHub Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a `v*` git tag, build the Linux release of Olivier and publish a GitHub Release with a `.deb`, `.rpm`, and `.tar.gz`.

**Architecture:** Keep the GitHub Actions workflow thin; put the real logic in `scripts/stage-release.sh` (lays out the install tree + tarball) and `packaging/nfpm.yaml` (declares the deb/rpm), both runnable locally via a `just package` recipe. nfpm is pinned in mise so CI and local use the same version.

**Tech Stack:** GitHub Actions, nfpm (deb+rpm from one config), mise, Flutter 3.44.2 (cargokit/Rust), bash.

**Spec:** `docs/superpowers/specs/2026-06-27-gh-release-automation-design.md`

---

## Repository facts (verified — rely on these, don't re-discover)

- Release build: `mise exec -- flutter build linux --release` → `build/linux/x64/release/bundle/` containing the executable `olivier`, `lib/*.so`, and `data/`. RPATH `$ORIGIN/lib`; self-contained except system libs.
- The Flutter build needs a Rust toolchain on PATH (cargokit runs `cargo`), mise (Flutter + ninja), and apt deps: `clang cmake pkg-config libgtk-3-dev liblzma-dev libstdc++-14-dev libmpv-dev`.
- Runtime deps NOT bundled: **libmpv** (dlopened → must be declared) and GTK3.
- Committed assets: `linux/org.urth.olivier.desktop`; icons `assets/icon/hicolor/<n>x<n>/olivier.png` for n ∈ {16,24,32,48,64,128,256,512} and `assets/icon/olivier.svg`.
- `LICENSE` (Apache-2.0) already exists at repo root.
- `mise.toml` registry: `nfpm` resolves to `aqua:goreleaser/nfpm`; latest 2.47.0.
- Remote: `origin` = `git@github.com:houseabsolute/olivier.git` (repo `houseabsolute/olivier`). The release workflow runs on GitHub once the repo and a `v*` tag are pushed; during plan execution it can't be triggered, so the locally-runnable `just package` is the real test of the packaging logic.
- Lint: `just lint --all` (precious → shellcheck/shfmt for `scripts/*.sh`, prettier for YAML, taplo for TOML). `just tidy` auto-formats.

## File Structure

- `mise.toml` (MODIFY) — pin `nfpm`.
- `pubspec.yaml` (MODIFY) — real `description`. (pubspec has no `license` field; the LICENSE file + package metadata carry the license.)
- `rust/Cargo.toml` (MODIFY) — add `license = "Apache-2.0"`.
- `.gitignore` (MODIFY) — ignore `/dist/` and `/staging/`.
- `precious.toml` (MODIFY) — exclude `dist/**`, `staging/**` from lint.
- `packaging/README.tarball.md` (CREATE) — run instructions shipped in the tarball + deb/rpm docdir.
- `scripts/stage-release.sh` (CREATE) — builds `staging/` (FHS tree) + `dist/<name>.tar.gz` from a finished bundle.
- `packaging/nfpm.yaml` (CREATE) — declares the deb/rpm from `staging/`.
- `Justfile` (MODIFY) — add `package` recipe.
- `.github/workflows/release.yml` (CREATE) — the tag-triggered pipeline.

---

## Task 1: Foundations — pin nfpm, metadata, ignore/lint excludes

**Files:**
- Modify: `mise.toml`, `pubspec.yaml`, `rust/Cargo.toml`, `.gitignore`, `precious.toml`

- [ ] **Step 1: Pin nfpm in `mise.toml`**

In `mise.toml`, under `[tools]`, add this line after the `flutter`/`ninja` lines (anywhere in the `[tools]` block is fine):

```toml
# Packaging: builds the .deb and .rpm release artifacts (see packaging/nfpm.yaml).
nfpm = "2.47.0"
```

- [ ] **Step 2: Install nfpm and verify**

Run: `mise install nfpm && mise exec -- nfpm --version`
Expected: prints `nfpm version v2.47.0` (or similar).

- [ ] **Step 3: Real description in `pubspec.yaml`**

Replace the line:

```yaml
description: A new Flutter project.
```

with:

```yaml
description: A bilingual-aware music player.
```

- [ ] **Step 4: License field in `rust/Cargo.toml`**

In the `[package]` table, add a `license` line after `edition = "2021"`:

```toml
license = "Apache-2.0"
```

- [ ] **Step 5: Ignore build outputs**

In `.gitignore`, add these two lines (after the existing `/build/` line):

```gitignore
/dist/
/staging/
```

- [ ] **Step 6: Exclude build outputs from lint**

In `precious.toml`, add these two entries to the top-level `exclude = [ ... ]` array (e.g. right after the `"build/**",` line):

```toml
    "dist/**",
    "staging/**",
```

- [ ] **Step 7: Verify lint + cargo still happy**

Run: `just lint --all`
Expected: passes (taplo accepts the new TOML, prettier accepts pubspec).
Run: `mise exec -- cargo metadata --manifest-path rust/Cargo.toml --no-deps --format-version 1 >/dev/null && echo OK`
Expected: `OK` (the new `license` key parses).

- [ ] **Step 8: Commit**

```bash
git add mise.toml pubspec.yaml rust/Cargo.toml .gitignore precious.toml
git commit -m "Pin nfpm in mise; add license/description metadata"
```

---

## Task 2: `scripts/stage-release.sh` + tarball README

**Files:**
- Create: `packaging/README.tarball.md`, `scripts/stage-release.sh`

- [ ] **Step 1: Create the tarball/doc README**

Create `packaging/README.tarball.md`:

```markdown
# Olivier (Linux x86_64)

A bilingual-aware music player.

## Running from the tarball

This archive contains a self-contained build. Run it with:

    ./olivier

## Runtime requirement: libmpv

Audio playback uses libmpv, which is **not** bundled. Install it from your
distribution:

- Debian/Ubuntu: `sudo apt install libmpv2` (or `libmpv1` on older releases)
- Fedora: `sudo dnf install mpv-libs`

## Desktop integration (optional)

`org.urth.olivier.desktop` and the icons under `icons/hicolor/` can be copied
into `~/.local/share/applications` and `~/.local/share/icons/hicolor`
respectively. The `.deb`/`.rpm` packages do this for you.

## License

Apache-2.0. See `LICENSE`.
```

- [ ] **Step 2: Create the staging script**

Create `scripts/stage-release.sh`:

```bash
#!/usr/bin/env bash
# Build the Olivier release install tree (FHS layout, consumed by nfpm) and a
# relocatable tarball, from a finished `flutter build linux --release` bundle.
#
# Usage: scripts/stage-release.sh <bundle_dir> <version> <out_dir>
#   bundle_dir  e.g. build/linux/x64/release/bundle
#   version     e.g. 0.0.1 (no leading "v")
#   out_dir     created if needed; populated with <out_dir>/staging and
#               <out_dir>/dist/olivier-<version>-linux-x64.tar.gz
set -euo pipefail

bundle_dir=${1:?usage: stage-release.sh <bundle_dir> <version> <out_dir>}
version=${2:?usage: stage-release.sh <bundle_dir> <version> <out_dir>}
out_dir=${3:?usage: stage-release.sh <bundle_dir> <version> <out_dir>}

cd "$(dirname "$0")/.."
repo="$PWD"

if [[ ! -x "$bundle_dir/olivier" ]]; then
    echo "release bundle not found at $bundle_dir/olivier" >&2
    echo "build it first: mise exec -- flutter build linux --release" >&2
    exit 1
fi

staging="$out_dir/staging"
dist="$out_dir/dist"
rm -rf "$staging"
mkdir -p "$staging" "$dist"

# 1. Whole app bundle -> /usr/lib/olivier
install -d "$staging/usr/lib/olivier"
cp -a "$bundle_dir/." "$staging/usr/lib/olivier/"

# 2. Desktop entry -> /usr/share/applications (Exec=olivier resolves via the
#    /usr/bin/olivier symlink that nfpm adds).
install -d "$staging/usr/share/applications"
install -m 0644 "$repo/linux/org.urth.olivier.desktop" \
    "$staging/usr/share/applications/org.urth.olivier.desktop"

# 3. Themed icons -> /usr/share/icons/hicolor
for n in 16 24 32 48 64 128 256 512; do
    install -d "$staging/usr/share/icons/hicolor/${n}x${n}/apps"
    install -m 0644 "$repo/assets/icon/hicolor/${n}x${n}/olivier.png" \
        "$staging/usr/share/icons/hicolor/${n}x${n}/apps/olivier.png"
done
install -d "$staging/usr/share/icons/hicolor/scalable/apps"
install -m 0644 "$repo/assets/icon/olivier.svg" \
    "$staging/usr/share/icons/hicolor/scalable/apps/olivier.svg"

# 4. License + README -> /usr/share/doc/olivier
install -d "$staging/usr/share/doc/olivier"
install -m 0644 "$repo/LICENSE" "$staging/usr/share/doc/olivier/LICENSE"
install -m 0644 "$repo/packaging/README.tarball.md" \
    "$staging/usr/share/doc/olivier/README"

# 5. Relocatable tarball: olivier-<version>-linux-x64/
top="olivier-${version}-linux-x64"
tarroot="$dist/$top"
rm -rf "$tarroot"
mkdir -p "$tarroot/icons"
cp -a "$bundle_dir/." "$tarroot/"
install -m 0644 "$repo/linux/org.urth.olivier.desktop" \
    "$tarroot/org.urth.olivier.desktop"
cp -a "$staging/usr/share/icons/hicolor" "$tarroot/icons/hicolor"
install -m 0644 "$repo/LICENSE" "$tarroot/LICENSE"
install -m 0644 "$repo/packaging/README.tarball.md" "$tarroot/README"
tar -C "$dist" -czf "$dist/${top}.tar.gz" "$top"
rm -rf "$tarroot"

echo "staged:  $staging"
echo "tarball: $dist/${top}.tar.gz"
```

- [ ] **Step 3: Make it executable**

Run: `chmod +x scripts/stage-release.sh`

- [ ] **Step 4: Test it against a FAKE bundle (no slow flutter build)**

Run:

```bash
rm -rf /tmp/olv-fake && mkdir -p /tmp/olv-fake/bundle/lib /tmp/olv-fake/bundle/data/flutter_assets
printf '#!/bin/sh\necho olivier\n' > /tmp/olv-fake/bundle/olivier && chmod +x /tmp/olv-fake/bundle/olivier
: > /tmp/olv-fake/bundle/lib/librust_lib_olivier.so
: > /tmp/olv-fake/bundle/data/flutter_assets/AssetManifest.json
./scripts/stage-release.sh /tmp/olv-fake/bundle 0.0.0-test /tmp/olv-fake
```

Expected output ends with `staged:` and `tarball:` lines.

- [ ] **Step 5: Assert the staging layout + tarball contents**

Run:

```bash
test -x /tmp/olv-fake/staging/usr/lib/olivier/olivier
test -f /tmp/olv-fake/staging/usr/lib/olivier/lib/librust_lib_olivier.so
test -f /tmp/olv-fake/staging/usr/share/applications/org.urth.olivier.desktop
test -f /tmp/olv-fake/staging/usr/share/icons/hicolor/256x256/apps/olivier.png
test -f /tmp/olv-fake/staging/usr/share/icons/hicolor/scalable/apps/olivier.svg
test -f /tmp/olv-fake/staging/usr/share/doc/olivier/LICENSE
tar tzf /tmp/olv-fake/dist/olivier-0.0.0-test-linux-x64.tar.gz | grep -q '^olivier-0.0.0-test-linux-x64/olivier$'
echo "STAGE OK"
```

Expected: `STAGE OK` (every `test` passes; the `grep` finds the top-level executable in the tarball).

- [ ] **Step 6: Lint the script**

Run: `just lint scripts/stage-release.sh`
Expected: passes (shellcheck + shfmt). If shfmt reformats, run `just tidy scripts/stage-release.sh` and re-lint.

- [ ] **Step 7: Commit**

```bash
git add scripts/stage-release.sh packaging/README.tarball.md
git commit -m "Add stage-release.sh: build install tree + tarball from the bundle"
```

---

## Task 3: `packaging/nfpm.yaml` + `just package`

**Files:**
- Create: `packaging/nfpm.yaml`
- Modify: `Justfile`

- [ ] **Step 1: Create the nfpm config**

Create `packaging/nfpm.yaml`:

```yaml
name: olivier
arch: amd64
platform: linux
version: ${VERSION}
maintainer: Dave Rolsky <autarch@urth.org>
description: A bilingual-aware music player.
homepage: https://github.com/houseabsolute/olivier
license: Apache-2.0
section: sound
priority: optional
contents:
  - src: ./staging/usr/lib/olivier
    dst: /usr/lib/olivier
    type: tree
  - src: ./staging/usr/share/icons/hicolor
    dst: /usr/share/icons/hicolor
    type: tree
  - src: ./staging/usr/share/applications/org.urth.olivier.desktop
    dst: /usr/share/applications/org.urth.olivier.desktop
  - src: ./staging/usr/share/doc/olivier/LICENSE
    dst: /usr/share/doc/olivier/LICENSE
  - src: ./staging/usr/share/doc/olivier/README
    dst: /usr/share/doc/olivier/README
  - src: /usr/lib/olivier/olivier
    dst: /usr/bin/olivier
    type: symlink
overrides:
  deb:
    depends:
      - libmpv2 | libmpv1
      - libgtk-3-0 | libgtk-3-0t64
  rpm:
    depends:
      - mpv-libs
      - gtk3
```

- [ ] **Step 2: Add the `package` recipe to `Justfile`**

Append to `Justfile`:

```just
# Build the Linux release and produce dist/*.deb, *.rpm, and *.tar.gz locally
# (the same script + nfpm config the release workflow uses). Usage:
# `just package` or `just package 0.0.1`. Requires the Flutter build toolchain.
package version="0.0.0-dev":
    #!/usr/bin/env bash
    set -euo pipefail
    ver='{{ version }}'
    base="${ver%%-*}"
    mise exec -- flutter build linux --release --build-name="$base" --build-number=0
    ./scripts/stage-release.sh build/linux/x64/release/bundle "$ver" .
    VERSION="$ver" mise exec -- nfpm pkg -p deb -f packaging/nfpm.yaml -t dist/
    VERSION="$ver" mise exec -- nfpm pkg -p rpm -f packaging/nfpm.yaml -t dist/
    echo "Artifacts:"
    ls -1 dist/
```

- [ ] **Step 3: Structural test of nfpm against the FAKE staging (fast)**

This reuses the fake staging from Task 2 (regenerate if `/tmp/olv-fake` is gone using Task 2 Step 4). Build a deb from a temporary staging in the repo root, because `nfpm.yaml` references `./staging`:

```bash
# Recreate the fake bundle + staging in the repo so ./staging resolves.
rm -rf /tmp/olv-fake && mkdir -p /tmp/olv-fake/bundle/lib /tmp/olv-fake/bundle/data/flutter_assets
printf '#!/bin/sh\necho olivier\n' > /tmp/olv-fake/bundle/olivier && chmod +x /tmp/olv-fake/bundle/olivier
: > /tmp/olv-fake/bundle/lib/librust_lib_olivier.so
: > /tmp/olv-fake/bundle/data/flutter_assets/AssetManifest.json
./scripts/stage-release.sh /tmp/olv-fake/bundle 0.0.0-test .   # creates ./staging + ./dist
VERSION=0.0.0-test mise exec -- nfpm pkg -p deb -f packaging/nfpm.yaml -t dist/
dpkg-deb --info dist/olivier_0.0.0-test_amd64.deb | grep -E 'Package:|Version:|Depends:|License' || true
dpkg-deb --contents dist/olivier_0.0.0-test_amd64.deb | grep -E 'usr/bin/olivier|usr/lib/olivier/olivier|org.urth.olivier.desktop|256x256/apps/olivier.png'
```

Expected: `Depends:` line contains `libmpv2 | libmpv1` and `libgtk-3-0 | libgtk-3-0t64`; the contents listing shows `/usr/bin/olivier` as a symlink (`-> /usr/lib/olivier/olivier`), the real executable, the desktop file, and an icon.

- [ ] **Step 4: Assert the deb dependency + symlink precisely**

Run:

```bash
dpkg-deb --field dist/olivier_0.0.0-test_amd64.deb Depends | grep -q 'libmpv2 | libmpv1' && echo "DEPS OK"
dpkg-deb --contents dist/olivier_0.0.0-test_amd64.deb | grep -q 'usr/bin/olivier -> /usr/lib/olivier/olivier' && echo "SYMLINK OK"
```

Expected: `DEPS OK` and `SYMLINK OK`.

- [ ] **Step 5: Clean the throwaway artifacts**

Run: `rm -rf ./staging ./dist`
(These are gitignored, but remove them so the working tree is clean.)

- [ ] **Step 6: End-to-end REAL build (definitive; slow — a real release build)**

Run: `just package 0.0.0-dev`
Expected: finishes with an `Artifacts:` listing showing `olivier_0.0.0-dev_amd64.deb`, `olivier-0.0.0-dev.x86_64.rpm`, and `olivier-0.0.0-dev-linux-x64.tar.gz` in `dist/`.

Then verify the real artifacts:

```bash
dpkg-deb --contents dist/olivier_0.0.0-dev_amd64.deb | grep -q 'usr/lib/olivier/lib/librust_lib_olivier.so' && echo "REAL DEB OK"
tar tzf dist/olivier-0.0.0-dev-linux-x64.tar.gz | grep -q 'olivier-0.0.0-dev-linux-x64/lib/librust_lib_olivier.so' && echo "REAL TARBALL OK"
test -s dist/olivier-0.0.0-dev.x86_64.rpm && echo "REAL RPM OK"
```

Expected: `REAL DEB OK`, `REAL TARBALL OK`, `REAL RPM OK`. (If `just package` cannot complete the Flutter release build in this environment, report it as DONE_WITH_CONCERNS — Steps 3–4 already validated the packaging config against a staged tree.)

- [ ] **Step 7: Clean + lint**

Run: `rm -rf ./staging ./dist`
Run: `just lint --all`
Expected: passes. If prettier reformats `packaging/nfpm.yaml` or the Justfile, run `just tidy` and re-lint. Confirm `git status` shows only `packaging/nfpm.yaml` and `Justfile` (no `dist/`/`staging/`).

- [ ] **Step 8: Commit**

```bash
git add packaging/nfpm.yaml Justfile
git commit -m "Add nfpm.yaml + just package recipe (deb/rpm/tarball locally)"
```

---

## Task 4: `.github/workflows/release.yml`

**Files:**
- Create: `.github/workflows/release.yml`

Note: the remote is `houseabsolute/olivier`, but the workflow can only be triggered on GitHub (by pushing the repo + a `v*` tag), not from here. Its packaging logic was proven end-to-end by `just package` in Task 3. Validate here by lint + careful reading.

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release
on:
  push:
    tags:
      - "v*"
  workflow_dispatch:
    inputs:
      version:
        description: "Version to build (no leading v), e.g. 0.0.1 or 0.0.1-rc1"
        required: true
        default: "0.0.0-dev"

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # cargokit invokes cargo during `flutter build linux`.
      - uses: dtolnay/rust-toolchain@stable
      # mise provides Flutter, ninja, and nfpm (pinned in mise.toml).
      - uses: jdx/mise-action@v2
      - name: System libraries for the Flutter Linux build
        run: |
          sudo apt-get update
          sudo apt-get install -y clang cmake pkg-config libgtk-3-dev liblzma-dev libstdc++-14-dev libmpv-dev rpm
      - name: Resolve version + prerelease flag
        id: ver
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            version="${{ github.event.inputs.version }}"
          else
            version="${GITHUB_REF_NAME#v}"
          fi
          echo "version=$version" >> "$GITHUB_OUTPUT"
          case "$version" in
            *-*) echo "prerelease=true" >> "$GITHUB_OUTPUT" ;;
            *) echo "prerelease=false" >> "$GITHUB_OUTPUT" ;;
          esac
      - run: mise exec -- flutter pub get
      - name: Build release bundle
        run: |
          base="${{ steps.ver.outputs.version }}"
          base="${base%%-*}"
          mise exec -- flutter build linux --release \
            --build-name="$base" --build-number="${{ github.run_number }}"
      - name: Stage install tree + tarball
        run: ./scripts/stage-release.sh build/linux/x64/release/bundle "${{ steps.ver.outputs.version }}" .
      - name: Build deb + rpm
        env:
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          mise exec -- nfpm pkg -p deb -f packaging/nfpm.yaml -t dist/
          mise exec -- nfpm pkg -p rpm -f packaging/nfpm.yaml -t dist/
      - name: Smoke-test the .deb
        run: |
          sudo apt-get install -y ./dist/olivier_*.deb
          test -L /usr/bin/olivier
          test -x /usr/lib/olivier/olivier
          # libmpv is dlopened (not a NEEDED entry), so its absence here is fine;
          # fail only if a *linked* library is missing.
          if ldd /usr/lib/olivier/olivier | grep -i 'not found'; then
            echo "missing linked library" >&2
            exit 1
          fi
      - name: Inspect the .rpm (structural)
        run: |
          rpm -qp --info dist/olivier-*.rpm
          rpm -qp --requires dist/olivier-*.rpm
          rpm -qp --list dist/olivier-*.rpm
      - name: Upload artifacts (dry runs)
        if: github.event_name == 'workflow_dispatch'
        uses: actions/upload-artifact@v4
        with:
          name: olivier-${{ steps.ver.outputs.version }}
          path: |
            dist/olivier_*.deb
            dist/olivier-*.rpm
            dist/olivier-*-linux-x64.tar.gz
      - name: Publish GitHub Release (tags only)
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          prerelease: ${{ steps.ver.outputs.prerelease }}
          files: |
            dist/olivier_*.deb
            dist/olivier-*.rpm
            dist/olivier-*-linux-x64.tar.gz
```

- [ ] **Step 2: Validate the YAML parses**

Run: `mise exec -- node -e "const fs=require('fs');const s=fs.readFileSync('.github/workflows/release.yml','utf8');require('child_process');console.log('len',s.length)"`
(That just confirms the file is readable; for a real YAML parse:)
Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"`
Expected: `YAML OK`.

- [ ] **Step 3: Lint**

Run: `just lint .github/workflows/release.yml`
Expected: passes (prettier). If it reformats, `just tidy .github/workflows/release.yml` and re-lint.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add release workflow: build + package + publish on v* tags"
```

---

## Self-Review

**1. Spec coverage:**
- Tag-triggered build + GitHub Release with deb/rpm/tarball → Task 4 (workflow). ✓
- nfpm one-config deb+rpm → Task 3. ✓
- libmpv/GTK declared deps (deb `libmpv2 | libmpv1`, rpm `mpv-libs`) → Task 3 `overrides`. ✓
- Install layout (`/usr/lib/olivier`, `/usr/bin/olivier` symlink, desktop, icons, doc) → Task 2 (staging) + Task 3 (symlink in nfpm). ✓
- Tarball (relocatable, README, libmpv note) → Task 2. ✓
- Version from tag; `--build-name`/`--build-number` stamp; prerelease on suffix → Task 4. ✓
- nfpm pinned in mise; `just package` local repro → Tasks 1 + 3. ✓
- Apache-2.0 metadata → Task 1 (Cargo license; LICENSE already present; nfpm license field in Task 3). ✓
- Smoke test deb + structural rpm → Task 4. ✓
- Lint excludes for build outputs → Task 1. ✓

**2. Placeholder scan:** No TBD/"handle errors"/bare prose steps — every code step has full content. The `homepage` URL is the real repo (`houseabsolute/olivier`).

**3. Type/name consistency:** Artifact names are consistent everywhere — deb `olivier_<version>_amd64.deb`, rpm `olivier-<version>.x86_64.rpm`, tarball `olivier-<version>-linux-x64.tar.gz`. `scripts/stage-release.sh <bundle_dir> <version> <out_dir>` signature is identical in Task 2 tests, the `just package` recipe (Task 3), and the workflow (Task 4). `staging/` paths in `nfpm.yaml` match exactly what `stage-release.sh` writes. `VERSION` env var feeds `nfpm.yaml`'s `${VERSION}` in both the recipe and the workflow.
