# Resume the Playhead Across Restarts — Design

**Date:** 2026-07-03
**Status:** Approved

## Goal

When Olivier restarts, cue the track the user was on **at the offset they were at**, paused. Today
the queue *contents*, *order*, and *shuffle* state are restored, but the saved `currentIndex` and
`positionMs` only reflect the last **structural** queue mutation (append/remove/reorder/clear/
shuffle) — so as playback advances track-to-track nothing re-persists, and the mid-track offset is
"typically 0". The result: quit while listening to track 5 of an album and you reopen at track 1,
offset 0. This design keeps the playhead (index + position) fresh so restore lands where you left
off.

## Behavioral decisions (agreed)

- **Restore state:** cue **paused** at the saved offset. This matches today's launch behavior —
  `restoreFromSnapshot` already seeks to `positionMs` and never calls `play()`. No change to the
  restore path is needed for this.
- **Save cadence:** **on events only**, no periodic/throttled write-back. A hard crash (SIGKILL)
  loses the current-track offset; that is an accepted trade-off.
- **Near-end handling:** **resume at the saved spot** — if only a few seconds remained, restore
  plays them out and advances normally. No magic threshold.

## Scope: this is a write-side fix

The **restore side already does the right thing.** `restoreFromSnapshot`
(`lib/audio/queue_controller.dart`) rebuilds the player's sources with
`initialPosition: Duration(milliseconds: snap.positionMs.toInt())` and does not auto-play, so a
snapshot carrying an accurate `currentIndex` + `positionMs` is already resumed correctly, paused.
The problem is purely that the snapshot is stale. So all the work is on the **write** side: persist
the live playhead at the right moments.

## Save triggers

`_persist()` is currently called only by the structural mutators (`setQueue`, `setShuffle`,
`append`, `removeAt`, `removePaths`, `reorder`, `clear`). We add three event-driven saves of the
live playhead:

| Trigger | Mechanism | Reliability |
| --- | --- | --- |
| Track advances | existing `currentIndexStream` listener in `PlaybackController._subscribePlayTracking` | Always — keeps the persisted **track** correct as playback moves |
| Pause | new `playingStream.distinct()` listener → save when playback goes non-playing | Always — captures the exact offset at pause |
| Ctrl+Q quit | existing quit binding, changed to flush-then-pop | Always |

### Known limitation (documented, accepted)

The Linux runner is the **old Flutter GTK template** (`linux/runner/my_application.cc` builds the
window with `fl_view_new` and does not route the window's close button through Dart). So
`AppLifecycleListener(onExitRequested:)` does **not** fire on a window-**X** close — it only fires
for exits Dart itself initiates. Therefore:

- Quitting via **Ctrl+Q**, or **pausing before you close**, preserves the exact offset.
- Closing via the window's **X while a track is actively playing** (never paused) is not caught, so
  it falls back to the last track-change save → **resumes the correct track from 0:00**, not the
  exact offset.

Wiring the GTK runner's `delete-event` into a Dart flush handshake would close this gap, but it is a
C++ change that can only be verified by hand; it is intentionally **out of scope** here and can be a
separate follow-up.

## Architecture

### Unit 1 — `QueueController.savePlayhead()` (new public method)

A guarded wrapper over the existing private `_persist()`. The guards are the critical correctness
point: the player's index stream emits `null` transiently (see the existing note at
`_subscribeIndex`), and `_persist()` falls back to `currentIndex: 0` when `currentCanonicalIndex` is
null — so an unguarded event-driven save could clobber a good snapshot with index 0.

```dart
/// Persist the live playhead (current index + position) now. Called on
/// track-change, pause, and app quit so the saved position stays fresh between
/// structural mutations. Guarded so a transient/unresolvable player index can
/// never overwrite a good snapshot with index 0 — unlike the structural
/// mutators, which call [_persist] directly and legitimately persist index 0.
Future<void> savePlayhead() async {
  if (_orderedPaths.isEmpty) return; // nothing to save
  if (currentCanonicalIndex == null) return; // transient/unresolvable — skip
  await _persist();
}
```

The structural mutators keep calling `_persist()` directly (unchanged). Only the new best-effort
callers use `savePlayhead()`.

### Unit 2 — `PlaybackController` save wiring

`PlaybackController` already owns the playback-stream subscriptions, holds a `queueController`
reference, and has a `dispose()` that cancels its subscriptions — so it is the home for both saves.

1. **Track-change save.** In the existing `_subscribePlayTracking` `currentIndexStream` listener,
   inside the `if (i != _trackedIndex)` block, add a save **gated on `i != null`** (never save on a
   transient null index):

   ```dart
   audioHandler.player.currentIndexStream.listen((i) {
     if (i != _trackedIndex) {
       _trackedIndex = i;
       _recordedForCurrentTrack = false;
       _lastErrorIndex = null;
       // Keep the persisted playhead's track fresh as playback advances.
       if (i != null) queueController.savePlayhead();
     }
   });
   ```

