import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

class AlbumColumn extends ConsumerWidget {
  const AlbumColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsProvider);
    return albumsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (albums) => _AlbumList(albums: albums),
    );
  }
}

class _AlbumList extends ConsumerWidget {
  const _AlbumList({required this.albums});

  final List<Album> albums;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedAlbumProvider);
    if (albums.isEmpty) {
      return const Center(child: Text('Select an artist'));
    }
    return ListView.builder(
      itemCount: albums.length,
      itemExtent: 48,
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      itemBuilder: (context, index) {
        final album = albums[index];
        final isSelected = selected == album.releaseMbid;
        final year = album.originalYear ?? album.reissueYear ?? '';
        final label = year.isNotEmpty ? '${album.title} ($year)' : album.title;
        return InkWell(
          key: ValueKey(album.releaseMbid),
          onTap: () {
            ref.read(selectedAlbumProvider.notifier).select(album.releaseMbid);
            // Store the full album object so the track column can access title.
            ref.read(selectedAlbumObjectProvider.notifier).select(album);
          },
          child: Container(
            color: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                Expanded(child: _RowLabel(text: label)),
                IconButton(
                  icon: const Icon(Icons.play_arrow, size: 20),
                  tooltip: 'Play album',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    ref.read(playbackControllerProvider).playAlbum(
                          album.releaseMbid,
                          album.title,
                        );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      overflow: TextOverflow.ellipsis,
    );
  }
}
