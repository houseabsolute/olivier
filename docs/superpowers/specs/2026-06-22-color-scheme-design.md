# Olivier Color Scheme — Design Spec

**Date:** 2026-06-22
**Status:** Approved in brainstorming — pending spec review

## Goal

Replace Flutter's default (purple) Material 3 theme with an intentional Olivier theme: a faint-indigo off-white background and dark-grey text, with accent colors drawn from the app icon's three musical notes, used only for highlights. Blue (the icon's high note) is the single general-highlight accent; red (the low note) marks the now-playing track; gold (the middle note) is held in reserve.

## Background

The app currently sets **no theme at all** — `MaterialApp` (`lib/main.dart:195`) has no `theme:` argument, so it runs on Flutter 3.44.2's stock Material 3 light default (a purple-ish baseline `ColorScheme`). Almost every widget already reads `Theme.of(context).colorScheme` / `.textTheme`, so introducing one central `ColorScheme` re-tints the app automatically. The app icon (`assets/icon/olivier.svg`) is a gold songbird on a deep-indigo tile (`#2e2a63`) with three rising quarter-notes: **red `#e4572e`**, **gold `#f4b400`**, **blue `#56a3d9`**.

## Decisions (from brainstorming)

- **Accent strategy C:** one base accent (blue) for general highlights, plus red reserved for the actively-playing track. (Not single-accent; not the full role-coded trio.)
- **Neutral base: faint indigo** — backgrounds/surfaces carry a whisper of the icon's indigo tile. Not warm tan/cream, not pure white.
- **Blue drives all general highlights** via `ColorScheme.primary`: selected rows, seek/volume sliders, clickable MBID links, text-field focus rings, action buttons (kept as accent fills), progress spinners, the queue drop-target border, the resize-handle hover line.
- **Red appears in exactly one place:** the queue's now-playing row (`currentIndex`), via `ColorScheme.tertiary` / `tertiaryContainer`. The now-playing bar stays neutral + blue (no red).
- **Gold is unused in v1** (reserved for a possible future third role).
- **Light theme only.** Dark mode / theme switching is out of scope.

## Palette (exact)

| Role | Hex | `ColorScheme` slot |
|------|-----|--------------------|
| App background | `#F5F6FB` | `surface` |
| Neutral/elevated surfaces (toolbar, column headers, queue header, now-playing bar, cover placeholder) | `#E8EAF3` | `surfaceContainerHighest` (and the nearby `surfaceContainer*` family) |
| Primary text | `#2B2D38` | `onSurface` |
| Muted/secondary text | `#64667B` | `onSurfaceVariant` |
| Dividers / outlines | `#DDDFEB` | `outlineVariant` |
| Blue accent | `#56A3D9` | `primary` (with `onPrimary` `#FFFFFF`) |
| Blue selection tint | `#D7E9F7` | `primaryContainer` (with `onPrimaryContainer` `#15506F`) |
| Red now-playing | `#E4572E` | `tertiary` (with `onTertiary` `#FFFFFF`) |
| Red playing-row tint | `#F8E0D6` | `tertiaryContainer` (with `onTertiaryContainer` `#7C2E16`) |
| Error states (settings) | `#BA1A1A` | `error` (with `onError` `#FFFFFF`) |
| Gold (reserved) | `#F4B400` | — (unassigned in v1) |

Contrast check: `onSurface #2B2D38` and `onSurfaceVariant #64667B` on `surface #F5F6FB` both clear 4.5:1; the container tints carry their darker `on*` text from the table.

## Architecture

Single source of truth = the central `ColorScheme`; almost all widgets already consume it, so there is no new state and no persistence (the theme is static).

- **New `lib/theme.dart`** exporting the Olivier `ThemeData` (e.g. `ThemeData olivierTheme()` / a top-level `final`). Build it from `ColorScheme.fromSeed(seedColor: Color(0xFF56A3D9), brightness: Brightness.light)` then `.copyWith(...)` overriding the exact roles in the palette table (`surface`, `onSurface`, `onSurfaceVariant`, `outlineVariant`, `primary`/`onPrimary`, `primaryContainer`/`onPrimaryContainer`, `tertiary`/`onTertiary`, `tertiaryContainer`/`onTertiaryContainer`, the `surfaceContainer*` levels the app reads, and `error`/`onError`). Using `fromSeed` yields a complete, valid scheme; `copyWith` pins the colors that matter so they are exact rather than seed-derived guesses. Wire it once at `lib/main.dart`'s `MaterialApp(theme: …)`.
- **Neutralize Material 3 elevation tint** so neutral surfaces don't pick up a blue overlay. The now-playing bar is a `Material` at `elevation: 8` (`now_playing_bar.dart:36`); at elevation, M3 applies a `surfaceTint` (primary-derived) overlay that would tint it blue. Keep elevated neutral surfaces at the literal `#E8EAF3` — set the scheme's `surfaceTint` to a neutral value (or give the elevated `Material`s an explicit `color:` plus `surfaceTintColor: Colors.transparent`). The chosen mechanism is an implementation detail for the plan; the requirement is that the now-playing bar and any elevated surface render the neutral surface color, not a blue-tinted variant.
- **One targeted widget change:** the queue now-playing row (`queue_panel.dart:337-339`) switches its fill from `scheme.primaryContainer` to `scheme.tertiaryContainer`, and any explicit text color on that row uses `onTertiaryContainer`. This is the sole place red is introduced.
- **De-hardcode the literal colors** so they follow the theme: `Colors.grey` → `colorScheme.onSurfaceVariant` (`settings_page.dart:31,111,177`, `import_log_page.dart:65`); `Colors.red` → `colorScheme.error` (`settings_page.dart:93,98,161,166`). Leave the two intentional `Colors.transparent` (the resize hit-area at `resizable_split.dart:103`; the non-current queue-row fill at `queue_panel.dart:339`).

## Edge cases

- Tests across `test/` wrap widgets in a bare `MaterialApp` (no `theme:`), so they keep rendering on Flutter's default theme and are unaffected by this change.
- The blue accent on `FilledButton`s, sliders, and spinners is intentional (these are "highlights"), not a regression of the "accent only for highlights" intent — large surfaces (backgrounds, headers, cover placeholders, the now-playing bar) stay neutral.
- The settings `error` red and the now-playing `tertiary` red are different reds in different contexts (error feedback vs. playback state); both are intended.

## Testing

- **Theme test:** pump `MaterialApp(theme: olivierTheme())` and assert `colorScheme.primary == Color(0xFF56A3D9)`, `colorScheme.tertiary == Color(0xFFE4572E)`, and `colorScheme.surface == Color(0xFFF5F6FB)`.
- **Queue test:** the now-playing (`currentIndex`) queue row uses `tertiaryContainer`, not `primaryContainer`.
- **Manual:** launch the app and confirm the faint-indigo off-white background, dark-grey text, blue selection/sliders/links/buttons, the red queue now-playing row, and a neutral (non-blue-tinted) now-playing bar at elevation.

## Out of scope

- Dark mode and theme switching; user-customizable colors; restyling the app icon; assigning gold a role; any layout/spacing/typography change beyond color.
