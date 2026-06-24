# Transport + Volume Keyboard Shortcuts — Design Spec

**Date:** 2026-06-24
**Status:** Approved in brainstorming — pending spec review

## Goal

Give Olivier in-app keyboard shortcuts for the common transport and volume
actions — next/previous track, seek forward/back, and volume up/down — alongside
the existing `Space` (play/pause) and `Ctrl-Q` (quit). Keyboard control should
work without reaching for the mouse, and must never hijack keys while the user is
typing in the search field.

## Background

The app binds keyboard shortcuts with the `CallbackShortcuts` widget plus a root
`Focus.onKeyEvent` handler — *not* the `Shortcuts`+`Actions`+`Intent` system.

- `lib/main.dart` `OlivierApp` (a `StatelessWidget`, lines ~209–249): a root
  `CallbackShortcuts` binds `Ctrl-Q` → `onQuit ?? SystemNavigator.pop()`; its
  child `Focus(autofocus: true)` has an `onKeyEvent` that toggles play/pause on
  `Space` when `!_textInputHasFocus()`. `OlivierApp` takes injectable
  `onQuit` / `onTogglePlayPause` callbacks (defaulting to the real wiring) so the
  bindings are widget-testable without a live audio service.
- `_textInputHasFocus()` (main.dart ~244): true when `FocusManager.instance
  .primaryFocus` is an `EditableText` (or has an `EditableTextState` ancestor).
- Transport API: the global `audioHandler` (`OlivierAudioHandler`,
  `lib/audio/audio_handler.dart`) exposes `togglePlayPause()`, `skipToNext()`,
  `skipToPrevious()`, and `seek(Duration)` (absolute). Current position/duration
  come from `player.position` / `player.duration` (just_audio).
- Volume: `volumeProvider` (`AsyncNotifierProvider<VolumeNotifier, double>`,
  `lib/state/volume.dart`), range `0.0–1.0`, `defaultVolume = 1.0`.
  `VolumeNotifier.setVolume(double v, {bool persist = false})` applies
  immediately and persists to settings only when `persist` is true. Mute = 0
  (no separate API).
- The existing shortcut tests (`test/play_pause_shortcut_test.dart`,
  `test/ctrl_q_test.dart`) build `OlivierApp(...)` **without** a `ProviderScope`,
  using injected callbacks + an injected `home`. The new design must keep
  `OlivierApp` provider-agnostic so these tests are not forced to add a scope.

OS media keys (play/next/previous) already work at the desktop level via
`audio_service` / MPRIS; this feature adds *in-app* keyboard shortcuts and does
not touch that.

## Bindings

`Space` (play/pause) and `Ctrl-Q` (quit) are unchanged. New:

| Keys | Action |
| --- | --- |
| `Ctrl/Cmd + →` | Next track |
| `Ctrl/Cmd + ←` | Previous track |
| `Ctrl/Cmd + ↑` | Volume +5% |
| `Ctrl/Cmd + ↓` | Volume −5% |
| `Shift + →` | Seek +10s |
| `Shift + ←` | Seek −10s |

Both Ctrl and Cmd are accepted (`HardwareKeyboard.instance.isControlPressed ||
isMetaPressed`), matching the existing Ctrl-F/Cmd-F search binding.

Step constants `volumeStep = 0.05` and `seekStep = Duration(seconds: 10)` live in
`lib/main.dart` (both are referenced there — `seekStep` in `OlivierApp`'s seek
defaults, `volumeStep` in the `main()` volume wiring).

Chord matching is **exclusive**: the Ctrl/Cmd chords require Ctrl/Cmd held and
Shift *not* held, and the Shift chords require Shift held and Ctrl/Cmd *not*
held — so a combined `Ctrl+Shift+→` triggers neither.

## Architecture

Small, isolated, independently testable units:

### 1. `clampSeek` — pure helper (`lib/audio/audio_handler.dart`)

```
Duration clampSeek(Duration position, Duration delta, Duration? duration)
```

Returns `(position + delta)` clamped to `[Duration.zero, duration]`; when
`duration` is null, only the lower bound (zero) is applied. Pulled out as a pure
top-level function so the clamping is unit-testable without the audio engine.

