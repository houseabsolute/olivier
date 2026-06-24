# Transport + Volume Keyboard Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-app keyboard shortcuts — Ctrl/Cmd+←/→ (prev/next track), Ctrl/Cmd+↑/↓ (volume ±5%), Shift+←/→ (seek ∓10s) — alongside the existing Space (play/pause) and Ctrl-Q (quit).

**Architecture:** Three small units: a pure `clampSeek` helper + `OlivierAudioHandler.seekBy` for relative seeking, `VolumeNotifier.nudge` for stepped volume, and an extension of `OlivierApp`'s root `Focus.onKeyEvent` that maps the new chords to injectable callbacks (gated by the existing `_textInputHasFocus()`). `OlivierApp` stays a provider-agnostic `StatelessWidget`; the volume callbacks are injected in `main()` under the `ProviderScope`.

**Tech Stack:** Flutter, Riverpod 3.x (`AsyncNotifier`), just_audio (via `OlivierAudioHandler`). Tests via `mise exec -- flutter test`. Lint gate: `just lint --all`.

**Spec:** `docs/superpowers/specs/2026-06-24-keyboard-shortcuts-design.md`

**Conventions:**
- Flutter runs through mise: `mise exec -- flutter test <path>`.
- Use `state.value` (nullable) — this repo's Riverpod has no `valueOrNull`.
- NEVER `git add` the `TODO` file.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `lib/audio/audio_handler.dart` (modify) — add pure top-level `clampSeek` + `OlivierAudioHandler.seekBy`.
- `lib/state/volume.dart` (modify) — add `VolumeNotifier.nudge`.
- `lib/main.dart` (modify) — step constants, six injectable callbacks on `OlivierApp`, extended `onKeyEvent`, `Consumer` volume wiring in `main()`.
- `test/seek_clamp_test.dart` (create) — pure `clampSeek` unit tests.
- `test/volume_test.dart` (modify) — add a `nudge` test.
- `test/media_shortcuts_test.dart` (create) — widget tests for the six chords + focus suppression.

---

## Task 1: Relative seek (`clampSeek` + `seekBy`)

**Files:**
- Modify: `lib/audio/audio_handler.dart`
- Test: `test/seek_clamp_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `test/seek_clamp_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/audio_handler.dart';

