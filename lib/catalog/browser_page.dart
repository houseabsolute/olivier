import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multi_split_view/multi_split_view.dart';
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
  late final MultiSplitViewController _rightController;
  late final MultiSplitViewController _splitController;

  @override
  void initState() {
    super.initState();
    // Album over Track (vertical). Created first — referenced by the outer split.
    _rightController = MultiSplitViewController(areas: [
      Area(
        flex: defaultRightPaneFlex.$1,
        min: 80,
        builder: (c, a) => const AlbumColumn(),
      ),
      Area(
        flex: defaultRightPaneFlex.$2,
        min: 80,
        builder: (c, a) => const TrackColumn(),
      ),
    ]);
    // Artist | right pane (horizontal).
    _splitController = MultiSplitViewController(areas: [
      Area(
        flex: defaultArtistFlex.$1,
        min: 220,
        builder: (c, a) => const ArtistColumn(),
      ),
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
      try {
        final s = await ref.read(layoutSettingsProvider.future);
        if (!mounted) return;
        // Update flex in place rather than replacing the area lists. Replacing
        // the outer areas would mint a fresh `_RightPane` (new Area id) and
        // re-bind `_rightController` to a second MultiSplitView before the old
        // one deactivates, which the controller's sharing guard rejects.
        _splitController.areas[0].flex = s.artistFlex.$1;
        _splitController.areas[1].flex = s.artistFlex.$2;
        _rightController.areas[0].flex = s.rightPaneFlex.$1;
        _rightController.areas[1].flex = s.rightPaneFlex.$2;
      } catch (_) {
        // Best-effort: keep the default flex already seeded above. Mirrors
        // QueuePanel's defensive load.
      }
    });
  }

  void _saveArtistFlex() {
    final a = _splitController.areas;
    ref.read(setSettingFnProvider)(
      layoutArtistsKey,
      formatFlexPair(
        (a[0].flex ?? defaultArtistFlex.$1, a[1].flex ?? defaultArtistFlex.$2),
      ),
    );
  }

  void _saveRightPaneFlex() {
    final a = _rightController.areas;
    ref.read(setSettingFnProvider)(
      layoutRightPaneKey,
      formatFlexPair(
        (
          a[0].flex ?? defaultRightPaneFlex.$1,
          a[1].flex ?? defaultRightPaneFlex.$2,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _splitController.dispose();
    _rightController.dispose();
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
          Expanded(
            child: MultiSplitView(
              controller: _splitController,
              onDividerDragEnd: (_) => _saveArtistFlex(),
            ),
          ),
          // Queue panel between the browse split and the now-playing bar.
          // Collapses to a header; expands to a reorderable track list.
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