2. **Pause save.** Add one new subscription, stored in a field and cancelled in `dispose()`:

   ```dart
   StreamSubscription<bool>? _playingSub;
   // ...
   _playingSub =
       audioHandler.player.playingStream.distinct().listen((playing) {
     if (!playing) queueController.savePlayhead();
   });
   ```

   Rationale for `.distinct()`: `playingStream` can re-emit; we only want the play→pause edge. The
   startup emission (playing == false, right after a paused restore) triggers one redundant but
   harmless save of the just-restored values.

3. **`dispose()`** cancels `_playingSub` alongside the existing subscriptions.

### Unit 3 — Ctrl+Q flush

Change the quit binding default in `lib/main.dart` (currently
`onQuit ?? () => SystemNavigator.pop()`), so it flushes the playhead before popping:

```dart
onQuit ?? () async {
  await queueController.savePlayhead();
  SystemNavigator.pop();
},
```

A `Future<void> Function()` is assignable to `VoidCallback` (Dart's voidness rule), and the closure
body sequences flush → pop, so the write completes before the app exits. The injected `onQuit` used
by tests is unchanged.

## Edge cases

- **Empty queue** (`_orderedPaths.isEmpty`) → `savePlayhead()` is a no-op; `clear()` still persists
  the empty snapshot via `_persist()` as today.
- **Transient null index** from the stream → the `i != null` gate (Unit 2) and the
  `currentCanonicalIndex == null` guard (Unit 1) both prevent a spurious index-0 write.
- **Shuffle on** → `currentCanonicalIndex` already maps the player's shuffled source index back to
  the canonical index (occurrence-aware), and `_persist()` stores the canonical index, so a shuffled
  session round-trips correctly — unchanged by this design.
- **Restore skips missing files** → existing `restoreFromSnapshot` behavior (drop + log) is
  unchanged; the clamped `currentIndex` still points at the right surviving track.

## Testing

**`test/audio/queue_playhead_test.dart` (new)** — `savePlayhead()` via
`QueueController.withPlayer` + `FakeQueuePlayer` + a capturing `saveQueue`:

- After `append([...])` with the fake player reporting `currentIndex == 2` and `position == 30s`,
  `savePlayhead()` persists a snapshot with `currentIndex == 2` and `positionMs == 30000`.
- Empty queue → `savePlayhead()` performs **no** `saveQueue` call.
- Player index out of range so `currentCanonicalIndex == null` → `savePlayhead()` performs **no**
  `saveQueue` call (proves the anti-clobber guard).

**Round-trip test (new, same file or `queue_controller` test)** — build a snapshot via
`savePlayhead()` at a mid-track offset, feed it to `restoreFromSnapshot`, and assert the rebuilt
player was handed the matching `initialPosition` and current index (using the fake's recorded
`setAudioSources` args). Proves position survives save → restore.

**`FakeQueuePlayer` extensions required** (`test/support/fake_queue_player.dart`): the fake already
exposes a settable index via `setCurrentIndex`, but two additions are needed:
- A **settable `position`** — replace the hardcoded `Duration.zero` getter (line 107) with a
  `Duration positionValue` field (default `Duration.zero`) that the getter returns, so a test can
  simulate a mid-track offset for `savePlayhead()` to read.
- **Record `initialPosition`** (and `initialIndex`) in `setAudioSources` — it currently discards
  them; capture them into fields (e.g. `lastInitialPosition` / `lastInitialIndex`) so the round-trip
  test can assert what `restoreFromSnapshot` handed the player. Keep the existing empty-list no-op
  behavior unchanged.

**PlaybackController wiring** — extend the existing playback-controller test harness to assert that
a play→pause transition and a track-index change each trigger a `savePlayhead()` (spy on the
`queueController` or its `saveQueue` seam). If the existing harness cannot drive `playingStream` /
`currentIndexStream`, cover the pause/advance wiring at whatever seam the harness already exposes and
note it; the guarded `savePlayhead()` logic is the load-bearing unit and is fully covered above.

## Files

- Modify: `lib/audio/queue_controller.dart` — add `savePlayhead()`.
- Modify: `lib/audio/playback_controller.dart` — track-change save, `_playingSub` pause save,
  `dispose()` cancel.
- Modify: `lib/main.dart` — Ctrl+Q flush-then-pop.
- Modify: `test/support/fake_queue_player.dart` — settable `position`; record `initialPosition` /
  `initialIndex` in `setAudioSources`.
- Create: `test/audio/queue_playhead_test.dart`.
</content>
</invoke>
