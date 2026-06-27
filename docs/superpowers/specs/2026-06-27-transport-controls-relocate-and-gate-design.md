# Transport Controls: Relocate to Now-Playing Bar + Enable/Disable Gating

**Date:** 2026-06-27
**Status:** Approved

## Goal

Move the prev/play/next transport buttons out of the top app bar and back into
the bottom now-playing bar (to the right of the now-playing title/artist), and
grey out each button when it cannot do anything useful — which also fixes the
bug where clicking Play on an empty queue flips the icon to Pause.

## Background (current state)

- **Top bar** (`AppBar.title` = `lib/widgets/top_controls.dart` `TopControls`):
  `[ TransportControls (prev/play/next) ] [ SearchField (expanded, centered) ] [ VolumeControl ]`.
  `AppBar.actions` (in `lib/catalog/browser_page.dart`) = `[ Playlists ] [ Settings ]`.
- **Bottom bar** (`Scaffold.bottomNavigationBar` = `lib/widgets/now_playing_bar.dart`
  `NowPlayingBar`): a single Row `[ Title/Artist (flex 2) ] [ seek slider + time (flex 3) ]`.
  No transport buttons today.
- `lib/widgets/transport_controls.dart` `TransportControls` is a `StatelessWidget`
  taking `OlivierAudioHandler`; it reads `audioHandler.player.playerStateStream`
  for the play/pause icon and the loading spinner. Prev/Next currently always
  enabled; Play always enabled.
- `OlivierAudioHandler.player` (`lib/audio/audio_handler.dart`) is a hardcoded,
  non-injectable real `just_audio` `AudioPlayer` that cannot run under headless
  `flutter test`.

## Behavior

| Button | Action | Enabled when |
|--------|--------|--------------|
| ⏮ Prev | seek the current track to `Duration.zero` (restart). NEVER changes track. | a track is loaded (queue non-empty) |
| ⏯ Play/Pause | toggle play/pause | a track is loaded (queue non-empty) |
| ⏭ Next | skip to the next track | there is a next track (not the last; queue non-empty) |

- A disabled button renders with `onPressed: null` so Material greys it out and
  ignores taps. This is what fixes the empty-queue glitch: with the queue empty
  the Play button is disabled and cannot flip to the Pause icon.
- While the player is loading/buffering, the play/pause slot shows the existing
  `CircularProgressIndicator` (unchanged).
- "A track is loaded" ≡ the player's sequence is non-empty (`currentIndex != null`).
  After the queue is cleared, `clear()` empties the player and `currentIndex`
  becomes null, so all three buttons disable.

### Out of scope / unchanged

- The `Ctrl/Cmd+←` keyboard shortcut continues to **skip to the previous track**
  (`audioHandler.skipToPrevious()` → `player.seekToPrevious()`). Only the on-screen
  Prev *button* restarts the current track. (`Ctrl/Cmd+→` next, volume, and seek
  shortcuts are unchanged.)
- `OlivierAudioHandler.skipToPrevious` / `skipToNext` are not modified.
- Volume control, search, Playlists, and Settings are unchanged (search simply
  reflows to fill the space the transport vacated in the top bar).

## Architecture

The enable/disable rules and the icon choice are extracted into a **pure
function** so they are unit-testable without the un-fakeable real player. The
rendering is a **pure view widget**. The existing `TransportControls` becomes
thin stream-wiring glue.

### Unit 1 — pure decision logic (`lib/widgets/transport_controls.dart`)

```dart
@immutable
class TransportState {
  const TransportState({
    required this.hasCurrent,
    required this.hasNext,
    required this.playing,
    required this.isLoading,
  });
  final bool hasCurrent; // a track is loaded (sequence non-empty)
  final bool hasNext;    // there is a next track
  final bool playing;    // player.playing
  final bool isLoading;  // processingState == loading || buffering
}

@immutable
class TransportButtons {
  const TransportButtons({
    required this.prevEnabled,
    required this.playEnabled,
    required this.nextEnabled,
    required this.showSpinner,
    required this.showPauseIcon,
  });
  final bool prevEnabled;
  final bool playEnabled;
  final bool nextEnabled;
  final bool showSpinner;   // play/pause slot shows the spinner instead of an icon
  final bool showPauseIcon; // icon is pause (true) vs play (false)
}

TransportButtons resolveTransport(TransportState s) => TransportButtons(
      prevEnabled: s.hasCurrent,
      playEnabled: s.hasCurrent,
      nextEnabled: s.hasNext,
      showSpinner: s.isLoading,
      showPauseIcon: s.playing,
    );
```

