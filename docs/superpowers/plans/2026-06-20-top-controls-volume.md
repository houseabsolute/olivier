# Top Control Bar + Persistent Volume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "Olivier" app-bar title with playback controls (transport + a persistent volume slider), moving the transport up from the bottom now-playing bar.

**Architecture:** A new `volumeProvider` (`AsyncNotifier<double>`) loads the saved volume from the `setting` table on startup, applies it to the audio player through an injectable seam, and persists changes on slider release. The app-bar title becomes a `TopControls` row (`TransportControls` + `VolumeControl`); the transport widgets are extracted from `now_playing_bar.dart`, which keeps only cover/title/seek. `BrowserPage` gains an injectable `topControls` param mirroring the existing `nowPlaying`, so the page stays widget-testable without the live global `audioHandler`.

**Tech Stack:** Dart / Flutter, Riverpod 3.x (`AsyncNotifier`, seam providers), just_audio (`AudioPlayer.setVolume`), the existing `getSettingFnProvider` / `setSettingFnProvider` persistence seams. **Dart-only — no Rust or flutter_rust_bridge changes, so no bridge regeneration.**

**Commands:** Run Flutter through mise: `mise exec -- flutter test <path>`, `mise exec -- flutter analyze`, `mise exec -- dart format <files>`. Final lint gate: `just lint --all`.

**Task order rationale:** 1 → 2 → 3 → 4. Task 3 wires the transport into the **top** bar before Task 4 removes it from the **bottom** bar, so the transport is transiently visible in both places but never absent. Each task leaves a working, compiling app.

**Scope note (deviation from spec):** The spec's `volumeStream` getter on the audio handler is **omitted** — nothing observes the player's volume (the volume only ever changes *through* `volumeProvider`, which is the single source of truth), so it is YAGNI. Only `setVolume` is added.

---

### Task 1: Volume state + persistence

**Files:**
- Modify: `lib/audio/audio_handler.dart` (add `setVolume` after `togglePlayPause`, line 18)
- Create: `lib/state/volume.dart`
- Test: `test/volume_test.dart`

- [ ] **Step 1: Add `setVolume` to the audio handler**

In `lib/audio/audio_handler.dart`, insert after the `togglePlayPause` method (currently line 18, just before `@override Future<void> stop()`):

```dart
  /// Toggle between playing and paused — bound to the space bar.
  Future<void> togglePlayPause() => player.playing ? pause() : play();

  /// Set output volume (0.0–1.0).
  Future<void> setVolume(double v) => player.setVolume(v);

  @override
  Future<void> stop() => player.stop();
```

(Only the `setVolume` lines are new; the surrounding lines show where it goes.)

- [ ] **Step 2: Write the failing tests for `parseVolume` + `volumeProvider`**

Create `test/volume_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/volume.dart';

void main() {
  group('parseVolume', () {
    test('parses a good value', () {
      expect(parseVolume('0.4'), 0.4);
    });
    test('clamps out-of-range values', () {
      expect(parseVolume('1.5'), 1.0);
      expect(parseVolume('-0.2'), 0.0);
    });
    test('falls back to defaultVolume on null/garbage', () {
      expect(parseVolume(null), defaultVolume);
      expect(parseVolume('oops'), defaultVolume);
    });
  });

  test('volumeProvider loads the saved volume and applies it on build',
      () async {
    final applied = <double>[];
    final saved = <(String, String)>[];
    final container = ProviderContainer(overrides: [
      getSettingFnProvider
          .overrideWithValue((key) async => key == volumeKey ? '0.4' : null),
      setSettingFnProvider
          .overrideWithValue((key, value) async => saved.add((key, value))),
      setVolumeFnProvider.overrideWithValue((v) async => applied.add(v)),
    ]);
    addTearDown(container.dispose);

    // build() loads 0.4 and applies it to the player via the seam.
    expect(await container.read(volumeProvider.future), 0.4);
    expect(applied, [0.4]);

    // setVolume(persist: true) applies and saves.
    await container.read(volumeProvider.notifier).setVolume(0.7, persist: true);
    expect(applied, [0.4, 0.7]);
    expect(saved, [(volumeKey, '0.7')]);

    // setVolume without persist applies but does not save.
    applied.clear();
    saved.clear();
    await container.read(volumeProvider.notifier).setVolume(0.6);
    expect(applied, [0.6]);
    expect(saved, isEmpty);
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mise exec -- flutter test test/volume_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:olivier/state/volume.dart'` (the file does not exist yet).

