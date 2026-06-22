# Color Scheme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Olivier an intentional theme — a faint-indigo off-white base with dark-grey text, blue (the icon's high note) for general highlights, and red (the low note) reserved for the now-playing track.

**Architecture:** A single hand-pinned light `ColorScheme` in a new `lib/theme.dart`, wired once at `MaterialApp`. Because nearly every widget already reads `Theme.of(context).colorScheme`, that one change re-tints the app. Two small follow-ups: point the queue's now-playing row at `tertiaryContainer` (red) and keep the now-playing bar neutral; and route the few hardcoded `Colors.grey`/`Colors.red` literals through the theme.

**Tech Stack:** Flutter 3.44.2 (Material 3), Riverpod. Flutter via `mise exec --`.

**Commands:** `mise exec -- flutter test <path>`, `mise exec -- flutter analyze`, `mise exec -- dart format <files>`, `just lint --all`.

**Conventions:** NEVER `git add` the `TODO` file. Commit messages: plain imperative + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Task order:** 1 (theme + wire) → 2 (red now-playing row + neutral bar) → 3 (de-hardcode settings colors).

---

### Task 1: Central theme + wire at `MaterialApp`

**Files:**
- Create: `lib/theme.dart`
- Modify: `lib/main.dart` (the `MaterialApp` at ~line 195)
- Test: `test/theme_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/theme_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/theme.dart';

void main() {
  test('olivierTheme pins the brand colors', () {
    final scheme = olivierTheme().colorScheme;
    expect(scheme.brightness, Brightness.light);
    expect(scheme.primary, const Color(0xFF56A3D9)); // blue — high note
    expect(scheme.tertiary, const Color(0xFFE4572E)); // red — low note
    expect(scheme.surface, const Color(0xFFF5F6FB)); // faint-indigo bg
    expect(scheme.onSurface, const Color(0xFF2B2D38)); // dark-grey text
    expect(scheme.onSurfaceVariant, const Color(0xFF64667B));
    expect(scheme.outlineVariant, const Color(0xFFDDDFEB));
    expect(scheme.primaryContainer, const Color(0xFFD7E9F7));
    expect(scheme.tertiaryContainer, const Color(0xFFF8E0D6));
    expect(scheme.surfaceContainerHighest, const Color(0xFFE8EAF3));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/theme_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:olivier/theme.dart'` / `olivierTheme` undefined.

- [ ] **Step 3: Create the theme**

Create `lib/theme.dart`:

```dart
import 'package:flutter/material.dart';

// Brand colors from the app icon's three rising notes (assets/icon/olivier.svg).
const _blue = Color(0xFF56A3D9); // high note — general-highlight accent
const _red = Color(0xFFE4572E); // low note — now-playing marker
// gold #F4B400 (middle note) is reserved/unused in v1.

const _surface = Color(0xFFF5F6FB); // faint-indigo off-white background
const _surfaceHighest = Color(0xFFE8EAF3); // neutral elevated surfaces
const _onSurface = Color(0xFF2B2D38); // dark indigo-grey text
const _onSurfaceVariant = Color(0xFF64667B); // muted text
const _outlineVariant = Color(0xFFDDDFEB); // dividers

/// Olivier's light theme: a faint-indigo neutral base with dark-grey text, blue
/// for general highlights, and red reserved for the now-playing track. Built
/// from a blue seed (for a complete, valid tonal palette) with the brand roles
/// pinned exactly. `surfaceTint` is neutralized so elevated surfaces (the
/// now-playing bar, dialogs, menus) stay neutral instead of taking a blue tint.
ThemeData olivierTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _blue,
    brightness: Brightness.light,
  ).copyWith(
    primary: _blue,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFD7E9F7),
    onPrimaryContainer: const Color(0xFF15506F),
    tertiary: _red,
    onTertiary: Colors.white,
    tertiaryContainer: const Color(0xFFF8E0D6),
    onTertiaryContainer: const Color(0xFF7C2E16),
    surface: _surface,
    onSurface: _onSurface,
    onSurfaceVariant: _onSurfaceVariant,
    outlineVariant: _outlineVariant,
    surfaceContainerHighest: _surfaceHighest,
    surfaceTint: _surface,
    error: const Color(0xFFBA1A1A),
    onError: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- flutter test test/theme_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire the theme into the app**

In `lib/main.dart`, add the import (with the other `package:olivier/...` imports):

```dart
import 'package:olivier/theme.dart';
```

Then change the `MaterialApp` (around line 195) from:

```dart
        child: MaterialApp(
          title: 'Olivier',
          home: home ?? const BrowserPage(),
        ),