### 2. `OlivierAudioHandler.seekBy(Duration delta)` (`lib/audio/audio_handler.dart`)

Relative seek: `await seek(clampSeek(player.position, delta, player.duration))`.

### 3. `VolumeNotifier.nudge(double delta)` (`lib/state/volume.dart`)

```
final current = state.value ?? defaultVolume;
await setVolume((current + delta).clamp(0.0, 1.0), persist: true);
```

Reads the current value via `state.value` (nullable — this repo's Riverpod has
no `valueOrNull`). Persists on every call; because the handler is KeyDown-only,
that is one settings write per physical press.

### 4. Root key handler (`lib/main.dart`)

Extend `OlivierApp`'s `Focus.onKeyEvent`. On a `KeyDownEvent`, when
`!_textInputHasFocus()`, match the chords above using `HardwareKeyboard.instance`
modifier state and invoke the matching callback, returning
`KeyEventResult.handled`; otherwise `ignored`.

New injectable `VoidCallback?` params on `OlivierApp`: `onNextTrack`,
`onPreviousTrack`, `onSeekForward`, `onSeekBackward`, `onVolumeUp`,
`onVolumeDown`.

- Track/seek callbacks default to the global `audioHandler`
  (`onNextTrack ?? () => audioHandler.skipToNext()`, etc.), mirroring the
  existing `onTogglePlayPause` default.
- The two **volume** callbacks have **no** global default (volume needs the
  provider, which `OlivierApp` — a `StatelessWidget` — can't read). When null
  the chord falls through to `ignored`. They are injected in production (next).

### 5. Production volume wiring (`lib/main.dart`, `main()`)

In `runApp(ProviderScope(... child: const OlivierApp()))`, wrap `OlivierApp` in a
`Consumer` (it is under the `ProviderScope`, so `ref` is available) and inject:

```
onVolumeUp: () => ref.read(volumeProvider.notifier).nudge(volumeStep),
onVolumeDown: () => ref.read(volumeProvider.notifier).nudge(-volumeStep),
```

`OlivierApp` stays a `StatelessWidget`; the existing scope-free tests are
untouched.

## Focus / suppression rule

Every new chord is gated by the same `!_textInputHasFocus()` check as `Space`.
This is deliberate: while the search field is focused it preserves in-field
`Ctrl+←/→` (word jump) and `Shift+←/→` (text selection) instead of stealing them
for transport. `Ctrl-Q` remains ungated (quitting while typing is fine).

## Edge cases

- **Bounds:** volume and seek clamp at their limits; a press past the limit is a
  harmless no-op (the key is still consumed).
- **No track / no duration:** backward seek clamps to 0; forward seek is allowed
  (just_audio clamps internally).
- **Empty queue:** `skipToNext()` / `skipToPrevious()` are just_audio no-ops.
- **KeyDown only:** holding a key does not auto-repeat (one action per press),
  matching the chosen discrete-step model and the existing `Space` handling.
- **Ctrl vs Cmd:** both modifiers trigger the track/volume chords.

## Testing

- **`clampSeek`** (pure unit tests): below-zero → zero; past-duration →
  duration; null-duration → no upper clamp; a normal in-range value.
- **`VolumeNotifier.nudge`** (extend `test/volume_test.dart`, reuse its
  `getSettingFn`/`setSettingFn`/`setVolumeFn` seam overrides): nudge up and down
  changes + persists; clamps at 1.0 (up at max is a no-op) and 0.0 (down at min);
  starts from `defaultVolume` when unset.
- **Widget tests** (new `test/media_shortcuts_test.dart`, extending the
  `play_pause_shortcut_test.dart` pattern — build `OlivierApp(...)` with spy
  callbacks + an injected `home`, send the chord via
  `sendKeyDownEvent`/`sendKeyEvent`/`sendKeyUpEvent`): each of the six chords
  invokes its callback exactly once; and every chord is suppressed (callback not
  called) while a `TextField` holds focus.

## Out of scope (YAGNI)

- Hold-to-repeat seek/volume.
- A mute toggle.
- A shortcuts help / cheat-sheet overlay.
- OS media keys (already handled via `audio_service` / MPRIS).
