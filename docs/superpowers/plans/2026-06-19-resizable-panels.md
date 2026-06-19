# Resizable & Persistent Panels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Drag-resize the artist/album/track columns and the queue, persisting the sizes across launches.

**Architecture:** A `layoutSettingsProvider` (FutureProvider) loads three keys from the settings table via the existing `getSettingFn` seam; `BrowserPage` seeds its two `MultiSplitViewController`s' `Area(flex:)` from them and saves on `onDividerDragEnd`; `QueuePanel` gets a draggable top edge with a persisted pixel height. Pure Flutter — no Rust/bridge changes.

**Tech Stack:** Flutter, Riverpod, `multi_split_view` ^3.6.2 (already a dep).

**Spec:** `docs/superpowers/specs/2026-06-19-resizable-panels-design.md`

**Conventions (every task):** Branch `resize-panels`. NEVER stage `TODO`/`#TODO#`. `git -C /home/autarch/projects/olivier` for git. Run flutter commands with a `timeout` guard. Widget tests: use `pump()` not `pumpAndSettle()` if anything hangs. ACTUALLY RUN every command; report real output. End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Task 1: Layout settings model + provider + helpers

**Files:**
- Create: `lib/state/layout_settings.dart`
- Test: `test/layout_settings_test.dart`

- [ ] **Step 1: Write the failing tests.** Create `test/layout_settings_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/layout_settings.dart';
import 'package:olivier/state/providers.dart';

void main() {
  group('parsing', () {
    test('parseFlexPair parses a good pair', () {
      expect(parseFlexPair('1,3', defaultArtistFlex), (1.0, 3.0));
      expect(parseFlexPair('2.5, 1.5', defaultArtistFlex), (2.5, 1.5));
    });
    test('parseFlexPair falls back on bad input', () {
      expect(parseFlexPair(null, defaultArtistFlex), defaultArtistFlex);
      expect(parseFlexPair('oops', defaultArtistFlex), defaultArtistFlex);
      expect(parseFlexPair('1', defaultArtistFlex), defaultArtistFlex);
      expect(parseFlexPair('0,1', defaultArtistFlex), defaultArtistFlex); // non-positive
      expect(parseFlexPair('-1,2', defaultArtistFlex), defaultArtistFlex);
    });
    test('formatFlexPair round-trips', () {
      expect(parseFlexPair(formatFlexPair((1.0, 2.0)), defaultArtistFlex), (1.0, 2.0));
    });
    test('parseQueueHeight parses or defaults', () {
      expect(parseQueueHeight('320'), 320.0);
      expect(parseQueueHeight(null), defaultQueueHeight);
      expect(parseQueueHeight('nope'), defaultQueueHeight);
    });
  });

  test('layoutSettingsProvider loads + parses from the seam', () async {
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((key) async => switch (key) {
            'layout.artists' => '1,3',
            'layout.right_pane' => '2,1',
            'layout.queue_height' => '300',
            _ => null,
          }),
    ]);
    addTearDown(container.dispose);

    final s = await container.read(layoutSettingsProvider.future);
    expect(s.artistFlex, (1.0, 3.0));
    expect(s.rightPaneFlex, (2.0, 1.0));
    expect(s.queueHeight, 300.0);
  });

  test('layoutSettingsProvider uses defaults when unset', () async {
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((_) async => null),
    ]);
    addTearDown(container.dispose);

    final s = await container.read(layoutSettingsProvider.future);
    expect(s.artistFlex, defaultArtistFlex);
    expect(s.rightPaneFlex, defaultRightPaneFlex);
    expect(s.queueHeight, defaultQueueHeight);
  });
}
```

- [ ] **Step 2: Run, verify it fails.**

Run: `timeout 180 mise exec -- flutter test test/layout_settings_test.dart 2>&1 | tail -12`
Expected: FAIL — `layout_settings.dart` and its symbols don't exist.