```

to:

```dart
        child: MaterialApp(
          title: 'Olivier',
          theme: olivierTheme(),
          home: home ?? const BrowserPage(),
        ),
```

- [ ] **Step 6: Analyze + full suite + lint**

Run: `mise exec -- flutter analyze` (No issues), `mise exec -- flutter test` (full suite green — existing tests wrap widgets in a bare `MaterialApp` with no theme, so they are unaffected), `just lint --all` (PASS).

- [ ] **Step 7: Commit**

```bash
git add lib/theme.dart lib/main.dart test/theme_test.dart
git commit -m "$(cat <<'EOF'
Add Olivier color scheme (faint-indigo base, blue + red accents)

Central light ColorScheme in lib/theme.dart, wired at MaterialApp: faint-
indigo off-white surfaces, dark-grey text, blue (icon high note) for general
highlights, red (low note) as tertiary. surfaceTint neutralized so elevated
surfaces stay neutral.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Red now-playing queue row + neutral now-playing bar

**Files:**
- Modify: `lib/catalog/queue_panel.dart` (the row `Material`, ~line 337)
- Modify: `lib/widgets/now_playing_bar.dart` (the `Material`, ~line 35)
- Test: `test/color_scheme_queue_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/color_scheme_queue_test.dart` (harness mirrors `test/shuffle_library_test.dart`):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/theme.dart';

class _FakeController implements ShuffleAllTarget {
  @override
  Future<void> replaceLibraryShuffled(List<String> paths) async {}
}

class _FakeQueueNotifier extends QueueNotifier {
  @override
  Future<QueueView> build() async => QueueView(
        tracks: [
          QueueTrack(path: '/q/0', title: 'Now playing', album: 'A', addedAt: 0),
          QueueTrack(path: '/q/1', title: 'Next', album: 'A', addedAt: 0),
        ],
        currentIndex: 0,
        shuffled: false,
      );
}

