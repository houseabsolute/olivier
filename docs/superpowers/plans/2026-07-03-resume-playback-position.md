# Resume the Playhead Across Restarts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the live playhead (current track index + position) on track-change, pause, and Ctrl+Q so a restart cues the track the user was on, at the offset they were at, paused.

**Architecture:** Pure write-side fix — `restoreFromSnapshot` already seeks to `positionMs` and does not auto-play, so it already cues paused at the saved spot; the snapshot is just stale between structural mutations. Add a guarded `QueueController.savePlayhead()` and call it from three event-driven sites. The guard (skip when the queue is empty or the player index is unresolvable) prevents a transient null index from clobbering a good snapshot with index 0.

**Tech Stack:** Dart / Flutter, just_audio, Riverpod. Tests run under headless `flutter test` with a `FakeQueuePlayer` (the real media_kit backend can't run headless).

---

## Background the implementer needs

- `lib/audio/queue_controller.dart` holds the canonical queue and persists a `QueueSnapshot`
  (`paths`, `currentIndex` [canonical], `positionMs`, `shuffle`) via the private `_persist()`.
  `_persist()` is called only by the structural mutators (`setQueue`, `setShuffle`, `append`,
  `removeAt`, `removePaths`, `reorder`, `clear`). It reads `currentCanonicalIndex` (a public getter,
  nullable) and `_player.position`.
- `currentCanonicalIndex` returns `null` when the queue is empty or the player's index is
  out of range; `_persist()` falls back to `currentIndex: 0` in that case (correct for a structural
  save, wrong for a best-effort playhead save — hence the guard we add).
- `lib/audio/playback_controller.dart` owns the playback-stream subscriptions, holds a
  `queueController` reference, and has a `dispose()` that cancels its `StreamSubscription`s. It reads
  `audioHandler.player` (a real just_audio `AudioPlayer`).
- **Testing seam:** `OlivierAudioHandler.player` is a real `AudioPlayer` constructed inline and is
  NOT injectable; headless, its streams don't emit useful events. So we do not test by driving those
  streams — we extract each save-trigger body into a `@visibleForTesting` method and call it
  directly. `savePlayhead()` reads the QueueController's OWN `_player` (the injected `FakeQueuePlayer`
  in tests), so its inputs are fully controllable.
- `test/support/fake_queue_player.dart` is the `QueuePlayer` test double. It already exposes a
  settable index via `setCurrentIndex(int?)`. Its `position` getter is hardcoded to `Duration.zero`
  and its `setAudioSources` discards `initialIndex`/`initialPosition`; Task 1 fixes both.
- Lint/format gate for the repo: `just lint --all`. Test runner: `flutter test`.

---

## Task 1: Extend `FakeQueuePlayer` (test double) for position + initial-args capture

**Files:**
- Modify: `test/support/fake_queue_player.dart`

This is enabling test infrastructure (a test double has no behavior of its own to TDD); it is
exercised by the tests in Tasks 2–4. Verify with the analyzer and the existing suite.

- [ ] **Step 1: Make `position` settable and record the `setAudioSources` initial args**

In `test/support/fake_queue_player.dart`, replace the hardcoded `position` getter at the bottom of
the class:

```dart
  @override
  Duration get position => Duration.zero;
```

with a settable field + getter, and add fields that capture the last `setAudioSources` seed. Add the
fields near the other state fields (after `int? _currentIndex = 0;`):

```dart
  /// Test hook: the position the fake reports (default zero). Set this to
  /// simulate a mid-track offset for savePlayhead() to read.
  Duration positionValue = Duration.zero;

  /// The initial index/position the last non-empty setAudioSources was seeded
  /// with, so restore round-trip tests can assert what the player was handed.
  int? lastInitialIndex;
  Duration? lastInitialPosition;
```

Replace the getter at the bottom of the class with:

```dart
  @override
  Duration get position => positionValue;
```

And in `setAudioSources`, record the seed in the non-empty branch. Change:

```dart
    if (list.isEmpty) return;
    stopCalled = false;
    sources
      ..clear()
      ..addAll(list.map(_path));
    setCurrentIndex(initialIndex ?? 0);
```

to:

```dart
    if (list.isEmpty) return;
    stopCalled = false;
    lastInitialIndex = initialIndex;
    lastInitialPosition = initialPosition;
    sources
      ..clear()
      ..addAll(list.map(_path));
    setCurrentIndex(initialIndex ?? 0);
```

