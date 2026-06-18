import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/main.dart' show audioHandler;
import 'package:olivier/settings/settings_page.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/widgets/now_playing_bar.dart';

class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key, this.nowPlaying});

  /// The bottom transport bar. Injectable so the page can be widget-tested
  /// without the live, uninitialized global [audioHandler]. Defaults to the
  /// real [NowPlayingBar] in production.
  final Widget? nowPlaying;

  @override
  ConsumerState<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends ConsumerState<BrowserPage> {
  late final MultiSplitViewController _splitController;

  @override
  void initState() {
    super.initState();
    _splitController = MultiSplitViewController(
      areas: [
        // Wide Artist column (≈ 33% default).
        Area(
          flex: 1,
          min: 220,
          builder: (ctx, area) => const ArtistColumn(),
        ),
        // Right pane (≈ 67% default): Albums stacked over Tracks.
        Area(
          flex: 2,
          min: 320,
          builder: (ctx, area) => const _RightPane(),
        ),
      ],
    );
    // Hydrate persisted root folders after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(scanControllerProvider.notifier).loadRoots();
    });
  }

  @override
  void dispose() {
    _splitController.dispose();
    super.dispose();
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Olivier'),
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
          Expanded(child: MultiSplitView(controller: _splitController)),
          // Collapsed queue-panel shell between the browse split and the
          // now-playing bar. Data/wiring arrive in later slices.
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

/// The right pane of the browse split: the album list stacked over the track
/// list, separated by a hairline divider. Each list takes half the height.
class _RightPane extends StatelessWidget {
  const _RightPane();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Expanded(child: AlbumColumn()),
        Divider(height: 1),
        Expanded(child: TrackColumn()),
      ],
    );
  }
}
