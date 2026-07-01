# Playback Error Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a queued track fails to play, surface the actual mpv error and skip to the next track (or stop if last), instead of stopping silently.

**Architecture:** The failure already arrives on `AudioPlayer.errorStream` as a `PlayerException` (media_kit forwards mpv's error log through just_audio_media_kit). `PlaybackController._subscribeErrors` currently only logs it. Add a pure `resolvePlaybackError()` (message + skip/stop decision) and have `_subscribeErrors` surface the notice via the app's `ErrorReporter` and recover — once per track.

**Tech Stack:** Flutter, just_audio (`PlayerException`, `errorStream`), audio_service (`skipToNext`/`stop`).

**Spec:** `docs/superpowers/specs/2026-06-29-playback-error-recovery-design.md`

---

## Repository facts (verified — rely on these)

- `lib/audio/playback_controller.dart`:
  - Top-level `mediaItemsForQueueTracks(...)` ends at line 45; `class PlaybackController` starts at line 47.
  - Constructor: lines 48–63 (named params, `_subscribeIndex()/_subscribePlayTracking()/_subscribeErrors()` called in the body).
  - Fields: `final String dbPath;` at line 67; `int? _trackedIndex;` at line 83; `StreamSubscription<PlayerException>? _errorSub;` at line 87.
  - `_subscribePlayTracking()` at lines 219–239 — its `currentIndexStream.listen((i) { if (i != _trackedIndex) {...} })` is where a track change is observed.
  - `_subscribeErrors()` at lines 289–300 — currently only `developer.log`s the error.
- `lib/main.dart:63` defines `final reporter = ErrorReporter(...)`; `PlaybackController(...)` is constructed at lines 92–96 (with `audioHandler`, `queueController`, `dbPath`). `reporter` is in scope there.
- `ErrorReporter.report(Object error, {StackTrace? stack, String? context})` (lib/state/error_reporter.dart) shows a floating snackbar, de-dups identical messages within 3s, and logs an `ERROR` activity line. Passing a `String` works (`'$error'`).
- Existing tests construct `PlaybackController` with named params only, so adding an optional `onPlaybackIssue` is backward-compatible. `errorStream` never fires under headless `flutter test` (no media_kit channel), so the recovery wiring won't perturb existing tests.
- Run tests with `mise exec -- flutter test`; analyze with `mise exec -- flutter analyze`.

## File Structure

- `lib/audio/playback_controller.dart` (MODIFY) — add the pure `resolvePlaybackError` + `PlaybackErrorAction`/`PlaybackErrorOutcome` (top-level); add `onPlaybackIssue`, `_lastErrorIndex`, the index-change reset, and the `_subscribeErrors`/`_recoverFromError` change.
- `lib/main.dart` (MODIFY) — pass `onPlaybackIssue`.
- `test/audio/playback_error_test.dart` (CREATE) — unit tests for `resolvePlaybackError`.

---

## Task 1: Pure `resolvePlaybackError` + types

**Files:**
- Modify: `lib/audio/playback_controller.dart`
- Test: `test/audio/playback_error_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/audio/playback_error_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';

void main() {
  group('resolvePlaybackError', () {
    test('detail + next track: message includes detail, action skipToNext', () {
      final o = resolvePlaybackError(
        title: 'Song',
        detail: 'mp3float: Header missing',
        hasNext: true,
      );
      expect(o.message, 'Couldn\'t play "Song": mp3float: Header missing');
      expect(o.action, PlaybackErrorAction.skipToNext);
    });

    test('no next track: action stop', () {
      final o = resolvePlaybackError(title: 'Song', detail: 'boom', hasNext: false);
      expect(o.action, PlaybackErrorAction.stop);
    });

    test('null detail: no trailing colon', () {
      final o = resolvePlaybackError(title: 'Song', detail: null, hasNext: true);
      expect(o.message, 'Couldn\'t play "Song"');
    });

    test('empty detail: no trailing colon', () {
      final o = resolvePlaybackError(title: 'Song', detail: '', hasNext: true);
      expect(o.message, 'Couldn\'t play "Song"');
    });

    test('title used verbatim; stop when no next', () {
      final o = resolvePlaybackError(title: 'this track', detail: null, hasNext: false);
      expect(o.message, 'Couldn\'t play "this track"');
      expect(o.action, PlaybackErrorAction.stop);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/audio/playback_error_test.dart`
Expected: FAIL to compile — `resolvePlaybackError`, `PlaybackErrorAction`, `PlaybackErrorOutcome` are undefined.

- [ ] **Step 3: Add the pure logic**

In `lib/audio/playback_controller.dart`, insert this AFTER the `mediaItemsForQueueTracks` function (ends line 45) and BEFORE `class PlaybackController {` (line 47):

```dart
/// What to do with the player after a track fails to play.
enum PlaybackErrorAction { skipToNext, stop }

/// The user-facing notice + recovery action for a failed track.
class PlaybackErrorOutcome {
  const PlaybackErrorOutcome({required this.message, required this.action});
  final String message;
  final PlaybackErrorAction action;
}

/// Builds the notice + recovery action for a track that failed to play. Pure
/// (no player, no Flutter) so it is unit-testable. [detail] is the message from
/// the player's `PlayerException` (mpv's error text), which may be null/empty.
PlaybackErrorOutcome resolvePlaybackError({
  required String title,
  required String? detail,
  required bool hasNext,
}) {
  final base = 'Couldn\'t play "$title"';
  return PlaybackErrorOutcome(
    message: (detail == null || detail.isEmpty) ? base : '$base: $detail',
    action: hasNext ? PlaybackErrorAction.skipToNext : PlaybackErrorAction.stop,
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- flutter test test/audio/playback_error_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/audio/playback_controller.dart test/audio/playback_error_test.dart
git commit -m "Add pure resolvePlaybackError decision logic"
```

---

## Task 2: Wire recovery into `PlaybackController`

**Files:**
- Modify: `lib/audio/playback_controller.dart`

No new unit test: the recovery reads the real media_kit player (`errorStream`, `currentIndex`, `hasNext`, `mediaItem`), which can't run headless. The decision logic is covered by Task 1; this wiring is verified by analyze + the full suite here and the manual run after Task 3.

- [ ] **Step 1: Add the `onPlaybackIssue` constructor param**

In the constructor (lines 48–54), add `this.onPlaybackIssue,` after `TracksForPathsFn? tracksForPathsFn,`:

```dart
  PlaybackController({
    required this.audioHandler,
    required this.queueController,
    required this.dbPath,
    TracksForPathsFn? tracksForPathsFn,
    this.onPlaybackIssue,
  }) : _tracksForPaths = tracksForPathsFn ??
            ((paths) => tracksForPaths(dbPath: dbPath, paths: paths)) {
```

- [ ] **Step 2: Declare the field**

After `final String dbPath;` (line 67), add:

```dart

  /// Surfaces a user-facing playback issue (e.g. a track that failed to play).
  /// Null in tests; wired to the app's ErrorReporter in main().
  final void Function(String message)? onPlaybackIssue;
```

- [ ] **Step 3: Add the per-track de-dup field**

After `int? _trackedIndex;` (line 83), add:

```dart
  // Player index of the last track we already ran error recovery for, so the
  // per-frame repeat of a decode error only triggers one skip. Reset on track
  // change (see _subscribePlayTracking).
  int? _lastErrorIndex;
```

- [ ] **Step 4: Reset the de-dup on track change**

In `_subscribePlayTracking` (lines 221–226), change:

```dart
    audioHandler.player.currentIndexStream.listen((i) {
      if (i != _trackedIndex) {
        _trackedIndex = i;
        _recordedForCurrentTrack = false;
      }
    });
```

to:

```dart
    audioHandler.player.currentIndexStream.listen((i) {
      if (i != _trackedIndex) {
        _trackedIndex = i;
        _recordedForCurrentTrack = false;
        // New current track — allow one error recovery for it.
        _lastErrorIndex = null;
      }
    });
```

- [ ] **Step 5: Surface + recover in `_subscribeErrors`**

Replace the whole `_subscribeErrors` method (lines 286–300, including its doc comment) with:

```dart
  /// Playback errors (e.g. a corrupt/undecodable file, or a queued file deleted
  /// or on an unmounted drive) surface on `errorStream` as `PlayerException`s.
  /// Log them, tell the user, and recover so playback never silently wedges.
  void _subscribeErrors() {
    _errorSub = audioHandler.player.errorStream.listen((e) {
      developer.log(
        'playback error: ${e.message}',
        name: 'olivier.player',
        error: e,
      );
      _recoverFromError(e);
    });
  }

  /// A track failed to play. Surface the error and move on: skip to the next
  /// track, or stop if this is the last one. mpv re-emits the decode error per
  /// bad frame, so `_lastErrorIndex` limits us to one recovery per track.
  void _recoverFromError(PlayerException e) {
    final player = audioHandler.player;
    final idx = player.currentIndex;
    if (idx != null && idx == _lastErrorIndex) return;
    _lastErrorIndex = idx;

    final title = audioHandler.mediaItem.value?.title ?? 'this track';
    final outcome = resolvePlaybackError(
      title: title,
      detail: e.message,
      hasNext: player.hasNext,
    );
    onPlaybackIssue?.call(outcome.message);
    if (outcome.action == PlaybackErrorAction.skipToNext) {
      audioHandler.skipToNext();
    } else {
      audioHandler.stop();
    }
  }
```

- [ ] **Step 6: Analyze + run the full suite**

Run: `mise exec -- flutter analyze`
Expected: "No issues found!"

Run: `mise exec -- flutter test`
Expected: all tests pass (the new param defaults null; `errorStream` doesn't fire headless, so existing behavior is unchanged).

- [ ] **Step 7: Commit**

```bash
git add lib/audio/playback_controller.dart
git commit -m "Recover from a failed track: surface the mpv error + skip"
```

---

## Task 3: Wire `onPlaybackIssue` in `main.dart`

**Files:**
- Modify: `lib/main.dart`

- [ ] **Step 1: Pass the callback**

In `lib/main.dart`, change the `PlaybackController` construction (lines 92–96):

```dart
    playbackController = PlaybackController(
      audioHandler: audioHandler,
      queueController: queueController,
      dbPath: dbPath,
    );
```

to:

```dart
    playbackController = PlaybackController(
      audioHandler: audioHandler,
      queueController: queueController,
      dbPath: dbPath,
      onPlaybackIssue: (msg) => reporter.report(msg),
    );
```

(`reporter` is the `ErrorReporter` created at `main.dart:63`; `report` accepts a `String` as its `Object error`.)

- [ ] **Step 2: Analyze + run the full suite**

Run: `mise exec -- flutter analyze`
Expected: "No issues found!"

Run: `mise exec -- flutter test`
Expected: all tests pass.

- [ ] **Step 3: Lint**

Run: `just lint --all`
Expected: passes. (Run `mise exec -- dart format lib/audio/playback_controller.dart lib/main.dart test/audio/playback_error_test.dart` first if dart-format flags anything.)

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart
git commit -m "Wire playback-error notices to the ErrorReporter"
```

- [ ] **Step 5: Manual verification (human — can't run headless)**

Build and run: `just run`. Then **Settings → Add folder → `~/olivier-broken-test`**, let it scan, and play the "Decode Failure Test" album from track 1.
Expected: a snackbar `Couldn't play "Broken Test Track": …` appears, playback advances to "Good Test Track" (660 Hz tone), and Settings → activity log shows an `ERROR` line. Remove the test folder afterward.

---

## Self-Review

**1. Spec coverage:**
- Surface the mpv error on `errorStream` → Task 2 (`_subscribeErrors` → `_recoverFromError`, `onPlaybackIssue`). ✓
- Notice `Couldn't play "<title>": <mpv message>` via ErrorReporter → Task 1 (`resolvePlaybackError`) + Task 3 (wire to `reporter.report`). ✓
- Skip to next / stop if last → Task 1 (`hasNext` → action) + Task 2 (`skipToNext`/`stop`). ✓
- De-dup once per track, reset on track change → Task 2 (`_lastErrorIndex` + Step 4 reset). ✓
- Null/empty message degrades gracefully → Task 1 test cases. ✓
- Unit tests for the pure function; wiring manually verified → Tasks 1 + 3 Step 5. ✓

**2. Placeholder scan:** No TBD/"handle errors"/bare-prose steps; every code step shows full code and exact commands.

**3. Type consistency:** `resolvePlaybackError({title, detail, hasNext}) → PlaybackErrorOutcome{message, action}` and `PlaybackErrorAction.{skipToNext, stop}` are used identically in Task 1 (definition + tests) and Task 2 (`_recoverFromError`). `onPlaybackIssue` is `void Function(String)?` in the field (Task 2 Step 2), the constructor (Step 1), and the call site (Task 3). `_lastErrorIndex` is declared (Step 3), reset (Step 4), and read/written (Step 5) consistently.