- [ ] **Step 2: Verify it analyzes clean and the existing suite still passes**

Run: `flutter analyze test/support/fake_queue_player.dart`
Expected: `No issues found!`

Run: `flutter test test/audio/playback_controller_sync_test.dart`
Expected: All tests pass (the change is additive; default `positionValue` is still zero).

- [ ] **Step 3: Commit**

```bash
git add test/support/fake_queue_player.dart
git commit -m "test: FakeQueuePlayer settable position + captured setAudioSources seed"
```

---

## Task 2: `QueueController.savePlayhead()` + save→restore round-trip

**Files:**
- Modify: `lib/audio/queue_controller.dart`
- Create: `test/audio/queue_playhead_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/audio/queue_playhead_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/db.dart';

import '../support/fake_queue_player.dart';

void main() {
  test('savePlayhead persists the live index and position', () async {
    QueueSnapshot? saved;
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);
    await queue.append(['/a.flac', '/b.flac', '/c.flac']);
    player.setCurrentIndex(2);
    player.positionValue = const Duration(seconds: 30);
    saved = null; // drop the append()'s own persist

    await queue.savePlayhead();

    expect(saved, isNotNull);
    expect(saved!.currentIndex, 2);
    expect(saved!.positionMs.toInt(), 30000);
  });

  test('savePlayhead does nothing when the queue is empty', () async {
    QueueSnapshot? saved;
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);

    await queue.savePlayhead();

    expect(saved, isNull);
  });

  test('savePlayhead skips when the player index is unresolvable', () async {
    QueueSnapshot? saved;
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);
    await queue.append(['/a.flac']);
    player.setCurrentIndex(5); // out of range -> currentCanonicalIndex == null
    saved = null;

    await queue.savePlayhead();

    expect(saved, isNull);
  });

  test('a mid-track playhead survives save -> restore', () async {
    final dir = await Directory.systemTemp.createTemp('olivier_playhead');
    addTearDown(() => dir.delete(recursive: true));
    final paths = <String>[
      for (final n in ['a', 'b', 'c'])
        (await File('${dir.path}/$n.flac').writeAsString('x')).path,
    ];

    QueueSnapshot? saved;
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);
    await queue.append(paths);
    player.setCurrentIndex(1);
    player.positionValue = const Duration(seconds: 45);
    await queue.savePlayhead();

    final player2 = FakeQueuePlayer();
    final queue2 = QueueController.withPlayer(player2,
        dbPath: ':memory:', saveQueue: (_) async {});
    await queue2.restoreFromSnapshot(saved!);

    expect(player2.lastInitialIndex, 1);
    expect(player2.lastInitialPosition, const Duration(milliseconds: 45000));
  });
}
```

Note: the round-trip test uses REAL temp files because `restoreFromSnapshot` drops paths that don't
exist on disk (`File(path).exists()`); the three savePlayhead tests need no files because
`savePlayhead` never touches the filesystem.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/audio/queue_playhead_test.dart`
Expected: FAIL — compile error, `The method 'savePlayhead' isn't defined for the class 'QueueController'`.

- [ ] **Step 3: Implement `savePlayhead`**

In `lib/audio/queue_controller.dart`, add this method immediately after `_persist()` (after its
closing brace, before `restoreFromSnapshot`):

```dart
  /// Persist the live playhead (current index + position) now. Called on
  /// track-change, pause, and app quit so the saved position stays fresh
  /// between structural mutations. Guarded so a transient or unresolvable
  /// player index can never overwrite a good snapshot with index 0 — unlike the
  /// structural mutators, which call [_persist] directly and legitimately
  /// persist index 0 (e.g. a fresh setQueue starting at the top).
  Future<void> savePlayhead() async {
    if (_orderedPaths.isEmpty) return; // nothing to save
    if (currentCanonicalIndex == null) return; // transient/unresolvable — skip
    await _persist();
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/audio/queue_playhead_test.dart`
Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add lib/audio/queue_controller.dart test/audio/queue_playhead_test.dart
git commit -m "feat: QueueController.savePlayhead() persists the live playhead"
```

---

## Task 3: Persist the playhead on track-change and pause in `PlaybackController`

**Files:**
- Modify: `lib/audio/playback_controller.dart`
- Create: `test/audio/playback_controller_playhead_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/audio/playback_controller_playhead_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/src/rust/db.dart';

