import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/main.dart' show audioHandler;
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/now_playing_bar.dart';

class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key});

  @override
  ConsumerState<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends ConsumerState<BrowserPage> {
  late final MultiSplitViewController _splitController;
  bool _scanning = false;
  int _scanSeen = 0;
  int _scanChanged = 0;

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
  }

  @override
  void dispose() {
    _splitController.dispose();
    super.dispose();
  }

  Future<void> _scanFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || !mounted) return;

    final dbPath = ref.read(dbPathProvider);
    setState(() {
      _scanning = true;
      _scanSeen = 0;
      _scanChanged = 0;
    });

    try {
      await for (final progress in scanLibrary(dbPath: dbPath, roots: [dir])) {
        if (mounted) {
          setState(() {
            _scanSeen = progress.filesSeen.toInt();
            _scanChanged = progress.filesChanged.toInt();
          });
        }
        if (progress.done) break;
      }
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Scan complete — $_scanSeen files, $_scanChanged new')),
        );
      }
      ref.invalidate(artistsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Olivier'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Scan folder',
            onPressed: _scanning ? null : _scanFolder,
          ),
        ],
        bottom: _scanning
            ? PreferredSize(
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
                      Text('Scanning… $_scanSeen files ($_scanChanged new)'),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: MultiSplitView(controller: _splitController),
      bottomNavigationBar: NowPlayingBar(audioHandler: audioHandler),
    );
  }
}
