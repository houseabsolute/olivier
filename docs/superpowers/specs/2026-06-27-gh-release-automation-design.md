# GitHub Release Automation (DEB + RPM + Tarball) — Design

**Date:** 2026-06-27
**Status:** Approved

## Goal

On pushing a version tag (`vX.Y.Z`, optionally with a prerelease suffix like
`v0.0.1-rc1`), GitHub Actions builds the Linux release of Olivier and publishes a
GitHub Release with three attached artifacts: a `.deb`, an `.rpm`, and a
`.tar.gz` containing the runnable Linux bundle.

## Decisions (locked)

- **License:** Apache-2.0. A top-level `LICENSE` (verbatim canonical Apache-2.0 text)
  is already committed to `master`. The release work additionally sets the `license`
  field in `pubspec.yaml` and `rust/Cargo.toml` and uses SPDX `Apache-2.0` in package
  metadata.
- **Packaging tool:** [nfpm](https://nfpm.goreleaser.com/) — one YAML config emits
  both `.deb` and `.rpm` on the Ubuntu runner (no `rpmbuild`/Fedora needed).
- **Release mode:** auto-publish; a tag with a prerelease suffix (`-rc1`, `-beta`, …)
  marks the GitHub Release as a prerelease.
- **RPM verification:** structural only (`rpm -qp --info/--requires/--list`); no
  Fedora install-test.
- **nfpm provisioning:** pinned in `mise.toml` so CI and local `just package` use
  the same version.

## Background (verified from the repo)

- App: binary `olivier`, app id `org.urth.olivier`, maintainer Dave Rolsky
  <autarch@urth.org>.
- Release build: `mise exec -- flutter build linux --release` →
  `build/linux/x64/release/bundle/` (executable `olivier`, `lib/*.so`, `data/`).
  RPATH is `$ORIGIN/lib`; the bundle is self-contained except for system libs.
- Build environment: a Rust toolchain on PATH (cargokit invokes `cargo` during the
  Flutter build), mise (Flutter 3.44.2, ninja 1.13.2), and apt build deps:
  `clang cmake pkg-config libgtk-3-dev liblzma-dev libstdc++-14-dev libmpv-dev`.
- Runtime deps NOT in the bundle: **libmpv** (dlopened by media_kit as
  `libmpv.so.2` → must be a declared package dependency) and GTK3 (linked).
- Existing CI (`.github/workflows/ci.yml`) sets up the toolchain with
  `jdx/mise-action@v2` + `dtolnay/rust-toolchain@stable` + the apt list above; the
  release workflow reuses these steps. (`xvfb` is not needed — no integration tests
  in the release job.)
- Desktop assets already exist: `linux/org.urth.olivier.desktop` (Exec=olivier) and
  committed hicolor PNG icons (16–512) + an SVG, installed today by
  `scripts/install-desktop.sh` (the authoritative source for exact icon paths).

## Architecture

Thin workflow + a reviewable, locally-runnable shell script + an nfpm config. The
file layout lives in ONE place (the staging script) and is consumed by both the
tarball and the packages.

### Component 1 — `scripts/stage-release.sh`

Inputs (env or args): the built bundle dir (`build/linux/x64/release/bundle`), the
version string, and an output dir. Responsibilities:

1. Build a `staging/` tree mirroring the install layout:
   - `staging/usr/lib/olivier/` ← the entire bundle (exe + `lib/` + `data/`)
   - `staging/usr/share/applications/org.urth.olivier.desktop` ← committed `.desktop`
   - `staging/usr/share/icons/hicolor/<size>/apps/olivier.png` + `scalable/apps/olivier.svg`
     ← the same committed icons `scripts/install-desktop.sh` uses (exact paths taken
     from that script)
   - `staging/usr/share/doc/olivier/LICENSE` and `.../README` (run notes incl. the
     libmpv requirement)
   - `staging/usr/bin/olivier` → symlink to `/usr/lib/olivier/olivier`
2. Produce `dist/olivier-<version>-linux-x64.tar.gz` whose top folder
   `olivier-<version>-linux-x64/` contains the bundle + `.desktop` + icons +
   `LICENSE` + `README` (runnable via `./olivier`; no bespoke installer).

Single responsibility: turn "built bundle + version" into "install tree + tarball."
shellcheck/shfmt-clean (the repo lints shell). Deterministic; no network.

### Component 2 — `packaging/nfpm.yaml`

Declares the `.deb`/`.rpm` from `staging/`. Key fields:

- `name: olivier`, `arch: amd64`, `version: ${VERSION}` (env-expanded; nfpm handles
  deb/rpm prerelease formatting, e.g. rpm `~rc1`), `maintainer`, `homepage`,
  `license: Apache-2.0`, `section: sound`, a real `description`.
- `contents:` map the staged subtrees (`type: tree` for `/usr/lib/olivier`,
  `/usr/share/icons/hicolor`; individual entries for the `.desktop`, license/readme)
  and a `type: symlink` entry for `/usr/bin/olivier`.
- Dependency overrides (libmpv is dlopened, so nothing auto-detects it):
  - `overrides.deb.depends: ["libmpv2 | libmpv1", "libgtk-3-0 | libgtk-3-0t64"]`
  - `overrides.rpm.depends: ["mpv-libs", "gtk3"]`

### Component 3 — `.github/workflows/release.yml`

`on: push: tags: ['v*']` **and** `workflow_dispatch` (a `version` input, default like
`0.0.0-dev`, so the pipeline can be dry-run before the first real tag).
`permissions: contents: write`. One `ubuntu-latest` job:

1. `actions/checkout@v4`
2. `dtolnay/rust-toolchain@stable`
3. `jdx/mise-action@v2` (provides Flutter, ninja, **nfpm**)
4. apt build deps (the ci.yml list, minus xvfb)
5. `mise exec -- flutter pub get`
6. Resolve version: tag → `VERSION=${GITHUB_REF_NAME#v}`; dispatch → `inputs.version`.
   `IS_PRERELEASE = VERSION contains '-'`.
7. `mise exec -- flutter build linux --release --build-name=${VERSION%%-*} --build-number=${{ github.run_number }}`
8. `scripts/stage-release.sh` → `staging/` + tarball
9. `mise exec -- nfpm pkg -p deb -f packaging/nfpm.yaml -t dist/` and `-p rpm` (with
   `VERSION` exported)
10. Smoke test: `sudo apt-get install ./dist/olivier_*.deb`; assert `/usr/bin/olivier`
    resolves to the bundle exe and `ldd /usr/lib/olivier/olivier` reports no missing
    **linked** libs (libmpv is dlopened, so its absence here is expected); structurally
    validate the rpm with `rpm -qp --info --requires --list dist/olivier-*.rpm`.
11. `softprops/action-gh-release` — attach the `.deb`, `.rpm`, `.tar.gz`;
    `prerelease: ${IS_PRERELEASE}`.

### Component 4 — `Justfile` `package` recipe

`just package [version]` runs the release build → `stage-release.sh` → `nfpm pkg`
(deb+rpm) locally against the same script + config, so packaging is testable without
pushing a tag. Default version e.g. `0.0.0-dev`.

## Versioning

- The git tag is the source of truth; `pubspec.yaml` is NOT committed-back (YAGNI —
  the app has no About screen). The built binary's version metadata is stamped via
  `--build-name`/`--build-number` only.
- A prerelease suffix on the tag flows to nfpm (correct deb/rpm formatting) and to the
  GitHub Release `prerelease` flag.

## Error handling

- `stage-release.sh` uses `set -euo pipefail`; fails loudly if the bundle dir or an
  expected asset is missing.
- The workflow fails the job (and creates no release) if the build, staging, nfpm, or
  smoke-test steps fail — partial/empty artifacts are never published.

## Testing

No unit tests (CI/packaging logic). Validation:
1. `just package 0.0.0-dev` locally → inspect all three artifacts (`dpkg-deb -c`,
   `rpm -qp --list`, `tar tzf`).
2. The in-workflow smoke test (deb install + ldd; rpm structural check).
3. A `workflow_dispatch` dry-run on the branch before the first real `v*` tag.

## New / changed files

- Already on `master`: `LICENSE` (Apache-2.0).
- Create: `scripts/stage-release.sh`, `packaging/nfpm.yaml`,
  `packaging/README.tarball.md`, `.github/workflows/release.yml`
- Modify: `mise.toml` (pin nfpm), `Justfile` (add `package`), `pubspec.yaml`
  (real `description` + `license: Apache-2.0`), `rust/Cargo.toml` (`license`),
  `precious.toml` if needed (exclude `staging/`, `dist/` from lint globs)