- [ ] **Step 4: Create `lib/state/volume.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/main.dart' show audioHandler;
import 'package:olivier/state/providers.dart';

const volumeKey = 'volume';
const defaultVolume = 1.0;

/// Parse a stored volume string; clamp to [0,1]; [defaultVolume] on bad/missing
/// input. ([num.clamp] returns `num`, so `.toDouble()` keeps the return typed.)
double parseVolume(String? s) {
  final v = s == null ? null : double.tryParse(s);
  if (v == null) return defaultVolume;
  return v.clamp(0.0, 1.0).toDouble();
}

/// Applies a volume to the player. A seam so [VolumeNotifier] is testable
/// without the live audio handler; defaults to the global handler.
typedef SetVolumeFn = Future<void> Function(double v);
final setVolumeFnProvider =
    Provider<SetVolumeFn>((ref) => audioHandler.setVolume);

class VolumeNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final v = parseVolume(await ref.read(getSettingFnProvider)(volumeKey));
    await ref.read(setVolumeFnProvider)(v); // apply the saved level on startup
    return v;
  }

  /// Apply a new volume immediately; persist only when [persist] (on slider
  /// release), so dragging doesn't spam the settings write.
  Future<void> setVolume(double v, {bool persist = false}) async {
    final clamped = v.clamp(0.0, 1.0).toDouble();
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

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mise exec -- flutter test test/volume_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 6: Format + analyze**

Run: `mise exec -- dart format lib/audio/audio_handler.dart lib/state/volume.dart test/volume_test.dart`
Run: `mise exec -- flutter analyze`
Expected: No issues.

- [ ] **Step 7: Commit**

```bash
git add lib/audio/audio_handler.dart lib/state/volume.dart test/volume_test.dart
git commit -m "$(cat <<'EOF'
Add volume state with persistence

setVolume on the audio handler plus a volumeProvider AsyncNotifier that
loads the saved level on startup, applies it through an injectable seam,
and persists changes (only when asked, so dragging doesn't spam writes).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Control widgets (TransportControls, VolumeControl, TopControls)

**Files:**
- Create: `lib/widgets/transport_controls.dart`
- Create: `lib/widgets/volume_control.dart`
- Create: `lib/widgets/top_controls.dart`
- Test: `test/volume_control_test.dart`

**Testability note:** `TransportControls` (and therefore `TopControls`) subscribes to `audioHandler.player.playerStateStream`, a platform-backed just_audio stream, so it **cannot** be widget-tested headless — the same reason `NowPlayingBar` has no render test (see `test/catalog_text_scale_test.dart:113`). Only `VolumeControl` (player-free; backed by the overridable `volumeProvider` seams) gets a widget test.

- [ ] **Step 1: Create `lib/widgets/transport_controls.dart`**

This is the exact transport block lifted from `now_playing_bar.dart` (lines 46–83), wrapped in a `Row(mainAxisSize: MainAxisSize.min)`:

```dart
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/audio_handler.dart';

/// Previous / play-pause / next, driven by the audio handler's player state.
/// Extracted from the now-playing bar so it can live in the top app bar.
class TransportControls extends StatelessWidget {
  const TransportControls({super.key, required this.audioHandler});

  final OlivierAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    final player = audioHandler.player;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          tooltip: 'Previous',
          onPressed: () => audioHandler.skipToPrevious(),
        ),
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, snap) {
            final state = snap.data;
            final playing = state?.playing ?? false;
            final processingState =
                state?.processingState ?? ProcessingState.idle;
            final isLoading = processingState == ProcessingState.loading ||
                processingState == ProcessingState.buffering;
            if (isLoading) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            return IconButton(
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: () =>
                  playing ? audioHandler.pause() : audioHandler.play(),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.skip_next),
          tooltip: 'Next',
          onPressed: () => audioHandler.skipToNext(),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Write the failing test for `VolumeControl`**

Create `test/volume_control_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/volume.dart';
import 'package:olivier/widgets/volume_control.dart';

void main() {
  testWidgets('VolumeControl reflects the provider and drives setVolume',
      (tester) async {
    final applied = <double>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => '0.3'),
        setSettingFnProvider.overrideWithValue((key, value) async {}),
        setVolumeFnProvider.overrideWithValue((v) async => applied.add(v)),
      ],
      child: const MaterialApp(home: Scaffold(body: VolumeControl())),
    ));
    await tester.pumpAndSettle();

    // Reflects the loaded 0.3 and shows the low-volume icon (< 0.5).
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0.3);
    expect(find.byIcon(Icons.volume_down), findsOneWidget);

    // Dragging right drives setVolume to a higher value.
    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(applied, isNotEmpty);
    expect(applied.last, greaterThan(0.3));
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mise exec -- flutter test test/volume_control_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:olivier/widgets/volume_control.dart'`.

