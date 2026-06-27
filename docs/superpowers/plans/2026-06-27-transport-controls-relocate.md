# Transport Controls Relocate + Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move prev/play/next from the top app bar into the bottom now-playing bar (right of the title/artist) and grey out each button when it can't do anything useful — which also fixes the empty-queue Play→Pause icon glitch.

**Architecture:** Extract the button enable/icon rules into a pure function `resolveTransport(TransportState) → TransportButtons` and a pure `TransportControlsView` widget (both unit/widget-tested), leaving the existing `TransportControls` as thin glue that maps the real `just_audio` player's streams to a `TransportState`. Then relocate the widget (now-playing bar gains it, top controls loses it).

**Tech Stack:** Flutter, Riverpod, just_audio 0.10.5 (`sequenceStateStream`/`playerStateStream`/`hasNext`/`currentIndex`), rxdart 0.28 (`Rx.combineLatest2`).

**Spec:** `docs/superpowers/specs/2026-06-27-transport-controls-relocate-and-gate-design.md`

---

## File Structure

- `lib/widgets/transport_controls.dart` (MODIFY) — gains `TransportState`, `TransportButtons`, `resolveTransport` (pure logic), `TransportControlsView` (pure view), and a rewired `TransportControls` (stream glue). Single file: these units are tightly cohesive and small.
- `lib/widgets/now_playing_bar.dart` (MODIFY) — insert `TransportControls` into the Row between the title/artist and the seek slider.
- `lib/widgets/top_controls.dart` (MODIFY) — remove `TransportControls`; search reflows to fill.
- `test/widgets/transport_resolve_test.dart` (CREATE) — host-VM unit tests for `resolveTransport`.
- `test/widgets/transport_controls_view_test.dart` (CREATE) — widget tests for `TransportControlsView`.

**Background facts (verified):**
- `OlivierAudioHandler.player` (`lib/audio/audio_handler.dart:15`) is a non-injectable real `AudioPlayer` that can't run under headless `flutter test`. That's why the logic is extracted into pure units; the glue layer is not unit-tested (verified via analyze + manual run).
- `audioHandler.seek(Duration)` exists (`lib/audio/audio_handler.dart:35`) → used for the Prev "restart current track" action.
- `player.sequenceStateStream` and `player.playerStateStream` are seeded `BehaviorSubject`s, so `Rx.combineLatest2` emits immediately.
- `browser_page` tests inject replacement `topControls`/`nowPlaying` widgets, so the real bars aren't exercised there; the full suite stays green after the layout edits.

---

## Task 1: Pure transport decision logic

**Files:**
- Modify: `lib/widgets/transport_controls.dart`
- Test: `test/widgets/transport_resolve_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/widgets/transport_resolve_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/transport_controls.dart';

void main() {
  group('resolveTransport', () {
    test('empty queue disables every button', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: false,
        hasNext: false,
        playing: false,
        isLoading: false,
      ));
      expect(b.prevEnabled, isFalse);
      expect(b.playEnabled, isFalse);
      expect(b.nextEnabled, isFalse);
      expect(b.showSpinner, isFalse);
      expect(b.showPauseIcon, isFalse);
    });

    test('last track: prev + play enabled, next disabled', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: true,
        hasNext: false,
        playing: false,
        isLoading: false,
      ));
      expect(b.prevEnabled, isTrue);
      expect(b.playEnabled, isTrue);
      expect(b.nextEnabled, isFalse);
    });

    test('track with a next: all three enabled', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: true,
        hasNext: true,
        playing: false,
        isLoading: false,
      ));
      expect(b.prevEnabled, isTrue);
      expect(b.playEnabled, isTrue);
      expect(b.nextEnabled, isTrue);
    });

    test('playing shows the pause icon', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: true,
        hasNext: true,
        playing: true,
        isLoading: false,
      ));
      expect(b.showPauseIcon, isTrue);
    });

    test('loading shows the spinner', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: true,
        hasNext: true,
        playing: false,
        isLoading: true,
      ));
      expect(b.showSpinner, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/widgets/transport_resolve_test.dart`
Expected: FAIL to compile — `TransportState`, `TransportButtons`, `resolveTransport` are undefined.

- [ ] **Step 3: Add the pure logic**

At the TOP of `lib/widgets/transport_controls.dart`, replace the existing imports block (currently lines 1-3) with the imports plus the new pure types/function, leaving the existing `TransportControls` class (below) untouched for now:

```dart
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/audio_handler.dart';

/// The transport buttons' input state, derived from the player. A pure value
/// type so [resolveTransport] (and its tests) need no real player.
@immutable
class TransportState {
  const TransportState({
    required this.hasCurrent,
    required this.hasNext,
    required this.playing,
    required this.isLoading,
  });

  /// A track is loaded (the player has a current source).
  final bool hasCurrent;

  /// There is a track after the current one.
  final bool hasNext;

  /// The player is currently playing (vs paused).
  final bool playing;

  /// The player is loading/buffering (show a spinner, not an icon).
  final bool isLoading;
}

/// The rendered state of the three transport buttons.
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

  /// Show the loading spinner in the play/pause slot instead of an icon.
  final bool showSpinner;

  /// The play/pause icon is "pause" (true) rather than "play" (false).
  final bool showPauseIcon;
}

/// Pure mapping from player state to button state. Prev (restart the current
/// track) and play/pause need a loaded track; next needs a following track.
TransportButtons resolveTransport(TransportState s) => TransportButtons(
      prevEnabled: s.hasCurrent,
      playEnabled: s.hasCurrent,
      nextEnabled: s.hasNext,
      showSpinner: s.isLoading,
      showPauseIcon: s.playing,
    );
```

Note: this changes the import line `import 'package:just_audio/just_audio.dart';` to remain (the old widget still uses it). Keep the existing `TransportControls` class below unchanged in this task.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- flutter test test/widgets/transport_resolve_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/transport_controls.dart test/widgets/transport_resolve_test.dart
git commit -m "Add pure transport button decision logic"
```

---

## Task 2: Pure view widget `TransportControlsView`

**Files:**
- Modify: `lib/widgets/transport_controls.dart`
- Test: `test/widgets/transport_controls_view_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/widgets/transport_controls_view_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/transport_controls.dart';

Future<void> _pump(
  WidgetTester tester,
  TransportButtons buttons, {
  VoidCallback? onPrev,
  VoidCallback? onPlayPause,
  VoidCallback? onNext,
}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TransportControlsView(
        buttons: buttons,
        onPrev: onPrev ?? () {},
        onPlayPause: onPlayPause ?? () {},
        onNext: onNext ?? () {},
      ),
    ),
  ));
}

IconButton _btn(WidgetTester tester, IconData icon) =>
    tester.widget<IconButton>(find.ancestor(
      of: find.byIcon(icon),
      matching: find.byType(IconButton),
    ));