### Unit 2 — pure view widget (`lib/widgets/transport_controls.dart`)

`TransportControlsView extends StatelessWidget` with fields:
`TransportButtons buttons`, `VoidCallback onPrev`, `VoidCallback onPlayPause`,
`VoidCallback onNext`. Renders a `Row(mainAxisSize: min)` of:

- Prev `IconButton(Icons.skip_previous, tooltip: 'Restart track', onPressed: buttons.prevEnabled ? onPrev : null)`
- Play/pause slot: if `buttons.showSpinner`, the existing 24×24 spinner Padding;
  else `IconButton(icon: Icon(buttons.showPauseIcon ? Icons.pause : Icons.play_arrow), tooltip: buttons.showPauseIcon ? 'Pause' : 'Play', onPressed: buttons.playEnabled ? onPlayPause : null)`
- Next `IconButton(Icons.skip_next, tooltip: 'Next', onPressed: buttons.nextEnabled ? onNext : null)`

No player/stream access — trivially widget-testable.

### Unit 3 — stream glue (`TransportControls`, rewired)

`TransportControls` keeps its `OlivierAudioHandler` constructor. It combines
`player.sequenceStateStream` and `player.playerStateStream` (via rxdart
`Rx.combineLatest2`, already a dependency) and, on each emission, builds a
`TransportState`:

- `hasCurrent = player.sequence.isNotEmpty` (equivalently `player.currentIndex != null`)
- `hasNext = player.hasNext`
- `playing = playerState.playing`
- `isLoading = processingState == loading || buffering`

then renders `TransportControlsView(buttons: resolveTransport(state), ...)` with:

- `onPrev: () => audioHandler.seek(Duration.zero)`
- `onPlayPause: () => playing ? audioHandler.pause() : audioHandler.play()`
- `onNext: () => audioHandler.skipToNext()`

This layer has no branching logic beyond mapping streams to the value object.

### Layout changes

- `lib/widgets/now_playing_bar.dart`: insert `TransportControls(audioHandler: audioHandler)`
  into the Row between the Title/Artist `Expanded(flex: 2)` and the seek
  `Expanded(flex: 3)`, with `SizedBox(width: 8)` spacers on each side. The bar
  height (`bilingualRowExtent(context, 80)`) already accommodates ~48px buttons.
- `lib/widgets/top_controls.dart`: remove `TransportControls` (and its trailing
  `SizedBox`). Result: `Row([ Expanded(Center(SearchField)), SizedBox(8), VolumeControl ])`.

## Testing

- **`test/widgets/transport_resolve_test.dart`** (new, host-VM, pure): table of
  `resolveTransport` cases —
  - empty queue (`hasCurrent:false, hasNext:false`) → all `*Enabled` false.
  - single track / first of many (`hasCurrent:true, hasNext:false`) → prev+play
    enabled, next disabled.
  - middle/first-with-next (`hasCurrent:true, hasNext:true`) → all enabled.
  - `playing:true` → `showPauseIcon` true; `playing:false` → false.
  - `isLoading:true` → `showSpinner` true.
- **`test/widgets/transport_controls_view_test.dart`** (new, widget): pump
  `TransportControlsView` with controlled `TransportButtons` + spy callbacks.
  Assert: disabled buttons have `onPressed == null` (greyed) and tapping them
  does not fire the callback; enabled buttons fire their callback; the empty-queue
  case (`playEnabled:false`) does not fire `onPlayPause` on tap (the glitch
  regression); spinner shown iff `showSpinner`.
- The `TransportControls` stream-glue and the two layout edits are verified by the
  existing build/analyze plus manual `flutter run` (the real `AudioPlayer` cannot
  run headless). `browser_page` already injects replacement `topControls` /
  `nowPlaying` widgets in its tests, so those continue to pass unchanged.

## Files

- Modify: `lib/widgets/transport_controls.dart` (add `TransportState`,
  `TransportButtons`, `resolveTransport`, `TransportControlsView`; rewire
  `TransportControls`).
- Modify: `lib/widgets/now_playing_bar.dart` (insert transport into the Row).
- Modify: `lib/widgets/top_controls.dart` (remove transport).
- Create: `test/widgets/transport_resolve_test.dart`.
- Create: `test/widgets/transport_controls_view_test.dart`.