- [ ] **Step 4: Create `lib/widgets/volume_control.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/volume.dart';

/// A volume icon plus a compact slider bound to [volumeProvider].
/// `onChanged` gives live feedback (apply, no save); `onChangeEnd` persists.
class VolumeControl extends ConsumerWidget {
  const VolumeControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vol = ref.watch(volumeProvider).valueOrNull ?? defaultVolume;
    final icon = vol <= 0
        ? Icons.volume_off
        : vol < 0.5
            ? Icons.volume_down
            : Icons.volume_up;
    final notifier = ref.read(volumeProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        SizedBox(
          width: 120,
          child: Slider(
            value: vol,
            onChanged: (v) => notifier.setVolume(v),
            onChangeEnd: (v) => notifier.setVolume(v, persist: true),
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mise exec -- flutter test test/volume_control_test.dart`
Expected: PASS (1 test).

- [ ] **Step 6: Create `lib/widgets/top_controls.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/widgets/transport_controls.dart';
import 'package:olivier/widgets/volume_control.dart';

/// The app-bar title content: transport on the left, volume on the right.
class TopControls extends StatelessWidget {
  const TopControls({super.key, required this.audioHandler});

  final OlivierAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TransportControls(audioHandler: audioHandler),
        const Spacer(),
        const VolumeControl(),
      ],
    );
  }
}
```

- [ ] **Step 7: Format + analyze**

Run: `mise exec -- dart format lib/widgets/transport_controls.dart lib/widgets/volume_control.dart lib/widgets/top_controls.dart test/volume_control_test.dart`
Run: `mise exec -- flutter analyze`
Expected: No issues.

- [ ] **Step 8: Commit**

```bash
git add lib/widgets/transport_controls.dart lib/widgets/volume_control.dart lib/widgets/top_controls.dart test/volume_control_test.dart
git commit -m "$(cat <<'EOF'
Add transport, volume, and top-controls widgets

TransportControls is the transport block extracted from the now-playing
bar; VolumeControl is a slider bound to volumeProvider; TopControls rows
them together for the app bar. The bar still renders the transport too;
it moves up in the next task.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Top bar — use TopControls as the app-bar title

**Files:**
- Modify: `lib/catalog/browser_page.dart` (add `topControls` param + import; replace the title)
- Test: `test/browser_page_layout_test.dart:79-81` (add `topControls` stub)
- Test: `test/browser_page_resize_test.dart:89` (add `topControls` stub)

- [ ] **Step 1: Update the two browser-page tests to pass a `topControls` stub**

The tests inject a `nowPlaying` stub so the AppBar/bottom bar don't build the live global `audioHandler`; do the same for `topControls`.

In `test/browser_page_layout_test.dart`, change the `BrowserPage` construction (around line 79):

```dart
          child: const BrowserPage(
            nowPlaying: SizedBox(height: 56, child: Text('stub-now-playing')),
            topControls: SizedBox.shrink(),
          ),
```

In `test/browser_page_resize_test.dart`, change line 89:

```dart
        home: BrowserPage(
          nowPlaying: SizedBox.shrink(),
          topControls: SizedBox.shrink(),
        ),
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- flutter test test/browser_page_layout_test.dart test/browser_page_resize_test.dart`
Expected: FAIL — `No named parameter with the name 'topControls'` (the param doesn't exist yet).

- [ ] **Step 3: Add the `topControls` param to `BrowserPage`**

In `lib/catalog/browser_page.dart`, update the constructor + fields (lines 18–24):

```dart
class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key, this.nowPlaying, this.topControls});

  /// The bottom transport bar. Injectable so the page can be widget-tested
  /// without the live, uninitialized global [audioHandler]. Defaults to the
  /// real [NowPlayingBar] in production.
  final Widget? nowPlaying;

  /// The top control bar (transport + volume). Injectable for the same reason
  /// as [nowPlaying]; defaults to the real [TopControls] in production.
  final Widget? topControls;
```

- [ ] **Step 4: Import `TopControls` and use it as the AppBar title**

Add the import alongside the other widget imports (after line 12, `now_playing_bar.dart`):

```dart
import 'package:olivier/widgets/now_playing_bar.dart';
import 'package:olivier/widgets/resizable_split.dart';
import 'package:olivier/widgets/top_controls.dart';
```

Replace the AppBar title (line 92, `title: const Text('Olivier'),`):

```dart
      appBar: AppBar(
        title: widget.topControls ?? TopControls(audioHandler: audioHandler),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
        bottom: scan.scanning ? _scanProgressBar(scan) : null,
      ),
