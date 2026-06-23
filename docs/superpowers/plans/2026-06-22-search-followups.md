# Search Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two polish fixes to the global-search overlay: scroll the keyboard-highlighted row into view, and dismiss the overlay when opening Settings.

**Architecture:** Make `_ResultsList` (in `lib/widgets/search_results_panel.dart`) stateful so it can `Scrollable.ensureVisible` the highlighted row on a highlight change; clear `searchQueryProvider` in `BrowserPage`'s Settings button.

**Tech Stack:** Dart/Flutter/Riverpod. Flutter via `mise exec --`.

**Commands:** `mise exec -- flutter test <path>`, `mise exec -- flutter analyze`, `mise exec -- dart format <files>`, `just lint --all`.

**Conventions:** NEVER `git add` the `TODO` file. Commit messages: plain imperative + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**Task order:** 1 (overlay scroll-into-view) → 2 (Settings dismiss).

---

### Task 1: Overlay scroll-into-view

**Files:**
- Modify: `lib/widgets/search_results_panel.dart` (`_ResultsList`)
- Test: `test/search_results_panel_test.dart` (extend)

- [ ] **Step 1: Write the failing test**

Append to `test/search_results_panel_test.dart` (it already imports `material.dart`, the schema, providers, and the panel; add `import 'package:flutter/widgets.dart';` only if `ScrollableState` isn't resolved):

```dart
  testWidgets('moving the highlight deep scrolls the dropdown to it',
      (tester) async {
    final artists = [
      for (var i = 0; i < 8; i++)
        Artist(
            mbid: 'A$i', name: 'Artist $i', sortName: 'Artist $i',
            transliteration: null, nameOriginal: null),
    ];
    final albums = [
      for (var i = 0; i < 8; i++)
        Album(
            releaseMbid: 'R$i', title: 'Album $i', albumArtist: 'x',
            originalYear: null, reissueYear: null, titleTranslit: null,
            titleTranslate: null, addedAt: 0, albumArtistOriginal: null,
            albumArtistReading: null, albumArtistMbid: 'A0'),
    ];
    final tracks = [
      for (var i = 0; i < 8; i++)
        SearchTrack(
            id: i, title: 'Track $i', titleTranslit: null, titleTranslate: null,
            albumArtist: null, albumArtistOriginal: null,
            albumArtistReading: null, albumArtistMbid: 'A0', releaseMbid: 'R0'),
    ];
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue(':memory:'),
      getSettingFnProvider.overrideWithValue((key) async => null),
      searchCatalogFnProvider.overrideWithValue(
          (q, limit) async => SearchResults(
              artists: artists, albums: albums, tracks: tracks)),
    ]);
    addTearDown(container.dispose);
    container.read(searchQueryProvider.notifier).set('x');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: Stack(children: [SearchResultsPanel()])),
      ),
    ));
    await tester.pumpAndSettle();

    // Highlight the last (deepest) hit; the dropdown must scroll to reveal it.
    container.read(highlightedSearchIndexProvider.notifier).set(23);
    await tester.pumpAndSettle();

    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.pixels, greaterThan(0.0));
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/search_results_panel_test.dart`
Expected: the new test FAILS (`position.pixels` is `0.0` — the dropdown never scrolls to the highlight). The two existing panel tests still pass.

- [ ] **Step 3: Make `_ResultsList` stateful and scroll to the highlight**

In `lib/widgets/search_results_panel.dart`, replace the entire `class _ResultsList extends ConsumerWidget { ... }` with this version (same rendering; now stateful, holds a `GlobalKey` for the highlighted row, and `ensureVisible`s it when the highlight changes — `_groupFull`/`_footer`/`_header` are unchanged in body, just moved into the State; `_row` gains a `Key?` param applied to its `InkWell`):

```dart
class _ResultsList extends ConsumerStatefulWidget {
  const _ResultsList({required this.results});
  final SearchResults results;

  @override
  ConsumerState<_ResultsList> createState() => _ResultsListState();
}

class _ResultsListState extends ConsumerState<_ResultsList> {
  final _highlightKey = GlobalKey();

  void _ensureHighlightVisible(int index) {
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _highlightKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 120),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = widget.results;
    final hits = flattenHits(results);
    if (hits.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No matches'),
      );
    }
    final leads = ref.watch(languageLeadsProvider);
    final highlighted = ref.watch(highlightedSearchIndexProvider);
    final scheme = Theme.of(context).colorScheme;

    // Scroll the highlighted row into view as the keyboard moves it.
    ref.listen<int>(highlightedSearchIndexProvider,
        (_, next) => _ensureHighlightVisible(next));

    final children = <Widget>[];
    SearchHit? prev;
    for (var i = 0; i < hits.length; i++) {
      final hit = hits[i];
      if (prev == null || hit.runtimeType != prev.runtimeType) {
        children.add(_header(
            context,
            switch (hit) {
              ArtistHit() => 'Artists',
              AlbumHit() => 'Albums',
              TrackHit() => 'Tracks',
            }));
      }
      final isHighlighted = i == highlighted;
      children.add(_row(context, ref, hit, leads, isHighlighted, scheme,
          isHighlighted ? _highlightKey : null));
      final lastOfKind =
          i == hits.length - 1 || hits[i + 1].runtimeType != hit.runtimeType;
      if (lastOfKind && _groupFull(hit, results)) {
        children.add(_footer(context));
      }
      prev = hit;
    }
    return ListView(
        shrinkWrap: true, padding: EdgeInsets.zero, children: children);
  }

  bool _groupFull(SearchHit h, SearchResults r) => switch (h) {
        ArtistHit() => r.artists.length >= kSearchGroupLimit,
        AlbumHit() => r.albums.length >= kSearchGroupLimit,
        TrackHit() => r.tracks.length >= kSearchGroupLimit,
      };

  Widget _footer(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
        child: Text('Refine search to narrow results',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                )),
      );

  Widget _header(BuildContext context, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Text(label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                )),
      );

  Widget _row(BuildContext context, WidgetRef ref, SearchHit hit,
      LanguageLeads leads, bool highlighted, ColorScheme scheme, Key? key) {
    final (original, translit, translate, subtitle, icon) = switch (hit) {
      ArtistHit(:final artist) => (
          artist.nameOriginal ?? artist.name,
          artist.transliteration,
          null,
          null,
          Icons.person_outline,
        ),
      AlbumHit(:final album) => (
          album.title,
          album.titleTranslit,
          album.titleTranslate,
          album.albumArtist,
          Icons.album_outlined,
        ),
      TrackHit(:final track) => (
          track.title,
          track.titleTranslit,
          track.titleTranslate,
          track.albumArtist,
          Icons.music_note_outlined,
        ),
    };
    return InkWell(
      key: key,
      onTap: () => selectHit(ref, hit),
      child: Container(
        color: highlighted ? scheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: BilingualText(
                original: original,
                translit: translit,
                translate: translate,
                leads: leads,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- flutter test test/search_results_panel_test.dart`
Expected: all 3 tests pass (the two existing + the new scroll test).

- [ ] **Step 5: Analyze, format, full suite, lint, commit**

Run: `mise exec -- flutter analyze` (No issues), `mise exec -- dart format lib/widgets/search_results_panel.dart test/search_results_panel_test.dart`, `mise exec -- flutter test` (full suite green), `just lint --all` (PASS). Then:

```bash
git add lib/widgets/search_results_panel.dart test/search_results_panel_test.dart
git commit -m "$(cat <<'EOF'
Scroll the search overlay to the keyboard-highlighted row

_ResultsList is now stateful: it tags the highlighted row with a GlobalKey
and Scrollable.ensureVisible's it when the highlight moves, so arrowing past
the fold keeps the selection visible.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Dismiss the overlay when opening Settings

**Files:**
- Modify: `lib/catalog/browser_page.dart` (Settings `IconButton`)
- Test: `test/search_settings_dismiss_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/search_settings_dismiss_test.dart`. Build `BrowserPage` with the provider overrides an existing BrowserPage widget test uses (READ one — e.g. `test/browser_page_resize_test.dart` or `test/queue_fullscreen_test.dart` — and copy its `ProviderScope` override list + any `topControls`/`nowPlaying` stubs so the page builds without the live FFI). Then:

```dart
  testWidgets('opening Settings clears the active search query', (tester) async {
    // ... build `container` with the same overrides an existing BrowserPage
    //     widget test uses (dbPathProvider, getSettingFnProvider, the list
    //     providers, queue providers, etc.) ...
    container.read(searchQueryProvider.notifier).set('ringo');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: BrowserPage()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(); // runs onPressed (clears the query) + starts the push

    expect(container.read(searchQueryProvider), '');
  });
```

If pushing the real `SettingsPage` throws in the test (missing providers), either (a) add the overrides `SettingsPage` needs (copy from a settings test), or (b) assert immediately after the single `tester.pump()` — the clear runs synchronously in `onPressed` before the route mounts — and tolerate a later route-build exception with `tester.takeException()` if necessary. Prefer (a).

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/search_settings_dismiss_test.dart`
Expected: FAIL — `searchQueryProvider` is still `'ringo'` after tapping Settings (the button doesn't clear it yet).

- [ ] **Step 3: Clear the query in the Settings button**

In `lib/catalog/browser_page.dart`, change the Settings `IconButton` from:

```dart
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              ),
            ),
```

to:

```dart
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () {
                // Dismiss the search overlay before leaving the browse page.
                ref.read(searchQueryProvider.notifier).clear();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                );
              },
            ),
```

(`ref` is in scope — `BrowserPage`'s State is a `ConsumerState`; `searchQueryProvider` is already available via the existing `package:olivier/state/providers.dart` import.)

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- flutter test test/search_settings_dismiss_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze, format, full suite, lint, commit**

Run: `mise exec -- flutter analyze` (No issues), `mise exec -- dart format lib/catalog/browser_page.dart test/search_settings_dismiss_test.dart`, `mise exec -- flutter test` (full suite green), `just lint --all` (PASS). Then:

```bash
git add lib/catalog/browser_page.dart test/search_settings_dismiss_test.dart
git commit -m "$(cat <<'EOF'
Clear the search query when opening Settings

So the results overlay doesn't linger under the pushed Settings route.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `mise exec -- flutter test` — green (incl. the new scroll + Settings-dismiss tests).
- [ ] `mise exec -- flutter analyze` — No issues; `just lint --all` — PASS.
- [ ] Manual (`just run`): type a broad query so results overflow; `↓` past the fold keeps the highlight visible; open Settings → the overlay is gone (query cleared).

## Touched files

| File | Change |
|------|--------|
| `lib/widgets/search_results_panel.dart` | `_ResultsList` stateful + `ensureVisible` highlight |
| `lib/catalog/browser_page.dart` | clear query in the Settings button |
| `test/search_results_panel_test.dart` | scroll-into-view test |
| `test/search_settings_dismiss_test.dart` | Settings-dismiss test (new) |