- [ ] **Step 3: Implement.** Create `lib/state/layout_settings.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/providers.dart';

const layoutArtistsKey = 'layout.artists';
const layoutRightPaneKey = 'layout.right_pane';
const layoutQueueHeightKey = 'layout.queue_height';

const defaultArtistFlex = (1.0, 2.0);
const defaultRightPaneFlex = (1.0, 1.0);
const defaultQueueHeight = 240.0;
const minQueueHeight = 80.0;

/// Persisted panel sizes. Flex pairs for the columns (resolution-independent);
/// a pixel height for the expanded queue.
class LayoutSettings {
  const LayoutSettings({
    required this.artistFlex,
    required this.rightPaneFlex,
    required this.queueHeight,
  });

  final (double, double) artistFlex;
  final (double, double) rightPaneFlex;
  final double queueHeight;

  static const defaults = LayoutSettings(
    artistFlex: defaultArtistFlex,
    rightPaneFlex: defaultRightPaneFlex,
    queueHeight: defaultQueueHeight,
  );
}

/// Parse `"f0,f1"` into a positive flex pair; [fallback] on any bad input.
(double, double) parseFlexPair(String? s, (double, double) fallback) {
  if (s == null) return fallback;
  final parts = s.split(',');
  if (parts.length != 2) return fallback;
  final a = double.tryParse(parts[0].trim());
  final b = double.tryParse(parts[1].trim());
  if (a == null || b == null || a <= 0 || b <= 0) return fallback;
  return (a, b);
}

String formatFlexPair((double, double) f) => '${f.$1},${f.$2}';

/// Parse a pixel height; [defaultQueueHeight] on bad input. (The widget clamps
/// to the current screen at use time.)
double parseQueueHeight(String? s) => double.tryParse(s ?? '') ?? defaultQueueHeight;

/// Loads the persisted layout once via the settings seam, defaulting any
/// missing/garbage value.
final layoutSettingsProvider = FutureProvider<LayoutSettings>((ref) async {
  final get = ref.watch(getSettingFnProvider);
  final results = await Future.wait([
    get(layoutArtistsKey),
    get(layoutRightPaneKey),
    get(layoutQueueHeightKey),
  ]);
  return LayoutSettings(
    artistFlex: parseFlexPair(results[0], defaultArtistFlex),
    rightPaneFlex: parseFlexPair(results[1], defaultRightPaneFlex),
    queueHeight: parseQueueHeight(results[2]),
  );
});
```

- [ ] **Step 4: Run, verify it passes.**

Run: `timeout 180 mise exec -- flutter test test/layout_settings_test.dart 2>&1 | tail -8` → PASS (6 tests). Then full `timeout 400 mise exec -- flutter test 2>&1 | tail -3` + `mise exec -- precious lint --all 2>&1 | tail -3`.

- [ ] **Step 5: Commit.**

```bash
git -C /home/autarch/projects/olivier add lib/state/layout_settings.dart test/layout_settings_test.dart
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Add layout settings model + provider for persisted panel sizes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Persist artist↔right + make album↔track a vertical split

**Files:**
- Modify: `lib/catalog/browser_page.dart`
- Test: `test/browser_page_resize_test.dart`

- [ ] **Step 1: Write the failing test.** Create `test/browser_page_resize_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:olivier/catalog/browser_page.dart';
import 'package:olivier/state/providers.dart';

