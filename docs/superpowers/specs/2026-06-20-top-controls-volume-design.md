# Top Control Bar + Persistent Volume — Design

**Status:** approved, ready for implementation plan
**Date:** 2026-06-20

## Goal

Replace the "Olivier" title in the top app bar with playback controls: previous / play-pause / next,
a volume slider, and the existing settings button. The transport moves up from the bottom
now-playing bar; volume is net-new and persists across restarts. The bottom now-playing bar keeps
the cover, bilingual title/artist, and seek slider (its transport buttons are removed).

## Audio handler (`lib/audio/audio_handler.dart`)

`OlivierAudioHandler` wraps a just_audio `AudioPlayer`. Add volume passthroughs:

```dart
  /// Set output volume (0.0–1.0).
  Future<void> setVolume(double v) => player.setVolume(v);
  Stream<double> get volumeStream => player.volumeStream;
```

(`player.setVolume` / `player.volumeStream` already exist in just_audio.)

## Volume state + persistence (`lib/state/volume.dart`)

A seam + an `AsyncNotifier<double>` that loads the saved volume, applies it to the player, and
saves changes — mirroring `layoutSettingsProvider`'s use of the `getSettingFnProvider` /
`setSettingFnProvider` seams.

```dart
const volumeKey = 'volume';
const defaultVolume = 1.0;

/// Parse a stored volume string; clamp to [0,1]; [defaultVolume] on bad/missing input.
double parseVolume(String? s) {
  final v = s == null ? null : double.tryParse(s);
  if (v == null) return defaultVolume;
  return v.clamp(0.0, 1.0);
}

/// Applies a volume to the player. Seam so [VolumeNotifier] is testable without
/// the live audio handler; defaults to the global handler.
typedef SetVolumeFn = Future<void> Function(double v);
final setVolumeFnProvider = Provider<SetVolumeFn>((ref) => audioHandler.setVolume);

class VolumeNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final v = parseVolume(await ref.read(getSettingFnProvider)(volumeKey));
    await ref.read(setVolumeFnProvider)(v); // apply the saved level on startup
    return v;
  }

  /// Apply a new volume immediately; persist only when [persist] (on slider release),
  /// so dragging doesn't spam the settings write.
  Future<void> setVolume(double v, {bool persist = false}) async {
    final clamped = v.clamp(0.0, 1.0);
    state = AsyncData(clamped);
    await ref.read(setVolumeFnProvider)(clamped);
    if (persist) {
      await ref.read(setSettingFnProvider)(volumeKey, clamped.toString());
    }
  }
}

final volumeProvider =
    AsyncNotifierProvider<VolumeNotifier, double>(VolumeNotifier.new);
```

`setVolumeFnProvider` references the global `audioHandler` (import `package:olivier/main.dart show
audioHandler`, as other files do); tests override it.

## Widgets

### `TransportControls` (`lib/widgets/transport_controls.dart`)

Extract the existing transport block from `now_playing_bar.dart` (prev `IconButton` →
`audioHandler.skipToPrevious()`, the `StreamBuilder<PlayerState>` play/pause that shows a spinner
while loading and toggles `pause()`/`play()`, next → `audioHandler.skipToNext()`). Takes the
handler:

```dart
class TransportControls extends StatelessWidget {
  const TransportControls({super.key, required this.audioHandler});
  final OlivierAudioHandler audioHandler;
  // ...Row of the three controls (same code that lives in now_playing_bar today)...
}
```

### `VolumeControl` (`lib/widgets/volume_control.dart`)

A `ConsumerWidget`: a volume icon (`volume_off` at 0, `volume_down` < 0.5, else `volume_up`) +
a compact `Slider` (~120px) bound to `volumeProvider`:

```dart
final vol = ref.watch(volumeProvider).valueOrNull ?? defaultVolume;
// Slider(value: vol, min: 0, max: 1,
//   onChanged: (v) => ref.read(volumeProvider.notifier).setVolume(v),
//   onChangeEnd: (v) => ref.read(volumeProvider.notifier).setVolume(v, persist: true)),
```

