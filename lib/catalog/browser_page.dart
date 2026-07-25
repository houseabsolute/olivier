import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart'
    show selectedAlbumObjectProvider;
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/main.dart' show audioHandler;
import 'package:olivier/playlists/playlists_page.dart';
import 'package:olivier/settings/settings_page.dart';
import 'package:olivier/state/browse_level.dart';
import 'package:olivier/state/layout_settings.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_view.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/widgets/now_playing_bar.dart';
import 'package:olivier/widgets/queue_swipe_target.dart';
import 'package:olivier/widgets/resizable_split.dart';
import 'package:olivier/widgets/search_results_panel.dart';
import 'package:olivier/widgets/top_controls.dart';

/// How long the queue takes to slide in or out. Short enough to feel like a
/// direct response to the swipe rather than a transition to sit through.
const Duration kQueueRevealDuration = Duration(milliseconds: 180);

const _queueKey = ValueKey('queue');

/// The first pane's fraction of a persisted `(f0, f1)` flex pair.
double _ratioOf((double, double) flex) => flex.$1 / (flex.$1 + flex.$2);

class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key, this.nowPlaying, this.topControls});

  /// The bottom transport bar. Injectable so the page can be widget-tested
  /// without the live, uninitialized global [audioHandler]. Defaults to the
  /// real [NowPlayingBar] in production.
  final Widget? nowPlaying;

  /// The top control bar (transport + volume). Injectable for the same reason
  /// as [nowPlaying]; defaults to the real [TopControls] in production.
  final Widget? topControls;

  @override
  ConsumerState<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends ConsumerState<BrowserPage> {
  /// Narrow layout only: the app bar shows the search field instead of the
  /// level title. There isn't room for both at phone widths.
  bool _searchOpen = false;

  // Fraction (0..1) of the available extent given to the FIRST pane of each
  // split (artist of artist|right; album of album|track), seeded from the
  // persisted flex pairs.
  double _artistRatio = _ratioOf(defaultArtistFlex);
  double _albumRatio = _ratioOf(defaultRightPaneFlex);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ref.read(scanControllerProvider.notifier).loadRoots();
      try {
        final s = await ref.read(layoutSettingsProvider.future);
        if (!mounted) return;
        setState(() {
          _artistRatio = _ratioOf(s.artistFlex);
          _albumRatio = _ratioOf(s.rightPaneFlex);
        });
      } catch (_) {
        // Best-effort: keep the defaults already seeded above.
      }
    });
  }

  void _saveRatio(String key, double ratio) {
    ref.read(setSettingFnProvider)(key, formatFlexPair((ratio, 1 - ratio)));
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);

    // One-shot completion / error message. Clearing first avoids the
    // ScaffoldMessenger assertion that overlapping snackbars trigger.
    ref.listen<ScanState>(scanControllerProvider, (prev, next) {
      final messenger = ScaffoldMessenger.of(context);
      if (next.lastError != null && next.lastError != prev?.lastError) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text('Scan failed — ${next.lastError}')),
          );
      } else if ((prev?.scanning ?? false) &&
          !next.scanning &&
          next.lastError == null) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'Scan complete — ${next.filesSeen} files, ${next.filesChanged} new',
              ),
            ),
          );
      }
    });

    final queueExpanded = ref.watch(queueExpandedProvider);
    // Watched here rather than inside the LayoutBuilder below: its builder runs
    // during layout, so a provider watched from there registers its dependency
    // in the wrong phase and the next change asserts when it rebuilds.
    final level = ref.watch(browseLevelProvider);
    final narrowTitle = _narrowTitle(ref, level, queueExpanded);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            ref.read(searchFocusNodeProvider).requestFocus(),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
            ref.read(searchFocusNodeProvider).requestFocus(),
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < kNarrowBrowseWidth;
          return narrow
              ? _narrowScaffold(
                  context, ref, scan, queueExpanded, level, narrowTitle)
              : _wideScaffold(context, ref, scan, queueExpanded);
        },
      ),
    );
  }

  /// The three-pane cascade. Unchanged from before the narrow layout existed.
  Widget _wideScaffold(
    BuildContext context,
    WidgetRef ref,
    ScanState scan,
    bool queueExpanded,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: widget.topControls ?? TopControls(audioHandler: audioHandler),
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_play),
            tooltip: 'Playlists',
            onPressed: () => _openPlaylists(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => _openSettings(context, ref),
          ),
        ],
        bottom: scan.scanning ? _scanProgressBar(scan) : null,
      ),
      body: Stack(
        children: [
          // Not animated here, deliberately: the cascade and the expanded
          // queue have incompatible flex structures (Expanded vs intrinsic),
          // and every way of tweening between them either unbounds the
          // Column's constraints or fights the user's own drag-to-size on the
          // resizable split. The narrow layout, where the queue is a separate
          // full-screen view, animates instead.
          Column(
            children: [
              if (!queueExpanded)
                Expanded(
                  // Artist | right pane (horizontal), with the right pane
                  // stacking Album over Track (vertical). Custom
                  // ResizableSplit (opaque drag handle) — see its doc for why
                  // multi_split_view's translucent divider didn't resize here.
                  child: ResizableSplit(
                    axis: Axis.horizontal,
                    ratio: _artistRatio,
                    minFirst: 220,
                    minSecond: 320,
                    onRatioSettled: (r) {
                      _artistRatio = r;
                      _saveRatio(layoutArtistsKey, r);
                    },
                    first: const ArtistColumn(),
                    second: ResizableSplit(
                      axis: Axis.vertical,
                      ratio: _albumRatio,
                      minFirst: 80,
                      minSecond: 80,
                      onRatioSettled: (r) {
                        _albumRatio = r;
                        _saveRatio(layoutRightPaneKey, r);
                      },
                      first: const AlbumColumn(),
                      second: const TrackColumn(),
                    ),
                  ),
                ),
              if (queueExpanded)
                const Expanded(child: QueuePanel())
              else
                const QueuePanel(),
            ],
          ),
          const SearchResultsPanel(),
        ],
      ),
      bottomNavigationBar: QueueSwipeTarget(
        child: widget.nowPlaying ?? NowPlayingBar(audioHandler: audioHandler),
      ),
    );
  }

  /// One level of the cascade at a time, drilled into. The level is derived
  /// from the selection (see [browseLevelProvider]), so search lands on the
  /// right screen without knowing this layout exists.
  Widget _narrowScaffold(
    BuildContext context,
    WidgetRef ref,
    ScanState scan,
    bool queueExpanded,
    BrowseLevel level,
    String title,
  ) {
    final atRoot = level == BrowseLevel.artists;

    return PopScope(
      // Back walks up the cascade; only the artist list exits the app.
      canPop: atRoot && !queueExpanded,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (queueExpanded) {
          ref.read(queueExpandedProvider.notifier).collapse();
        } else {
          ref.read(browseLevelProvider.notifier).up();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: (atRoot && !queueExpanded)
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: () {
                    if (queueExpanded) {
                      ref.read(queueExpandedProvider.notifier).collapse();
                    } else {
                      ref.read(browseLevelProvider.notifier).up();
                    }
                  },
                ),
          title: _searchOpen
              ? (widget.topControls ?? TopControls(audioHandler: audioHandler))
              : Text(title, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              icon: Icon(_searchOpen ? Icons.search_off : Icons.search),
              tooltip: _searchOpen ? 'Close search' : 'Search',
              onPressed: () {
                setState(() => _searchOpen = !_searchOpen);
                if (_searchOpen) {
                  ref.read(searchFocusNodeProvider).requestFocus();
                } else {
                  ref.read(searchQueryProvider.notifier).clear();
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.queue_music),
              tooltip: queueExpanded ? 'Back to library' : 'Queue',
              onPressed: () =>
                  ref.read(queueExpandedProvider.notifier).toggle(),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => v == 'playlists'
                  ? _openPlaylists(context, ref)
                  : _openSettings(context, ref),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'playlists', child: Text('Playlists')),
                PopupMenuItem(value: 'settings', child: Text('Settings')),
              ],
            ),
          ],
          bottom: scan.scanning ? _scanProgressBar(scan) : null,
        ),
        body: Stack(
          children: [
            AnimatedSwitcher(
              duration: kQueueRevealDuration,
              // The queue slides up over the library and back down; the library
              // just cross-fades, so only one thing appears to move.
              transitionBuilder: (child, animation) => child.key == _queueKey
                  ? SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 1),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    )
                  : FadeTransition(opacity: animation, child: child),
              child: queueExpanded
                  ? const QueuePanel(key: _queueKey)
                  : KeyedSubtree(
                      key: ValueKey(level),
                      child: switch (level) {
                        BrowseLevel.artists => const ArtistColumn(narrow: true),
                        BrowseLevel.albums => const AlbumColumn(narrow: true),
                        BrowseLevel.tracks => const TrackColumn(narrow: true),
                      },
                    ),
            ),
            const SearchResultsPanel(),
          ],
        ),
        bottomNavigationBar: QueueSwipeTarget(
          child: widget.nowPlaying ?? NowPlayingBar(audioHandler: audioHandler),
        ),
      ),
    );
  }

  /// What the narrow app bar says we're looking at.
  String _narrowTitle(WidgetRef ref, BrowseLevel level, bool queueExpanded) {
    if (queueExpanded) return 'Queue';
    switch (level) {
      case BrowseLevel.artists:
        return 'Artists';
      case BrowseLevel.albums:
        final mbid = ref.watch(selectedArtistProvider);
        final artists = ref.watch(artistsProvider).value ?? const [];
        for (final a in artists) {
          if (a.mbid == mbid) return a.name;
        }
        return 'Albums';
      case BrowseLevel.tracks:
        return ref.watch(selectedAlbumObjectProvider)?.title ?? 'Tracks';
    }
  }

  void _openPlaylists(BuildContext context, WidgetRef ref) {
    ref.read(searchQueryProvider.notifier).clear();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlaylistsPage()),
    );
  }

  void _openSettings(BuildContext context, WidgetRef ref) {
    // Dismiss the search overlay before leaving the browse page.
    ref.read(searchQueryProvider.notifier).clear();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
  }

  PreferredSizeWidget _scanProgressBar(ScanState scan) {
    final queued = scan.queued > 0 ? ' · ${scan.queued} queued' : '';
    return PreferredSize(
      preferredSize: const Size.fromHeight(30),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'Scanning… ${scan.filesSeen} files (${scan.filesChanged} new)$queued',
            ),
          ],
        ),
      ),
    );
  }
}