void main() {
  testWidgets('the now-playing queue row is red (tertiaryContainer)',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          getSettingFnProvider.overrideWithValue((key) async => null),
          libraryPathsFnProvider.overrideWithValue(() async => const []),
          shuffleAllTargetProvider.overrideWithValue(_FakeController()),
          queueProvider.overrideWith(() => _FakeQueueNotifier()),
        ],
        child: MaterialApp(
          theme: olivierTheme(),
          home: const Scaffold(body: QueuePanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rowMaterial = tester.widget<Material>(
      find
          .ancestor(of: find.text('Now playing'), matching: find.byType(Material))
          .first,
    );
    expect(rowMaterial.color, olivierTheme().colorScheme.tertiaryContainer);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- flutter test test/color_scheme_queue_test.dart`
Expected: FAIL — the row's color is `primaryContainer` (blue), not `tertiaryContainer`, so the `expect` mismatches.

(If it instead fails to build because the harness needs another provider override, add the missing override copied from `test/shuffle_library_test.dart`'s `_host`, then re-run to reach the real assertion failure.)

- [ ] **Step 3: Point the now-playing row at `tertiaryContainer`**

In `lib/catalog/queue_panel.dart`, the queue row `Material` (the current row is `selected = i == view.currentIndex`) currently reads:

```dart
                    child: Material(
                      color: selected
                          ? scheme.primaryContainer
                          : Colors.transparent,
```

Change `scheme.primaryContainer` to `scheme.tertiaryContainer`:

```dart
                    child: Material(
                      color: selected
                          ? scheme.tertiaryContainer
                          : Colors.transparent,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- flutter test test/color_scheme_queue_test.dart`
Expected: PASS.

- [ ] **Step 5: Keep the now-playing bar neutral (no blue elevation tint)**

In `lib/widgets/now_playing_bar.dart`, the bar is a `Material` at `elevation: 8` with no explicit color. Give it the neutral surface and disable its surface tint so it doesn't pick up a blue overlay. Change:

```dart
    return Material(
      elevation: 8,
      child: SizedBox(
```

to:

```dart
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      child: SizedBox(
```

(`context` is the `build(BuildContext context, WidgetRef ref)` parameter — already in scope.)

- [ ] **Step 6: Analyze + full suite + lint**

Run: `mise exec -- flutter analyze` (No issues), `mise exec -- flutter test` (full suite green), `just lint --all` (PASS).

- [ ] **Step 7: Commit**

```bash
git add lib/catalog/queue_panel.dart lib/widgets/now_playing_bar.dart test/color_scheme_queue_test.dart
git commit -m "$(cat <<'EOF'
Mark the now-playing queue row red; keep the now-playing bar neutral

The queue's current row uses tertiaryContainer (red) instead of
primaryContainer, so the playing track reads distinctly from blue selection
highlights. The now-playing bar takes the neutral surface with its surface
tint disabled so elevation doesn't blue-tint it.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Route hardcoded settings colors through the theme

**Files:**
- Modify: `lib/settings/settings_page.dart`
- Modify: `lib/settings/import_log_page.dart`

(No new test: this is a literal-to-theme refactor with no behavior change; verified by `flutter analyze`, a grep check, and the full suite. The `Theme.of(context)` calls are all inside `build`/builder scopes that already use `context`.)

- [ ] **Step 1: De-hardcode the "no folders" hint**

In `lib/settings/settings_page.dart`, change:

```dart
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No music folders yet. Add one to build your library.',
                style: TextStyle(color: Colors.grey),
              ),
            )
```

to:

```dart
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No music folders yet. Add one to build your library.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            )
```

- [ ] **Step 2: De-hardcode the scan error row**

In `lib/settings/settings_page.dart`, the scan error block (the one whose message is `'Error: ${scan.lastError}'`):

```dart
                const Icon(Icons.error_outline, color: Colors.red, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Error: ${scan.lastError}',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
```

becomes:

```dart
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Error: ${scan.lastError}',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
```

- [ ] **Step 3: De-hardcode the enrich blurb**

In `lib/settings/settings_page.dart`, change:

```dart
          const Text(
            'Fetch readings, translations, and original dates from MusicBrainz '
            'for your tagged files. Runs automatically after a scan.',
            style: TextStyle(color: Colors.grey),
          ),
```

to:

```dart
          Text(
            'Fetch readings, translations, and original dates from MusicBrainz '
            'for your tagged files. Runs automatically after a scan.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
```

- [ ] **Step 4: De-hardcode the enrich error row**

In `lib/settings/settings_page.dart`, the enrich error block (message `'Enrich error: ${enrich.lastError}'`):

```dart
                const Icon(Icons.error_outline, color: Colors.red, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Enrich error: ${enrich.lastError}',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
```

becomes:

```dart
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Enrich error: ${enrich.lastError}',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
```

- [ ] **Step 5: De-hardcode the language-leads blurb**

In `lib/settings/settings_page.dart`, change:

```dart
          const Text(
            'Language leads: which script shows first in bilingual rows.',
            style: TextStyle(color: Colors.grey),
          ),
```

to:

```dart
          Text(
            'Language leads: which script shows first in bilingual rows.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
```

- [ ] **Step 6: De-hardcode the import-log empty state**

In `lib/settings/import_log_page.dart`, change:

```dart
            return const Center(
              child: Text('No import activity logged yet.',
                  style: TextStyle(color: Colors.grey)),
            );
```

to:

```dart
            return Center(
              child: Text('No import activity logged yet.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            );
```

(`context` here is the builder's `BuildContext` already in scope at this return.)

- [ ] **Step 7: Verify, analyze, full suite, lint**

Run:
```bash
grep -n 'Colors\.grey\|Colors\.red' lib/settings/settings_page.dart lib/settings/import_log_page.dart
```
Expected: no matches (all routed through the theme).

Then `mise exec -- flutter analyze` (No issues — watch for any leftover `prefer_const` lints from the `const` removals and fix by adding `const` to inner literals as shown), `mise exec -- flutter test` (full suite green), `just lint --all` (PASS).

- [ ] **Step 8: Commit**

```bash
git add lib/settings/settings_page.dart lib/settings/import_log_page.dart
git commit -m "$(cat <<'EOF'
Route settings/import-log colors through the theme

Hardcoded Colors.grey -> onSurfaceVariant and Colors.red -> colorScheme.error
in the settings and import-log pages, so they follow the Olivier theme.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `mise exec -- flutter test` — full suite green (incl. `theme_test`, `color_scheme_queue_test`).
- [ ] `mise exec -- flutter analyze` — No issues.
- [ ] `just lint --all` — PASS.
- [ ] Manual (`just run`): faint-indigo off-white background, dark-grey text; blue selected rows / sliders / links / buttons / focus rings; the queue's now-playing row is red; the now-playing bar is neutral (not blue-tinted) at elevation; settings hints are grey and error rows red.

## Touched files

| File | Change |
|------|--------|
| `lib/theme.dart` | new — `olivierTheme()` `ColorScheme` |
| `lib/main.dart` | wire `theme: olivierTheme()` |
| `lib/catalog/queue_panel.dart` | now-playing row → `tertiaryContainer` |
| `lib/widgets/now_playing_bar.dart` | neutral surface + no surface tint |
| `lib/settings/settings_page.dart`, `import_log_page.dart` | de-hardcode `Colors.grey`/`Colors.red` |
| `test/theme_test.dart`, `test/color_scheme_queue_test.dart` | new tests |
