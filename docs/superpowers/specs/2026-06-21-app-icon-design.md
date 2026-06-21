# App Icon — Design Spec

**Date:** 2026-06-21
**Status:** Approved in brainstorming — pending spec review

## Goal

Give Olivier a unique app icon: an original "birdsong in colour" motif evoking Olivier Messiaen, wired in as the Linux window icon, a `.desktop` launcher entry (for the app menu / dock), and the Android launcher icon. Replaces the stock Flutter scaffold icon.

## Decisions (from brainstorming)

- **Motif — original symbolic, "birdsong in colour."** A stylized gold songbird on a deep-indigo tile, with three coloured quarter-notes (red, gold, blue) rising from its beak. This nods to Messiaen's birdsong (he was an ornithologist-composer) and his colour synesthesia, and the notes read as "music". Chosen over a photo-likeness (and over the abstract stained-glass / bird-note variants).
- **Original artwork → license-clean.** The icon is created from scratch for this project; we release it under **CC0** (recorded in a short credits note). This satisfies the constraint that all artwork be CC0/CC-BY/CC-SA/CC-BY-SA, with no third-party attribution obligations.
- **Scope — all three:** Linux window icon, a `.desktop` install entry with themed icons, and the Android launcher icon.
- **Vector master.** A single SVG master is the source of truth; all raster sizes are generated from it (reproducibly) with `rsvg-convert`.

## The design (master)

The approved master, `assets/icon/olivier.svg` (viewBox `0 0 100 100`; colours: tile `#2e2a63`, bird `#f3c34e`, beak/wing `#e4933b`, notes `#e4572e`/`#f4b400`/`#56a3d9`):

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="512" height="512">
  <rect width="100" height="100" rx="22" fill="#2e2a63"/>
  <rect x="18" y="84" width="48" height="4" rx="2" fill="#6c63a8"/>
  <polygon points="28,64 8,57 28,77" fill="#f3c34e"/>
  <ellipse cx="46" cy="66" rx="24" ry="18" fill="#f3c34e"/>
  <circle cx="64" cy="51" r="14" fill="#f3c34e"/>
  <path d="M36 62 Q48 56 60 64 Q48 70 36 62 Z" fill="#e4933b" opacity="0.55"/>
  <polygon points="75,47 89,42 76,54" fill="#e4933b"/>
  <rect x="44" y="83" width="3" height="6" fill="#e4933b"/>
  <rect x="54" y="83" width="3" height="6" fill="#e4933b"/>
  <circle cx="67" cy="49" r="2.4" fill="#2e2a63"/>
  <g fill="#e4572e"><ellipse cx="80" cy="35" rx="4.4" ry="3.2" transform="rotate(-20 80 35)"/><rect x="83.2" y="23" width="1.8" height="12"/></g>
  <g fill="#f4b400"><ellipse cx="88" cy="27" rx="4.4" ry="3.2" transform="rotate(-20 88 27)"/><rect x="91.2" y="15" width="1.8" height="12"/></g>
  <g fill="#56a3d9"><ellipse cx="94" cy="16" rx="4.4" ry="3.2" transform="rotate(-20 94 16)"/><rect x="97.2" y="6" width="1.8" height="10"/></g>