`onChanged` gives live feedback (apply, no save); `onChangeEnd` persists.

### `TopControls` (`lib/widgets/top_controls.dart`)

The AppBar title content: `Row(children: [TransportControls(audioHandler: audioHandler),
const Spacer(), const VolumeControl()])`. Takes the handler.

## Top bar (`lib/catalog/browser_page.dart`)

Add an injectable `topControls` param (mirroring the existing `nowPlaying`), and use it as the
AppBar title:

```dart
class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key, this.nowPlaying, this.topControls});
  final Widget? nowPlaying;
  /// The top control bar (transport + volume). Injectable so the page is
  /// widget-testable without the live global audioHandler. Defaults to the real bar.
  final Widget? topControls;
  // ...
}
```
```dart
      appBar: AppBar(
        title: widget.topControls ?? TopControls(audioHandler: audioHandler),
        actions: [ /* the existing Settings IconButton, unchanged */ ],
        bottom: scan.scanning ? _scanProgressBar(scan) : null,
      ),
```

The `'Olivier'` `Text` title is removed. Settings + the scan-progress `bottom` are unchanged.

## Bottom now-playing bar (`lib/widgets/now_playing_bar.dart`)

Remove the three transport `IconButton`s / the play-pause `StreamBuilder` (and the trailing
`SizedBox(width: 8)` that separated them from the title) — they now live in `TransportControls`.
Keep the cover, the bilingual title/artist `StreamBuilder`, and the seek slider + position. The
`PlayerState`/`PositionData` plumbing the bar still needs (for the seek slider) stays.

## Testing

### Dart (host-VM)

- `parseVolume` unit: good value → clamped; null/garbage → `defaultVolume`; out-of-range → clamped.
- `volumeProvider`: override `getSettingFnProvider` (returns "0.4"), `setVolumeFnProvider` (recorder),
  `setSettingFnProvider` (recorder). Assert `build()` returns 0.4 and applied 0.4 via the seam;
  `setVolume(0.7, persist: true)` applies 0.7 and saves `'0.7'`; `setVolume(0.6)` (no persist)
  applies but does not save.
- `VolumeControl` widget: override the seams; pump it; assert the `Slider`'s value reflects the
  provider, dragging calls `setVolume`, and the icon reflects the level (e.g. `volume_off` at 0).
- `browser_page` tests (`browser_page_layout_test`, `browser_page_resize_test`): pass
  `topControls: const SizedBox.shrink()` so the AppBar doesn't build the real `TopControls`
  (uninitialized global). Update both existing tests accordingly.
- A check that the **bottom** now-playing bar no longer renders the transport icons (the
  `skip_previous`/`skip_next` icons are gone from `NowPlayingBar`), so the move is verified.

`TransportControls` itself is a mechanical extraction of currently-untested code (its play/pause
`StreamBuilder` needs a live `AudioPlayer`), so it gets no dedicated unit test; the bottom-bar
"transport removed" check + the existing suite cover the move.

## Touched files

- `lib/audio/audio_handler.dart` — `setVolume` + `volumeStream`.
- `lib/state/volume.dart` — `parseVolume`, `setVolumeFnProvider`, `volumeProvider`.
- `lib/widgets/transport_controls.dart` — extracted transport.
- `lib/widgets/volume_control.dart` — volume icon + slider.
- `lib/widgets/top_controls.dart` — transport + volume row.
- `lib/catalog/browser_page.dart` — `topControls` param + AppBar title.
- `lib/widgets/now_playing_bar.dart` — remove transport.
- `test/…` — `parseVolume` / `volumeProvider` / `VolumeControl` tests; updated browser-page + now-playing tests.

## Non-goals

- No mute toggle / keyboard volume shortcuts (just the slider).
- The now-playing bar's seek/position behavior is unchanged.