import '../support/fake_queue_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  QueueTrack track(String path) => QueueTrack(
        path: path,
        title: 'Title $path',
        album: 'Album $path',
        addedAt: 0,
      );

  late OlivierAudioHandler handler;
  late FakeQueuePlayer player;
  late QueueController queue;
  late PlaybackController playback;
  QueueSnapshot? saved;

  setUp(() async {
    handler = OlivierAudioHandler();
    player = FakeQueuePlayer();
    saved = null;
    queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (s) async => saved = s);
    playback = PlaybackController(
      audioHandler: handler,
      queueController: queue,
      dbPath: ':memory:',
      tracksForPathsFn: (paths) async => [for (final p in paths) track(p)],
    );
    await queue.append(['/a.flac', '/b.flac']);
    player.setCurrentIndex(1);
    player.positionValue = const Duration(seconds: 10);
    saved = null; // drop the append()'s own persist
  });

  tearDown(() => playback.dispose());

  test('pausing persists the playhead', () {
    playback.onPlayingChanged(false);
    expect(saved, isNotNull);
    expect(saved!.currentIndex, 1);
    expect(saved!.positionMs.toInt(), 10000);
  });

  test('starting playback does NOT persist', () {
    playback.onPlayingChanged(true);
    expect(saved, isNull);
  });

  test('advancing to a new track persists the playhead', () {
    playback.onTrackChanged(1);
    expect(saved, isNotNull);
    expect(saved!.currentIndex, 1);
  });

  test('a transient null index does NOT persist (anti-clobber)', () {
    playback.onTrackChanged(1); // establish a tracked index first
    saved = null;
    playback.onTrackChanged(null); // transient null must not overwrite
    expect(saved, isNull);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/audio/playback_controller_playhead_test.dart`
Expected: FAIL — `The method 'onPlayingChanged' isn't defined` (and `onTrackChanged`).

- [ ] **Step 3: Extract the save-trigger methods and add the pause subscription**

In `lib/audio/playback_controller.dart`:

(a) Add a field for the new subscription, next to the existing ones (near line 121–123):

```dart
  StreamSubscription<bool>? _playingSub;
```

(b) Replace the `currentIndexStream` listener inside `_subscribePlayTracking` (the second one, the
play-tracking one). Change:

```dart
    // Watch for track changes to reset the per-track recorded flag.
    audioHandler.player.currentIndexStream.listen((i) {
      if (i != _trackedIndex) {
        _trackedIndex = i;
        _recordedForCurrentTrack = false;
        // New current track — allow one error recovery for it.
        _lastErrorIndex = null;
      }
    });
```

to:

```dart
    // Watch for track changes to reset the per-track recorded flag and keep the
    // persisted playhead's track fresh as playback advances.
    audioHandler.player.currentIndexStream.listen(onTrackChanged);

    // Persist the playhead whenever playback pauses (captures the exact offset).
    _playingSub =
        audioHandler.player.playingStream.distinct().listen(onPlayingChanged);
```

(c) Add the two extracted methods. Put them just after `_subscribePlayTracking`'s closing brace:

```dart
  /// Handles a player index change: reset per-track play-tracking state and,
  /// for a real (non-null) index, persist the playhead so the saved track stays
  /// current as playback advances. The index stream emits null transiently, so
  /// the null-gate is what prevents clobbering a good snapshot with index 0.
  @visibleForTesting
  void onTrackChanged(int? i) {
    if (i != _trackedIndex) {
      _trackedIndex = i;
      _recordedForCurrentTrack = false;
      // New current track — allow one error recovery for it.
      _lastErrorIndex = null;
      if (i != null) queueController.savePlayhead();
    }
  }

  /// Persists the playhead when playback stops driving (pause or end), so the
  /// exact offset is saved. No-op on the play edge.
  @visibleForTesting
  void onPlayingChanged(bool playing) {
    if (!playing) queueController.savePlayhead();
  }
```

(d) Cancel the new subscription in `dispose()`. Change:

```dart
  void dispose() {
    queueController.revision.removeListener(_onQueueRevision);
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _errorSub?.cancel();
  }
```

to:

```dart
  void dispose() {
    queueController.revision.removeListener(_onQueueRevision);
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _playingSub?.cancel();
    _errorSub?.cancel();
  }
```

(`@visibleForTesting` is already available via the existing `package:flutter/foundation.dart`
import.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/audio/playback_controller_playhead_test.dart`
Expected: PASS (4/4).

- [ ] **Step 5: Run the sibling playback tests to confirm no regression**

Run: `flutter test test/audio/playback_controller_sync_test.dart test/audio/playback_error_test.dart`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add lib/audio/playback_controller.dart test/audio/playback_controller_playhead_test.dart
git commit -m "feat: persist playhead on track-change and pause"
```

---

## Task 4: Flush the playhead on Ctrl+Q

**Files:**
- Modify: `lib/main.dart`
- Create: `test/quit_with_flush_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/quit_with_flush_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/main.dart';

import 'support/fake_queue_player.dart';

void main() {
  test('quitWithFlush saves the playhead before exiting', () async {
    final events = <String>[];
    final player = FakeQueuePlayer();
    final queue = QueueController.withPlayer(player,
        dbPath: ':memory:', saveQueue: (_) async => events.add('saved'));
    await queue.append(['/a.flac']);
    player.setCurrentIndex(0);
    events.clear(); // drop the append()'s own persist

    await quitWithFlush(queue, exit: () => events.add('exited'));

    expect(events, ['saved', 'exited']);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/quit_with_flush_test.dart`
Expected: FAIL — `The function 'quitWithFlush' isn't defined`.

- [ ] **Step 3: Add the `quitWithFlush` helper and wire it to the quit binding**

In `lib/main.dart`, add this top-level function just above `class OlivierApp` (after the
`seekStep`/`volumeStep` consts near line 199):

```dart
/// Persist the playhead, then quit. Exposed so the flush-before-exit ordering
/// is testable; the default [exit] pops the navigator (the app's Ctrl+Q action).
@visibleForTesting
Future<void> quitWithFlush(QueueController queue, {void Function()? exit}) async {
  await queue.savePlayhead();
  (exit ?? () => SystemNavigator.pop())();
}
```

Then wire it into the app by passing `onQuit` to `OlivierApp` in `main()`. Change the `OlivierApp`
construction (currently only passing `onVolumeUp`/`onVolumeDown`):

```dart
          builder: (context, ref, _) => OlivierApp(
            onVolumeUp: () =>
                ref.read(volumeProvider.notifier).nudge(volumeStep),
            onVolumeDown: () =>
                ref.read(volumeProvider.notifier).nudge(-volumeStep),
          ),
```

to also pass `onQuit`:

```dart
          builder: (context, ref, _) => OlivierApp(
            onQuit: () => quitWithFlush(queueController),
            onVolumeUp: () =>
                ref.read(volumeProvider.notifier).nudge(volumeStep),
            onVolumeDown: () =>
                ref.read(volumeProvider.notifier).nudge(-volumeStep),
          ),
```

(`queueController` is the top-level `late final` in `main.dart`, in scope here. `@visibleForTesting`
and `SystemNavigator` are already available via the existing `material.dart` / `services.dart`
imports. `OlivierApp.onQuit` already exists and, when null, falls back to the plain
`SystemNavigator.pop()` — so tests that don't pass it are unaffected.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/quit_with_flush_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart test/quit_with_flush_test.dart
git commit -m "feat: flush the playhead on Ctrl+Q before quitting"
```

---

## Task 5: Full-suite + lint gate

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `flutter test`
Expected: All tests pass (the four new tests plus the existing suite).

- [ ] **Step 2: Run the lint/format gate**

Run: `just lint --all`
Expected: Clean (clippy/rustfmt/dart-format/flutter-analyze/prettier/taplo/typos/shellcheck all
pass).

- [ ] **Step 3: Fix anything the gate flags, then re-run until clean.** If `dart format` rewrites a
  file, `git add` it and amend the relevant task commit or add a `style:` commit.

---

## Manual verification (human, after merge)

Headless tests can't drive the real media_kit backend, so confirm in a running app:

1. Play an album, let it advance to track 3–4, **pause**, quit and relaunch → it reopens cued
   **paused** on that track at roughly the offset you paused at.
2. Play, then quit with **Ctrl+Q** mid-track → relaunch resumes at that offset.
3. Play, then close via the **window X** while still playing → relaunch reopens the **correct
   track from 0:00** (the documented limitation — the old GTK runner doesn't route window-close
   through Dart).
4. Shuffle the library, advance a few tracks, pause, relaunch → the same shuffled order resumes on
   the right track.
</content>