</svg>
```

A second master, `assets/icon/olivier_foreground.svg`, holds **only** the bird + notes (no tile background, centred within the Android adaptive-icon safe zone) for the Android adaptive foreground.

## Architecture / approach

### 1. Raster pipeline (reproducible)

A script `scripts/gen-icons.sh` rasterises the master with `rsvg-convert` to the sizes each target needs, so the PNGs are regenerable and never hand-edited:
- hicolor theme sizes: 16, 24, 32, 48, 64, 128, 256, 512 → `assets/icon/hicolor/<n>x<n>/olivier.png`
- Linux window icon: a 256 px `assets/icon/olivier_256.png` (bundled as a Flutter asset)
- Android source: a 1024 px `assets/icon/olivier_1024.png` (+ a 1024 px foreground) for `flutter_launcher_icons`

The generated PNGs are committed (so a clean checkout has them without needing `rsvg-convert`); the script documents how to regenerate.

### 2. Linux window icon (always works, in-place or installed)

Declare `assets/icon/olivier_256.png` as a Flutter asset (`pubspec.yaml`). In `linux/runner/my_application.cc`, after the window is created in `my_application_activate`, load the bundled PNG and set it as the window icon:
- Resolve the executable directory from `/proc/self/exe`, then the asset lives at `<exe_dir>/data/flutter_assets/assets/icon/olivier_256.png`.
- `gdk_pixbuf_new_from_file()` → `gtk_window_set_icon()` (guarded: if the load fails, skip silently — no crash). Also call `gtk_window_set_default_icon()` so dialogs inherit it.
This works for `just run` (the bundle has `data/flutter_assets/`) and for an installed bundle.

### 3. `.desktop` install entry + themed icons

- `linux/olivier.desktop` (a desktop entry: `Name=Olivier`, `Exec=` the launcher, `Icon=olivier`, `Categories=AudioVideo;Audio;Player;`, `StartupWMClass=olivier`).
- `scripts/install-desktop.sh`: copies the hicolor PNGs to `~/.local/share/icons/hicolor/<n>x<n>/apps/olivier.png` and the scalable SVG to `…/scalable/apps/olivier.svg`, installs `olivier.desktop` to `~/.local/share/applications/`, and refreshes caches (`gtk-update-icon-cache`, `update-desktop-database`). It points `Exec=` at the built release bundle binary (and notes how to re-run after a rebuild).
- A `just install-desktop` recipe wraps the script for convenience.

### 4. Android launcher icon

- Add `flutter_launcher_icons` as a dev dependency; configure it in `pubspec.yaml` to read `assets/icon/olivier_1024.png` as the legacy icon, plus an adaptive icon (`adaptive_icon_background: "#2e2a63"`, `adaptive_icon_foreground: assets/icon/olivier_foreground_1024.png`).
- Run `flutter_launcher_icons` to regenerate the `android/app/src/main/res/mipmap-*` icons (replacing the stock `ic_launcher.png`), and commit the generated files.

## Licensing

The icon is original work for this project, released **CC0**. Add a short note (e.g. `assets/icon/README.md` or a `CREDITS` entry) recording the CC0 dedication. No third-party assets are used, so there are no attribution/share-alike obligations.

## Testing / verification

The icon is non-code art; there is no meaningful unit test. Verification is:
- `scripts/gen-icons.sh` runs and produces the expected PNG sizes (non-empty, correct dimensions via `file`/`identify`).
- `mise exec -- flutter analyze` and `just lint --all` stay green (the only Dart change is the `pubspec.yaml` asset declaration; the runner change is C++).
- `mise exec -- flutter build linux --debug` succeeds with the runner change.
- Manual smoke (`just run`): the window/title-bar/taskbar shows the birdsong icon. After `just install-desktop`, Olivier appears in the app menu with the icon. (Android: the generated mipmaps replace the stock icon — verified by inspecting the files; building an APK is out of scope.)

## Files touched

| File | Change |
|------|--------|
| `assets/icon/olivier.svg`, `olivier_foreground.svg` | vector masters (new) |
| `assets/icon/**` PNGs (hicolor sizes, `olivier_256.png`, `olivier_1024.png`, `olivier_foreground_1024.png`) | generated rasters (new) |
| `assets/icon/README.md` | CC0 credits note (new) |
| `scripts/gen-icons.sh` | rsvg-convert raster pipeline (new) |
| `scripts/install-desktop.sh`, `linux/olivier.desktop` | desktop install (new) |
| `Justfile` | `install-desktop` recipe |
| `pubspec.yaml` | declare the window-icon asset; `flutter_launcher_icons` dev dep + config |
| `linux/runner/my_application.cc` | load + set the GTK window icon |
| `android/app/src/main/res/mipmap-*` | regenerated launcher icons |

## Out of scope

System packaging (.deb/Flatpak/AppImage); macOS/iOS/Windows/web icons (those platforms aren't present); animating or theming the icon; a separate monochrome/symbolic icon variant.
