import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/main.dart' show audioHandler;
import 'package:olivier/settings/settings_page.dart';
import 'package:olivier/state/layout_settings.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/widgets/now_playing_bar.dart';
import 'package:olivier/widgets/resizable_split.dart';
import 'package:olivier/widgets/top_controls.dart';

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

    return Scaffold(
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
      body: Column(
        children: [
          if (!queueExpanded)
            Expanded(
              // Artist | right pane (horizontal), with the right pane stacking
              // Album over Track (vertical). Custom ResizableSplit (opaque drag
              // handle) — see its doc for why multi_split_view's translucent
              // divider didn't resize here.
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
      bottomNavigationBar:
          widget.nowPlaying ?? NowPlayingBar(audioHandler: audioHandler),
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