```

(Only the `title:` line changes; `actions` and `bottom` are unchanged — shown for context.)

- [ ] **Step 5: Run the browser-page tests to verify they pass**

Run: `mise exec -- flutter test test/browser_page_layout_test.dart test/browser_page_resize_test.dart`
Expected: PASS.

- [ ] **Step 6: Format + analyze**

Run: `mise exec -- dart format lib/catalog/browser_page.dart test/browser_page_layout_test.dart test/browser_page_resize_test.dart`
Run: `mise exec -- flutter analyze`
Expected: No issues.

- [ ] **Step 7: Commit**

```bash
git add lib/catalog/browser_page.dart test/browser_page_layout_test.dart test/browser_page_resize_test.dart
git commit -m "$(cat <<'EOF'
Use TopControls as the app-bar title

Replace the static "Olivier" title with the transport + volume controls.
topControls is injectable, mirroring nowPlaying, so the page stays
widget-testable without the live global audioHandler.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Remove the transport from the bottom now-playing bar

**Files:**
- Modify: `lib/widgets/now_playing_bar.dart` (delete the transport children, lines 45–84)

**No unit test:** this deletes untested, live-player-dependent code. `NowPlayingBar` can't be widget-tested headless (it subscribes to platform-backed just_audio streams — see `test/catalog_text_scale_test.dart:113`), and no test renders it, so the removal is verified by `flutter analyze` + the full suite staying green. The transport now lives only in `TopControls`.

- [ ] **Step 1: Delete the transport block from the bar's `Row`**

In `lib/widgets/now_playing_bar.dart`, the `Row`'s `children` currently begin with the transport block (lines 45–84). Remove it so the children start at `// Title / artist.`:

```dart
          child: Row(
            children: [
              // Title / artist.
              Expanded(
                flex: 2,
                child: StreamBuilder<MediaItem?>(
```

That is: delete the `// Transport buttons.` comment, the `skip_previous` `IconButton`, the play/pause `StreamBuilder<PlayerState>`, the `skip_next` `IconButton`, and the trailing `const SizedBox(width: 8),` — everything from line 45 through line 84. Keep everything from `// Title / artist.` onward unchanged.

(The `just_audio` import stays — `AudioPlayer` is still used by `_player`/`_posStream`. `PlayerState`/`ProcessingState` simply become unreferenced names from that same import, which Dart does not flag.)

- [ ] **Step 2: Analyze to confirm no unused imports or dangling references**

Run: `mise exec -- flutter analyze`
Expected: No issues. (If analyze reports an unused `just_audio` import, that means `_posStream`/`_player` were also touched — they must not be; revert and remove only the transport children.)

- [ ] **Step 3: Run the full test suite to confirm nothing regressed**

Run: `mise exec -- flutter test`
Expected: All tests pass (no test renders `NowPlayingBar`, so the removal breaks nothing).

- [ ] **Step 4: Format**

Run: `mise exec -- dart format lib/widgets/now_playing_bar.dart`
Expected: Formatted/unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/now_playing_bar.dart
git commit -m "$(cat <<'EOF'
Remove transport from the now-playing bar

The previous/play-pause/next controls now live in the top app bar via
TopControls. The bar keeps the cover, bilingual title/artist, and seek.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (before finishing the branch)

- [ ] `just lint --all` — whole-project lint gate (dart format check + analyze; no Rust touched).
- [ ] `mise exec -- flutter test` — full suite green.
- [ ] Manual smoke (optional, `just run`): the app bar shows transport + a volume slider (no "Olivier" text); dragging the slider changes loudness; the bottom bar shows cover/title/seek with no transport buttons; restart preserves the volume.

## Touched files

| File | Change |
|------|--------|
| `lib/audio/audio_handler.dart` | `setVolume` passthrough |
| `lib/state/volume.dart` | `parseVolume`, `setVolumeFnProvider`, `VolumeNotifier`, `volumeProvider` (new) |
| `lib/widgets/transport_controls.dart` | extracted transport (new) |
| `lib/widgets/volume_control.dart` | volume icon + slider (new) |
| `lib/widgets/top_controls.dart` | transport + volume row (new) |
| `lib/catalog/browser_page.dart` | `topControls` param + AppBar title |
| `lib/widgets/now_playing_bar.dart` | remove transport |
| `test/volume_test.dart` | `parseVolume` + `volumeProvider` (new) |
| `test/volume_control_test.dart` | `VolumeControl` widget (new) |
| `test/browser_page_layout_test.dart`, `test/browser_page_resize_test.dart` | `topControls` stub |
