# Playback Error Recovery (surface mpv errors + skip) — Design

**Date:** 2026-06-29
**Status:** Approved

## Goal

When a queued track fails to play, Olivier should **surface the actual error** (the message mpv
reports) and **skip to the next track** (or stop if it's the last), instead of stopping silently on
the bad track with nothing shown.

## Background

A real MP3 with a corrupt leading frame stalled playback: the track stopped, the UI stayed
responsive, and the user had to skip manually. Tracing the stack showed the failure is **already
delivered to the app as a catchable event** — we were just swallowing it:

1. **media_kit** forwards mpv error-level log messages (incl. `mp3float: Header missing`,
   `Error decoding audio`) to `Player.stream.error`
   (`media_kit/.../native/player/real.dart` ~2069–2117, fed by `MPV_EVENT_LOG_MESSAGE`).
2. **just_audio_media_kit** listens to it (`mediakit_player.dart:144`), stores the text in
   `_errorMessage`, sets `processingState = idle`, and emits a `PlaybackEventMessage` carrying
   `errorCode`/`errorMessage`.
3. **just_audio** turns that into a **`PlayerException` on `AudioPlayer.errorStream`**.

`PlaybackController._subscribeErrors` already subscribes to `errorStream` — its own comment says
"MPV / source-open failures surface on errorStream as PlayerExceptions … so a bad track is
skipped/logged and the app keeps running" — but it only calls `developer.log`. It never surfaces the
error or skips. That's the entire gap.

A timing-based stall watchdog was considered and **rejected**: the error is catchable, so a heuristic
is unnecessary and less precise.

## Behavior

- On a `PlayerException` from `audioHandler.player.errorStream`:
  - **Surface** a notice: `Couldn't play "<title>": <mpv message>` (snackbar + activity-log line via
    the existing `ErrorReporter`).
  - **Recover**: if there is a next track, skip to it; otherwise stop.
- **De-dup**: mpv emits the error repeatedly (per bad frame), so recover **once per track** — keyed on
  the player's current index, reset when the index changes. The `ErrorReporter` additionally de-dups
  identical messages within 3s.
- Skipping through several consecutive bad tracks is naturally bounded: each track is handled once and
  the index advances on each skip; the last track has no next, so we stop.

## Architecture

A pure decision function plus a one-method change to the existing error subscription. No timers, no
sampling, no thresholds.

### Unit 1 — pure formatter/decision (top-level in `lib/audio/playback_controller.dart`)

```dart
enum PlaybackErrorAction { skipToNext, stop }

@immutable
class PlaybackErrorOutcome {
  const PlaybackErrorOutcome({required this.message, required this.action});
  final String message;             // user-facing notice
  final PlaybackErrorAction action; // what to do with the player
}

/// Builds the notice + recovery action for a failed track. Pure (no player, no
/// Flutter) so it is unit-testable.
PlaybackErrorOutcome resolvePlaybackError({
  required String title,   // failing track's title (caller supplies a fallback)
  required String? detail, // mpv message from the PlayerException (may be null/empty)
  required bool hasNext,   // is there a next track to skip to
}) {
  final base = 'Couldn\'t play "$title"';
  return PlaybackErrorOutcome(
    message: (detail == null || detail.isEmpty) ? base : '$base: $detail',
    action: hasNext ? PlaybackErrorAction.skipToNext : PlaybackErrorAction.stop,
  );
}
```

### Unit 2 — wiring in `PlaybackController`

- Add an injectable `void Function(String message)? onPlaybackIssue` constructor param (default null;
  tests pass a spy, `main.dart` wires it to `ErrorReporter`).
- Add `int? _lastErrorIndex;`. Reset it to `null` whenever the player's current index changes (fold
  into the existing `currentIndexStream` listener in `_subscribePlayTracking`).
- Replace the body of `_subscribeErrors` so it still logs, then recovers:

```dart
void _subscribeErrors() {
  _errorSub = audioHandler.player.errorStream.listen((e) {
    developer.log('playback error: ${e.message}',
        name: 'olivier.player', error: e);
    _recoverFromError(e);
  });
}

void _recoverFromError(PlayerException e) {
  final player = audioHandler.player;
  final idx = player.currentIndex;
  if (idx != null && idx == _lastErrorIndex) return; // already handled this track
  _lastErrorIndex = idx;

  final title = audioHandler.mediaItem.value?.title ?? 'this track';
  final outcome = resolvePlaybackError(
      title: title, detail: e.message, hasNext: player.hasNext);
  onPlaybackIssue?.call(outcome.message);
  switch (outcome.action) {
    case PlaybackErrorAction.skipToNext:
      audioHandler.skipToNext();
    case PlaybackErrorAction.stop:
      audioHandler.stop();
  }
}
```

### Unit 3 — `lib/main.dart`

Pass `onPlaybackIssue: (msg) => reporter.report(msg)` when constructing `PlaybackController`
(main.dart:92). `ErrorReporter.report` already shows a floating snackbar, de-dups within 3s, and
appends an `ERROR` line to the activity log (so failures are also reviewable in Settings).

## Error handling / edge cases

- Repeated per-frame errors for the same track → ignored after the first (the `_lastErrorIndex`
  guard).
- All-bad queue → skips track by track, then stops at the last (no next).
- A bare error with a null/empty message → the notice degrades gracefully to just
  `Couldn't play "<title>"`.

## Testing

- **`test/audio/playback_error_test.dart`** (pure, host-VM): table for `resolvePlaybackError` —
  - detail present + `hasNext` → message is `Couldn't play "X": <detail>`, action `skipToNext`;
  - detail present + `!hasNext` → action `stop`;
  - `detail` null and `detail` empty → message is exactly `Couldn't play "X"` (no trailing colon);
  - title is used verbatim (caller owns the fallback).
- The `errorStream` wiring reads the real media_kit player, which can't run headless, so it is
  verified by a **manual run**: play a deliberately-corrupt MP3 (synthesize one with junk prepended to
  a valid file), confirm the app shows the "Couldn't play …" snackbar and advances to the next track.
  The decision logic it depends on is fully covered by the unit tests above.

## Files

- Modify: `lib/audio/playback_controller.dart` (add `PlaybackErrorAction`, `PlaybackErrorOutcome`,
  `resolvePlaybackError`, `onPlaybackIssue`, `_lastErrorIndex` + its reset, and the `_subscribeErrors`
  / `_recoverFromError` change).
- Modify: `lib/main.dart` (pass `onPlaybackIssue`).
- Create: `test/audio/playback_error_test.dart`.
