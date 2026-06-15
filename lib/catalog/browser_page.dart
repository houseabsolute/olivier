import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/main.dart' show audioHandler;
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/widgets/now_playing_bar.dart';

class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key});

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
        Area(min: 160, builder: (ctx, area) => const ArtistColumn()),
        Area(min: 160, builder: (ctx, area) => const AlbumColumn()),
        Area(min: 240, builder: (ctx, area) => const TrackColumn()),
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

  Future<void> _addFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    // Fire-and-forget: the controller queues and scans; the AppBar shows progress.
    await ref.read(scanControllerProvider.notifier).addFolder(dir);
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
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Add music folder',
            onPressed: _addFolder,
          ),
        ],
        bottom: scan.scanning ? _scanProgressBar(scan) : null,
      ),
      body: MultiSplitView(controller: _splitController),
      bottomNavigationBar: NowPlayingBar(audioHandler: audioHandler),
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
