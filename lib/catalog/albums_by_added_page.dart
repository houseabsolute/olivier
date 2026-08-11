import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart'
    show queueControllerProvider, selectedAlbumObjectProvider;
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/playlists/add_to_playlist_dialog.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_view.dart';
import 'package:olivier/widgets/album_cover.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/context_menu.dart';
import 'package:olivier/widgets/info_dialog.dart';
import 'package:olivier/widgets/track_meta.dart';

/// Every album in the library, ordered by when it was added — the one view that
/// crosses artists, so it lives on its own page rather than in the artist ⇒
/// album ⇒ track cascade. Tapping a row drops back into the cascade on that
/// album.
class AlbumsByAddedPage extends ConsumerWidget {
  const AlbumsByAddedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final newestFirst = ref.watch(albumsAddedNewestFirstProvider);
    final albumsAsync = ref.watch(albumsByAddedProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Albums by date added'),
        actions: [
          // One control, both directions: the icon shows which way the list
          // currently runs, the tooltip says what pressing it does.
          IconButton(
            icon: Icon(
              newestFirst ? Icons.arrow_downward : Icons.arrow_upward,
            ),
            tooltip: newestFirst ? 'Show oldest first' : 'Show newest first',
            onPressed: () =>
                ref.read(albumsAddedNewestFirstProvider.notifier).toggle(),
          ),
        ],
      ),
      body: albumsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
        data: (albums) => albums.isEmpty
            ? const Center(child: Text('No albums in the library yet'))
            : _AlbumsByAddedList(albums: albums),
      ),
    );
  }
}

class _AlbumsByAddedList extends ConsumerWidget {
  const _AlbumsByAddedList({required this.albums});

  final List<Album> albums;

  /// Leave this page and show [album] in the browse cascade — the same
  /// selection a search hit makes (see `selectHit`), plus the album object the
  /// track column reads its title from.
  void _openInBrowse(BuildContext context, WidgetRef ref, Album album) {
    ref.read(queueExpandedProvider.notifier).collapse();
    ref.read(selectedArtistProvider.notifier).select(album.albumArtistMbid);
    ref.read(selectedAlbumProvider.notifier).select(album.releaseMbid);
    ref.read(selectedAlbumObjectProvider.notifier).select(album);
    Navigator.of(context).pop();
  }

  Future<void> _enqueue(WidgetRef ref, QueueEntityRef entity) async {
    final paths = await resolveEntityPaths(
      entity,
      ref.read(entityPathFnsProvider),
    );
    if (paths.isEmpty) return;
    await ref.read(queueControllerProvider).append(paths);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leads = ref.watch(languageLeadsProvider);
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    return ListView.builder(
      itemCount: albums.length,
      itemExtent: bilingualRowExtent(context, 56),
      itemBuilder: (context, index) {
        final album = albums[index];
        final year = album.originalYear ?? album.reissueYear ?? '';
        final entity = QueueEntityRef.album(album.releaseMbid);
        return RowContextMenu(
          key: ValueKey(album.releaseMbid),
          entity: entity,
          onAddToQueue: (e) => _enqueue(ref, e),
          onAddToPlaylist: (e) => showAddToPlaylistDialog(context, ref, e),
          onInfo: (_) => showInfoDialog(
            context,
            title: 'Album',
            fields: albumInfoFields(album),
            header: AlbumCover(releaseMbid: album.releaseMbid, size: 220),
          ),
          child: InkWell(
            onTap: () => _openInBrowse(context, ref, album),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  AlbumCover(releaseMbid: album.releaseMbid, size: 40),
                  const SizedBox(width: 8),
                  Expanded(
                    child: BilingualText(
                      original: album.title,
                      translit: album.titleTranslit,
                      translate: album.titleTranslate,
                      leads: leads,
                      suffix: year.isNotEmpty ? ' ($year)' : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      album.albumArtistOriginal ?? album.albumArtist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: kTrackMetaDateWidth,
                    child: Tooltip(
                      message: 'Date added',
                      child: Text(
                        formatMetaDate(album.addedAt),
                        textAlign: TextAlign.right,
                        style: muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