void main() {
  testWidgets('renders two MultiSplitViews (artist|right and album|track)',
      (tester) async {
    final saved = <String, String>{};
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((_) async => null),
        setSettingFnProvider.overrideWithValue((k, v) async => saved[k] = v),
        // Stub the catalog seams so the columns build without FFI.
        listRootsFnProvider.overrideWithValue(() async => <String>[]),
      ],
      child: const MaterialApp(
        home: BrowserPage(nowPlaying: SizedBox.shrink()),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // Artist|right + album|track = two split views.
    expect(find.byType(MultiSplitView), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
```

NOTE: `BrowserPage` watches `scanControllerProvider` (loads roots) and the columns watch the catalog providers. Override the MINIMUM seams so it builds without FFI — model the overrides on an existing test that pumps `BrowserPage` (search `test/` — `browser_page_layout_test.dart` exists; copy its override set). The `listRootsFnProvider` name above is a guess — use the real one. The assertions (two `MultiSplitView`s, no exception) stay.

- [ ] **Step 2: Run, verify it fails.**

Run: `timeout 180 mise exec -- flutter test test/browser_page_resize_test.dart 2>&1 | tail -15`
Expected: FAIL — today there is only ONE `MultiSplitView` (album↔track is a plain `Column`), so `findsNWidgets(2)` fails (or a build error until the overrides are right).

- [ ] **Step 3: Restructure `browser_page.dart`.** Replace the `_BrowserPageState` controller setup + `_RightPane` so that:
- there are TWO controllers (artist↔right + album↔track);
- both seed their `Area(flex:)` from `layoutSettingsProvider` after the first frame;
- each `MultiSplitView` saves on `onDividerDragEnd`.

Add imports at the top:
```dart
import 'package:olivier/state/layout_settings.dart';
```

Replace the `_BrowserPageState` fields + `initState` + `dispose` with:
```dart
class _BrowserPageState extends ConsumerState<BrowserPage> {
  late final MultiSplitViewController _rightController;
  late final MultiSplitViewController _splitController;

  @override
  void initState() {
    super.initState();
    // Album over Track (vertical). Created first — referenced by the outer split.
    _rightController = MultiSplitViewController(areas: [
      Area(flex: defaultRightPaneFlex.$1, min: 80, builder: (c, a) => const AlbumColumn()),
      Area(flex: defaultRightPaneFlex.$2, min: 80, builder: (c, a) => const TrackColumn()),
    ]);
    // Artist | right pane (horizontal).
    _splitController = MultiSplitViewController(areas: [
      Area(flex: defaultArtistFlex.$1, min: 220, builder: (c, a) => const ArtistColumn()),
      Area(
        flex: defaultArtistFlex.$2,
        min: 320,
        builder: (c, a) => _RightPane(
          controller: _rightController,
          onDragEnd: _saveRightPaneFlex,
        ),
      ),
    ]);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ref.read(scanControllerProvider.notifier).loadRoots();
      final s = await ref.read(layoutSettingsProvider.future);
      if (!mounted) return;
      _splitController.areas = [
        Area(flex: s.artistFlex.$1, min: 220, builder: (c, a) => const ArtistColumn()),
        Area(
          flex: s.artistFlex.$2,
          min: 320,
          builder: (c, a) => _RightPane(
            controller: _rightController,
            onDragEnd: _saveRightPaneFlex,
          ),
        ),
      ];
      _rightController.areas = [
        Area(flex: s.rightPaneFlex.$1, min: 80, builder: (c, a) => const AlbumColumn()),
        Area(flex: s.rightPaneFlex.$2, min: 80, builder: (c, a) => const TrackColumn()),
      ];
    });
  }

  void _saveArtistFlex() {
    final a = _splitController.areas;
    ref.read(setSettingFnProvider)(
      layoutArtistsKey,
      formatFlexPair((a[0].flex ?? defaultArtistFlex.$1, a[1].flex ?? defaultArtistFlex.$2)),
    );
  }

  void _saveRightPaneFlex() {
    final a = _rightController.areas;
    ref.read(setSettingFnProvider)(
      layoutRightPaneKey,
      formatFlexPair((a[0].flex ?? defaultRightPaneFlex.$1, a[1].flex ?? defaultRightPaneFlex.$2)),
    );
  }

  @override
  void dispose() {
    _splitController.dispose();
    _rightController.dispose();
    super.dispose();
  }
```

Change the body's artist↔right `MultiSplitView` to save on drag-end:
```dart
          Expanded(
            child: MultiSplitView(
              controller: _splitController,
              onDividerDragEnd: (_) => _saveArtistFlex(),
            ),
          ),
```

Replace the `_RightPane` widget at the bottom of the file with a vertical split:
```dart
/// The right pane of the browse split: Album over Track as a vertical
/// MultiSplitView with a draggable, persisted divider.
class _RightPane extends StatelessWidget {
  const _RightPane({required this.controller, required this.onDragEnd});

  final MultiSplitViewController controller;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return MultiSplitView(
      axis: Axis.vertical,
      controller: controller,
      onDividerDragEnd: (_) => onDragEnd(),
    );
  }
}
```
(`Area`/`MultiSplitView`/`Axis` come from the existing `multi_split_view` + `flutter/material` imports. Confirm `Area` is imported — `multi_split_view` exports it.)

- [ ] **Step 4: Run, verify it passes.**

Run: `timeout 180 mise exec -- flutter test test/browser_page_resize_test.dart 2>&1 | tail -8` → PASS. Then run the existing `timeout 180 mise exec -- flutter test test/browser_page_layout_test.dart 2>&1 | tail -5` to confirm no regression in the layout test, and the full `timeout 400 mise exec -- flutter test 2>&1 | tail -3`.

- [ ] **Step 5: Commit.**

```bash
git -C /home/autarch/projects/olivier add lib/catalog/browser_page.dart test/browser_page_resize_test.dart
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Persist artist split + make album/track a resizable vertical split

Seed both split controllers' flex from layoutSettingsProvider after the
first frame; save the flex pair on each divider drag-end.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Resizable + persisted queue height

**Files:**
- Modify: `lib/catalog/queue_panel.dart`
- Test: `test/queue_resize_test.dart`

- [ ] **Step 1: Write the failing test.** Create `test/queue_resize_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/state/cover_providers.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

QueueTrack _track(String path, String title) =>
    QueueTrack(path: path, title: title, album: '', titleTranslit: null, titleTranslate: null);

void main() {
  testWidgets('expanded queue shows a resize handle and persists on drag',
      (tester) async {
    final saved = <String, String>{};
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((_) async => null),
        setSettingFnProvider.overrideWithValue((k, v) async => saved[k] = v),
        coverForPathFnProvider.overrideWithValue((_) async => null),
        queueProvider.overrideWith(() => _FakeQueue(QueueView(
              tracks: [_track('/m/a.flac', 'A'), _track('/m/b.flac', 'B')],
              currentIndex: 0,
              shuffled: false,
            ))),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    ));
    await tester.pump();
    await tester.pump();

    // Expand the queue.
    await tester.tap(find.byTooltip('Expand queue'));
    await tester.pump();
    await tester.pump();

    final handle = find.byKey(const ValueKey('queue-resize-handle'));
    expect(handle, findsOneWidget);

    // Drag the handle up to grow the queue, then release.
    await tester.drag(handle, const Offset(0, -50));
    await tester.pump();

    expect(saved.containsKey('layout.queue_height'), isTrue,
        'releasing the resize handle should persist the height');
    expect(tester.takeException(), isNull);
  });
}

class _FakeQueue extends QueueNotifier {
  _FakeQueue(this._view);
  final QueueView _view;
  @override
  Future<QueueView> build() async => _view;
}
```

NOTE: confirm `QueueTrack`'s constructor (it has a required `album`; see `test/queue_now_playing_cover_test.dart`). The expand button's tooltip is `'Expand queue'` (see `queue_panel.dart`). `tester.drag` on the handle should trigger `onVerticalDragEnd`; if the synthetic drag doesn't, fall back to asserting the handle renders + calling the save path via a smaller drag, and note it.

- [ ] **Step 2: Run, verify it fails.**

Run: `timeout 180 mise exec -- flutter test test/queue_resize_test.dart 2>&1 | tail -15`
Expected: FAIL — there's no resize handle (`queue-resize-handle` not found).

- [ ] **Step 3: Add the resize handle + persisted height.** In `lib/catalog/queue_panel.dart`:

Add the import:
```dart
import 'package:olivier/state/layout_settings.dart';
```

In `_QueuePanelState`, add a height field and load it after the first frame:
```dart
  bool _expanded = false;
  double? _queueHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final s = await ref.read(layoutSettingsProvider.future);
      if (mounted) setState(() => _queueHeight = s.queueHeight);
    });
  }
```

Replace `_expandedList`'s `ConstrainedBox(constraints: BoxConstraints(maxHeight: …*0.4), child: ReorderableListView.builder(…))` with a drag handle above a fixed-height list:
```dart
  Widget _expandedList(BuildContext context, QueueView view) {
    final leads = ref.watch(languageLeadsProvider);
    final controller = ref.read(queueControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    final maxH = MediaQuery.sizeOf(context).height * 0.6;
    final height = (_queueHeight ?? defaultQueueHeight).clamp(minQueueHeight, maxH);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drag handle on the top edge: drag up to grow the queue.
        MouseRegion(
          cursor: SystemMouseCursors.resizeRow,
          child: GestureDetector(
            key: const ValueKey('queue-resize-handle'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              final max = MediaQuery.sizeOf(context).height * 0.6;
              setState(() {
                _queueHeight =
                    ((_queueHeight ?? defaultQueueHeight) - d.delta.dy).clamp(minQueueHeight, max);
              });
            },
            onVerticalDragEnd: (_) {
              ref.read(setSettingFnProvider)(
                layoutQueueHeightKey,
                (_queueHeight ?? defaultQueueHeight).toStringAsFixed(0),
              );
            },
            child: Container(
              height: 8,
              color: scheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: height,
          child: ReorderableListView.builder(
            shrinkWrap: true,
            itemCount: view.tracks.length,
            onReorderItem: (oldIndex, newIndex) {
              controller.reorder(oldIndex, newIndex);
            },
            itemBuilder: (context, i) {
              final t = view.tracks[i];
              final selected = i == view.currentIndex;
              return Material(
                key: ValueKey('${t.path}#$i'),
                color: selected ? scheme.primaryContainer : Colors.transparent,
                child: InkWell(
                  onTap: () => controller.playAt(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_handle),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: BilingualText(
                            original: t.title,
                            translit: t.titleTranslit,
                            translate: t.titleTranslate,
                            leads: leads,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Remove from queue',
                          onPressed: () => controller.removeAt(i),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
```

NOTE: the `ReorderableListView.builder` body above is COPIED VERBATIM from the current `_expandedList` (only the wrapping changed from `ConstrainedBox`→`SizedBox(height:)` + the handle). If the current row builder differs, keep the real one — change ONLY the wrapper (replace the 40% `ConstrainedBox` with the handle + `SizedBox(height: clampedHeight)`).

- [ ] **Step 4: Run, verify it passes.**

Run: `timeout 180 mise exec -- flutter test test/queue_resize_test.dart 2>&1 | tail -8` → PASS. Then full `timeout 400 mise exec -- flutter test 2>&1 | tail -3` (incl. the existing queue tests) + `mise exec -- precious lint --all 2>&1 | tail -3` + `timeout 400 mise exec -- flutter build linux --debug 2>&1 | tail -3`.

- [ ] **Step 5: Commit.**

```bash
git -C /home/autarch/projects/olivier add lib/catalog/queue_panel.dart test/queue_resize_test.dart
git -C /home/autarch/projects/olivier commit -m "$(cat <<'EOF'
Make the expanded queue height drag-resizable + persisted

Replace the fixed 40%-height cap with a draggable top-edge handle whose
height is seeded from and saved to layout.queue_height (clamped to screen).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (after all tasks)

```
cd /home/autarch/projects/olivier && mise exec -- flutter test 2>&1 | tail -3
cd /home/autarch/projects/olivier && mise exec -- precious lint --all 2>&1 | tail -3
cd /home/autarch/projects/olivier && mise exec -- flutter build linux --debug 2>&1 | tail -3
```

All green → final holistic review, then `superpowers:finishing-a-development-branch`.

## Notes

- Saving happens on drag-END (`onDividerDragEnd` / `onVerticalDragEnd`), which fires once per drag — so no debounce is needed (the spec's debounce note was for save-on-update).
- No Rust/bridge changes — persistence rides the existing `getSetting`/`setSetting` FFI.
- The queue height is clamped to `[minQueueHeight, 0.6 * screen]` on every load and drag, so a stale value from a bigger monitor can't push it off-screen.