void main() {
  group('clampSeek', () {
    test('clamps a below-zero target to zero', () {
      expect(
        clampSeek(const Duration(seconds: 5), const Duration(seconds: -10),
            const Duration(minutes: 3)),
        Duration.zero,
      );
    });

    test('clamps a past-duration target to the duration', () {
      expect(
        clampSeek(const Duration(minutes: 2, seconds: 55),
            const Duration(seconds: 10), const Duration(minutes: 3)),
        const Duration(minutes: 3),
      );
    });

    test('applies no upper clamp when duration is null', () {
      expect(
        clampSeek(const Duration(seconds: 5), const Duration(seconds: 10), null),
        const Duration(seconds: 15),
      );
    });

    test('returns the in-range target unchanged', () {
      expect(
        clampSeek(const Duration(seconds: 30), const Duration(seconds: 10),
            const Duration(minutes: 3)),
        const Duration(seconds: 40),
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- flutter test test/seek_clamp_test.dart`
Expected: FAIL — compile error, `clampSeek` is not defined.

- [ ] **Step 3: Add `clampSeek` and `seekBy`**

In `lib/audio/audio_handler.dart`, add this pure top-level function above the
`OlivierAudioHandler` class (after the imports on line 2):

```dart
/// Clamp a relative seek target to the playable range. With no known duration
/// only the lower bound (zero) is applied.
Duration clampSeek(Duration position, Duration delta, Duration? duration) {
  final target = position + delta;
  if (target < Duration.zero) return Duration.zero;
  if (duration != null && target > duration) return duration;
  return target;
}
```

Then add this method to `OlivierAudioHandler`, right after the existing `seek`
override (currently line 26 `Future<void> seek(Duration position) => player.seek(position);`):

```dart

  /// Seek relative to the current position, clamped to [0, duration].
  Future<void> seekBy(Duration delta) =>
      seek(clampSeek(player.position, delta, player.duration));
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- flutter test test/seek_clamp_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/audio/audio_handler.dart test/seek_clamp_test.dart
git commit -m "$(cat <<'EOF'
Add clampSeek + OlivierAudioHandler.seekBy for relative seek

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Stepped volume (`VolumeNotifier.nudge`)

**Files:**
- Modify: `lib/state/volume.dart`
- Test: `test/volume_test.dart` (modify)

- [ ] **Step 1: Write the failing test**

In `test/volume_test.dart`, add this test inside `main()` after the existing
`volumeProvider loads the saved volume...` test (after line 49, before the
closing `}` of `main`):

```dart

  test('nudge changes volume by delta, clamps to [0,1], and persists',
      () async {
    final applied = <double>[];
    final saved = <(String, String)>[];
    final container = ProviderContainer(overrides: [
      getSettingFnProvider
          .overrideWithValue((key) async => key == volumeKey ? '0.5' : null),
      setSettingFnProvider
          .overrideWithValue((key, value) async => saved.add((key, value))),
      setVolumeFnProvider.overrideWithValue((v) async => applied.add(v)),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(volumeProvider.future), 0.5);
    final n = container.read(volumeProvider.notifier);

    // Up by 0.05 → ~0.55: applied to the player AND persisted.
    applied.clear();
    saved.clear();
    await n.nudge(0.05);
    expect(container.read(volumeProvider).value, closeTo(0.55, 1e-9));
    expect(applied.single, closeTo(0.55, 1e-9));
    expect(saved.single.$1, volumeKey);
    expect(double.parse(saved.single.$2), closeTo(0.55, 1e-9));

    // Down past zero clamps to 0.0.
    await n.setVolume(0.02);
    await n.nudge(-0.05);
    expect(container.read(volumeProvider).value, 0.0);

    // Up past one clamps to 1.0.
    await n.setVolume(0.98);
    await n.nudge(0.05);
    expect(container.read(volumeProvider).value, 1.0);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- flutter test test/volume_test.dart`
Expected: FAIL — `nudge` is not defined on `VolumeNotifier`.

- [ ] **Step 3: Add `nudge`**

In `lib/state/volume.dart`, add this method to `VolumeNotifier`, right after the
existing `setVolume` method (after line 39's closing `}`, before the class's
closing `}`):

```dart

  /// Nudge the volume by [delta] (keyboard Up/Down). Delegates to [setVolume]
  /// (which clamps to [0,1]) and persists so the level survives a restart.
  Future<void> nudge(double delta) =>
      setVolume((state.value ?? defaultVolume) + delta, persist: true);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- flutter test test/volume_test.dart`
Expected: PASS (all tests in the file, including the new `nudge` test).

- [ ] **Step 5: Commit**

```bash
git add lib/state/volume.dart test/volume_test.dart
git commit -m "$(cat <<'EOF'
Add VolumeNotifier.nudge for stepped, persisted volume changes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Root key handler + bindings + production wiring

**Files:**
- Modify: `lib/main.dart`
- Test: `test/media_shortcuts_test.dart` (create)

This task wires the chords into `OlivierApp`'s root `Focus.onKeyEvent`. The new
chords are gated by the existing `_textInputHasFocus()` so they never fire while
a text field is focused. `OlivierApp` gains six injectable `VoidCallback?` params
(testable, like the existing `onTogglePlayPause`); track/seek default to the
global `audioHandler`, and the two volume callbacks are injected in `main()`
(where a `ProviderScope` makes `ref` available).

- [ ] **Step 1: Write the failing test**

Create `test/media_shortcuts_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart';

void main() {
  Future<void> pump(WidgetTester tester, OlivierApp app) async {
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey modifier,
      LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  testWidgets('Ctrl+Right → next track', (tester) async {
    var n = 0;
    await pump(
        tester,
        OlivierApp(
          onNextTrack: () => n++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(tester, LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.arrowRight);
    expect(n, 1);
  });

  testWidgets('Ctrl+Left → previous track', (tester) async {
    var p = 0;
    await pump(
        tester,
        OlivierApp(
          onPreviousTrack: () => p++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowLeft);
    expect(p, 1);
  });

  testWidgets('Ctrl+Up → volume up', (tester) async {
    var up = 0;
    await pump(
        tester,
        OlivierApp(
          onVolumeUp: () => up++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowUp);
    expect(up, 1);
  });

  testWidgets('Ctrl+Down → volume down', (tester) async {
    var down = 0;
    await pump(
        tester,
        OlivierApp(
          onVolumeDown: () => down++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowDown);
    expect(down, 1);
  });

  testWidgets('Shift+Right → seek forward', (tester) async {
    var fwd = 0;
    await pump(
        tester,
        OlivierApp(
          onSeekForward: () => fwd++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowRight);
    expect(fwd, 1);
  });

  testWidgets('Shift+Left → seek backward', (tester) async {
    var back = 0;
    await pump(
        tester,
        OlivierApp(
          onSeekBackward: () => back++,
          home: const Scaffold(body: Center(child: Text('body'))),
        ));
    await chord(
        tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowLeft);
    expect(back, 1);
  });

  testWidgets('chords are suppressed while a text field is focused',
      (tester) async {
    var n = 0, up = 0, fwd = 0;
    await pump(
        tester,
        OlivierApp(
          onNextTrack: () => n++,
          onVolumeUp: () => up++,
          onSeekForward: () => fwd++,
          home: const Scaffold(body: Center(child: TextField())),
        ));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await chord(tester, LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.arrowRight); // would be next track
    await chord(
        tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowUp);
    await chord(
        tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowRight);

    expect(n, 0, reason: 'Ctrl+Right must yield word-jump to the field');
    expect(up, 0);
    expect(fwd, 0, reason: 'Shift+Right must yield selection to the field');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- flutter test test/media_shortcuts_test.dart`
Expected: FAIL — `OlivierApp` has no `onNextTrack` (etc.) named parameters.

- [ ] **Step 3a: Add the volume import + step constants**

In `lib/main.dart`, add this import alphabetically among the `package:olivier/...`
imports (after the `state/providers.dart` import on line 19):

```dart
import 'package:olivier/state/volume.dart';
```

Add these constants just above the `class OlivierApp` declaration (currently
line 188):

```dart
/// Per-keypress steps for the transport/volume keyboard shortcuts.
const volumeStep = 0.05;
const seekStep = Duration(seconds: 10);

```

- [ ] **Step 3b: Add the injectable callbacks to `OlivierApp`**

In `lib/main.dart`, extend the `OlivierApp` constructor. Replace:

```dart
  const OlivierApp({
    super.key,
    this.onQuit,
    this.onTogglePlayPause,
    this.home,
  });
```

with:

```dart
  const OlivierApp({
    super.key,
    this.onQuit,
    this.onTogglePlayPause,
    this.onNextTrack,
    this.onPreviousTrack,
    this.onSeekForward,
    this.onSeekBackward,
    this.onVolumeUp,
    this.onVolumeDown,
    this.home,
  });
```

Then add the field declarations right after the existing `onTogglePlayPause`
field (after its doc comment + `final VoidCallback? onTogglePlayPause;`, line 201):

```dart

  /// Injectable transport actions (Ctrl/Cmd+←/→, Shift+←/→). Default to the
  /// global audio handler; overridden in tests.
  final VoidCallback? onNextTrack;
  final VoidCallback? onPreviousTrack;
  final VoidCallback? onSeekForward;
  final VoidCallback? onSeekBackward;

  /// Injectable volume actions (Ctrl/Cmd+↑/↓). No global default — volume needs
  /// the provider, which this StatelessWidget can't read, so they are injected
  /// in main() under the ProviderScope (null ⇒ the chord is ignored).
  final VoidCallback? onVolumeUp;
  final VoidCallback? onVolumeDown;
```

- [ ] **Step 3c: Replace the `onKeyEvent` handler**

In `lib/main.dart`, replace the entire existing `onKeyEvent` callback (currently
lines 222–230):

```dart
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.space &&
              !_textInputHasFocus()) {
            (onTogglePlayPause ?? () => audioHandler.togglePlayPause())();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
```

with:

```dart
        onKeyEvent: (node, event) {
          // Media shortcuts fire on key-down only (no auto-repeat on hold) and
          // yield entirely to a focused text field, so typing — including
          // in-field Ctrl+←/→ word-jump and Shift+←/→ selection — is preserved.
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (_textInputHasFocus()) return KeyEventResult.ignored;

          final key = event.logicalKey;
          final kb = HardwareKeyboard.instance;
          final mod = kb.isControlPressed || kb.isMetaPressed; // Ctrl or Cmd
          final shift = kb.isShiftPressed;

          if (key == LogicalKeyboardKey.space && !mod && !shift) {
            (onTogglePlayPause ?? () => audioHandler.togglePlayPause())();
            return KeyEventResult.handled;
          }

          if (mod && !shift) {
            if (key == LogicalKeyboardKey.arrowRight) {
              (onNextTrack ?? () => audioHandler.skipToNext())();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft) {
              (onPreviousTrack ?? () => audioHandler.skipToPrevious())();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowUp && onVolumeUp != null) {
              onVolumeUp!();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowDown && onVolumeDown != null) {
              onVolumeDown!();
              return KeyEventResult.handled;
            }
          }

          if (shift && !mod) {
            if (key == LogicalKeyboardKey.arrowRight) {
              (onSeekForward ?? () => audioHandler.seekBy(seekStep))();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft) {
              (onSeekBackward ?? () => audioHandler.seekBy(-seekStep))();
              return KeyEventResult.handled;
            }
          }

          return KeyEventResult.ignored;
        },
```

- [ ] **Step 4: Run the widget test to verify it passes**

Run: `mise exec -- flutter test test/media_shortcuts_test.dart`
Expected: PASS (7 tests).

Also re-run the existing shortcut tests to confirm no regression:

Run: `mise exec -- flutter test test/play_pause_shortcut_test.dart test/ctrl_q_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire production volume callbacks in `main()`**

In `lib/main.dart`, in the `runApp(...)` call, replace:

```dart
        child: const OlivierApp(),
```

with:

```dart
        child: Consumer(
          builder: (context, ref, _) => OlivierApp(
            onVolumeUp: () =>
                ref.read(volumeProvider.notifier).nudge(volumeStep),
            onVolumeDown: () =>
                ref.read(volumeProvider.notifier).nudge(-volumeStep),
          ),
        ),
```

(`Consumer` and `ref` come from the already-imported `flutter_riverpod`;
`volumeProvider`/`nudge` from the `volume.dart` import added in Step 3a.)

- [ ] **Step 6: Verify the full suite, analyzer, and lint**

Run: `mise exec -- flutter test`
Expected: entire Dart suite PASS.

Run: `just lint --all`
Expected: PASS (rustfmt/clippy/dart-format/flutter-analyze/prettier/typos/etc.).

- [ ] **Step 7: Commit**

```bash
git add lib/main.dart test/media_shortcuts_test.dart
git commit -m "$(cat <<'EOF'
Add transport + volume keyboard shortcuts

Ctrl/Cmd+←/→ prev/next track, Ctrl/Cmd+↑/↓ volume ±5%, Shift+←/→ seek ∓10s,
gated by the existing text-input focus check. Track/seek default to the global
audioHandler; volume is injected in main() under the ProviderScope so OlivierApp
stays provider-agnostic and the scope-free shortcut tests are unaffected.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Definition of Done

- `Ctrl/Cmd+←/→` skip tracks, `Ctrl/Cmd+↑/↓` change volume by 5% (persisted),
  `Shift+←/→` seek ∓10s — none of them fire while the search field is focused.
- `Space` (play/pause) and `Ctrl-Q` (quit) still work.
- New: `clampSeek` + `seekBy`, `VolumeNotifier.nudge`, six injectable callbacks
  on `OlivierApp`, production volume wiring in `main()`.
- All tests green (`mise exec -- flutter test`); `just lint --all` clean.