void main() {
  testWidgets('all enabled: each tap fires its callback', (tester) async {
    var prev = 0, play = 0, next = 0;
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: true,
        playEnabled: true,
        nextEnabled: true,
        showSpinner: false,
        showPauseIcon: false,
      ),
      onPrev: () => prev++,
      onPlayPause: () => play++,
      onNext: () => next++,
    );

    await tester.tap(find.byIcon(Icons.skip_previous));
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.tap(find.byIcon(Icons.skip_next));

    expect(prev, 1);
    expect(play, 1);
    expect(next, 1);
  });

  testWidgets('empty queue: play is disabled and does not toggle (glitch fix)',
      (tester) async {
    var play = 0;
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: false,
        playEnabled: false,
        nextEnabled: false,
        showSpinner: false,
        showPauseIcon: false,
      ),
      onPlayPause: () => play++,
    );

    expect(_btn(tester, Icons.play_arrow).onPressed, isNull);
    expect(_btn(tester, Icons.skip_previous).onPressed, isNull);
    expect(_btn(tester, Icons.skip_next).onPressed, isNull);

    await tester.tap(find.byIcon(Icons.play_arrow), warnIfMissed: false);
    expect(play, 0);
  });

  testWidgets('next disabled at the last track', (tester) async {
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: true,
        playEnabled: true,
        nextEnabled: false,
        showSpinner: false,
        showPauseIcon: false,
      ),
    );
    expect(_btn(tester, Icons.skip_next).onPressed, isNull);
    expect(_btn(tester, Icons.skip_previous).onPressed, isNotNull);
  });

  testWidgets('spinner replaces the play/pause icon when loading',
      (tester) async {
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: true,
        playEnabled: true,
        nextEnabled: true,
        showSpinner: true,
        showPauseIcon: false,
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('shows pause icon when playing', (tester) async {
    await _pump(
      tester,
      const TransportButtons(
        prevEnabled: true,
        playEnabled: true,
        nextEnabled: true,
        showSpinner: false,
        showPauseIcon: true,
      ),
    );
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/widgets/transport_controls_view_test.dart`
Expected: FAIL to compile — `TransportControlsView` is undefined.

- [ ] **Step 3: Add the view widget**

In `lib/widgets/transport_controls.dart`, add this class AFTER `resolveTransport` and BEFORE the existing `TransportControls` class:

```dart
/// Previous / play-pause / next buttons rendered from a [TransportButtons]. A
/// disabled button passes `onPressed: null` so Material greys it out. Pure (no
/// player) so it is widget-testable.
class TransportControlsView extends StatelessWidget {
  const TransportControlsView({
    super.key,
    required this.buttons,
    required this.onPrev,
    required this.onPlayPause,
    required this.onNext,
  });

  final TransportButtons buttons;
  final VoidCallback onPrev;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          tooltip: 'Restart track',
          onPressed: buttons.prevEnabled ? onPrev : null,
        ),
        if (buttons.showSpinner)
          const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          IconButton(
            icon: Icon(buttons.showPauseIcon ? Icons.pause : Icons.play_arrow),
            tooltip: buttons.showPauseIcon ? 'Pause' : 'Play',
            onPressed: buttons.playEnabled ? onPlayPause : null,
          ),
        IconButton(
          icon: const Icon(Icons.skip_next),
          tooltip: 'Next',
          onPressed: buttons.nextEnabled ? onNext : null,
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- flutter test test/widgets/transport_controls_view_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/transport_controls.dart test/widgets/transport_controls_view_test.dart
git commit -m "Add pure TransportControlsView widget"
```

---

## Task 3: Rewire `TransportControls` to stream glue

**Files:**
- Modify: `lib/widgets/transport_controls.dart` (replace the existing `TransportControls` class body)

No new unit test: this layer reads the real `AudioPlayer`, which can't run headless. Correctness of the decision logic is covered by Tasks 1–2; this task is verified by `flutter analyze` and the manual run in Task 4.

- [ ] **Step 1: Replace the `TransportControls` class**

In `lib/widgets/transport_controls.dart`, replace the ENTIRE existing `TransportControls` class (the old `StatelessWidget` that builds the Row directly with `StreamBuilder<PlayerState>`) with:

```dart
/// Previous / play-pause / next, driven by the audio handler's player. Thin glue
/// that maps the player's streams to a [TransportState] and renders a
/// [TransportControlsView]; all decision logic lives in [resolveTransport].
class TransportControls extends StatelessWidget {
  const TransportControls({super.key, required this.audioHandler});

  final OlivierAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    final player = audioHandler.player;
    return StreamBuilder<TransportState>(
      stream: Rx.combineLatest2<SequenceState, PlayerState, TransportState>(
        player.sequenceStateStream,
        player.playerStateStream,
        (seq, ps) {
          final processing = ps.processingState;
          return TransportState(
            hasCurrent: player.currentIndex != null,
            hasNext: player.hasNext,
            playing: ps.playing,
            isLoading: processing == ProcessingState.loading ||
                processing == ProcessingState.buffering,
          );
        },
      ),
      builder: (context, snap) {
        final state = snap.data ??
            const TransportState(
              hasCurrent: false,
              hasNext: false,
              playing: false,
              isLoading: false,
            );
        return TransportControlsView(
          buttons: resolveTransport(state),
          onPrev: () => audioHandler.seek(Duration.zero),
          onPlayPause: () =>
              state.playing ? audioHandler.pause() : audioHandler.play(),
          onNext: () => audioHandler.skipToNext(),
        );
      },
    );
  }
}
```

- [ ] **Step 2: Add the rxdart import**

At the top of `lib/widgets/transport_controls.dart`, add to the import block:

```dart
import 'package:rxdart/rxdart.dart';
```

Resulting import block:

```dart
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:rxdart/rxdart.dart';
```

- [ ] **Step 3: Analyze + run the existing suite**

Run: `mise exec -- flutter analyze lib/widgets/transport_controls.dart`
Expected: "No issues found!"

Run: `mise exec -- flutter test test/widgets/transport_resolve_test.dart test/widgets/transport_controls_view_test.dart`
Expected: PASS (10 tests) — the pure units still build against the rewired file.

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/transport_controls.dart
git commit -m "Rewire TransportControls to pure logic + view via player streams"
```

---

## Task 4: Relocate — bottom bar gains it, top bar loses it

**Files:**
- Modify: `lib/widgets/now_playing_bar.dart` (insert `TransportControls` into the Row)
- Modify: `lib/widgets/top_controls.dart` (remove `TransportControls`)

- [ ] **Step 1: Insert transport into the now-playing bar**

In `lib/widgets/now_playing_bar.dart`, add the import (after the existing `bilingual_text.dart` import):

```dart
import 'package:olivier/widgets/transport_controls.dart';
```

Then, in the `Row` inside `build`, replace the single spacer that sits between the title/artist `Expanded(flex: 2, ...)` and the seek `Expanded(flex: 3, ...)`:

```dart
              const SizedBox(width: 8),
```

with the spacer, the transport, and a second spacer:

```dart
              const SizedBox(width: 8),
              TransportControls(audioHandler: audioHandler),
              const SizedBox(width: 8),
```

The resulting Row order is: `[ Expanded(flex:2 title/artist) ] [ SizedBox(8) ] [ TransportControls ] [ SizedBox(8) ] [ Expanded(flex:3 seek+time) ]`.

- [ ] **Step 2: Remove transport from the top controls**

Replace the ENTIRE contents of `lib/widgets/top_controls.dart` with:

```dart
import 'package:flutter/material.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/widgets/search_field.dart';
import 'package:olivier/widgets/volume_control.dart';

/// The app-bar title content: search fills the center, volume on the right.
/// (Transport controls now live in the bottom now-playing bar.)
class TopControls extends StatelessWidget {
  const TopControls({super.key, required this.audioHandler});

  final OlivierAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Center(child: SearchField())),
        SizedBox(width: 8),
        VolumeControl(),
      ],
    );
  }
}
```

Note: `audioHandler` is retained on `TopControls` (the constructor is called with it in `lib/catalog/browser_page.dart:107`); it is simply no longer used inside, which is fine for a public widget field. The `transport_controls.dart` import is removed.

- [ ] **Step 3: Analyze + run the full suite**

Run: `mise exec -- flutter analyze`
Expected: "No issues found!"

Run: `mise exec -- flutter test`
Expected: all tests pass (browser_page tests inject replacement `topControls`/`nowPlaying`, so they are unaffected by the relocation).

- [ ] **Step 4: Lint**

Run: `just lint --all`
Expected: all checks pass (run `mise exec -- dart format lib/widgets/now_playing_bar.dart lib/widgets/top_controls.dart lib/widgets/transport_controls.dart` first if dart-format flags anything).

- [ ] **Step 5: Manual verification**

Run: `just run`
Verify:
1. prev/play/next now appear in the bottom now-playing bar, to the right of the title/artist; the top bar shows only search + volume.
2. With an empty queue, all three buttons are greyed out and clicking Play does NOT flip to a pause icon.
3. Add an album → buttons enable; Play plays from the top; Next advances; on the last track Next greys out; Prev restarts the current track (jumps to 0:00) and never changes track.
4. `Ctrl/Cmd+←` still skips to the previous track (unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/now_playing_bar.dart lib/widgets/top_controls.dart
git commit -m "Move transport controls into the now-playing bar"
```

---

## Self-Review

**1. Spec coverage:**
- Prev restarts current track, greyed when no track → Task 1 (`prevEnabled: hasCurrent`), Task 3 (`onPrev: seek(Duration.zero)`). ✓
- Play greyed when empty (glitch fix) → Task 1 (`playEnabled: hasCurrent`), Task 2 (disabled-play test). ✓
- Next greyed at last/empty → Task 1 (`nextEnabled: hasNext`). ✓
- Loading spinner preserved → Task 1 (`showSpinner`), Task 2 (spinner test). ✓
- Layout: bottom bar `[title][transport][seek]`, top bar `[search][volume]` → Task 4. ✓
- Keyboard `Ctrl/Cmd+←` unchanged → no task touches `main.dart`/`audio_handler.dart`; called out in Task 4 manual check. ✓
- Testing: pure unit + view widget tests → Tasks 1–2. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✓

**3. Type consistency:** `TransportState{hasCurrent,hasNext,playing,isLoading}` and `TransportButtons{prevEnabled,playEnabled,nextEnabled,showSpinner,showPauseIcon}` are used identically across Tasks 1, 2, 3 and both test files. `resolveTransport`, `TransportControlsView` names consistent throughout. ✓
