import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/catalog_mutation.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/album_cover.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/context_menu.dart';
import 'package:olivier/widgets/info_dialog.dart';
import 'package:olivier/widgets/title_override_dialog.dart';

Future<void> _enqueue(WidgetRef ref, QueueEntityRef entity) async {
  final paths = await resolveEntityPaths(
    entity,
    ref.read(entityPathFnsProvider),
  );
  if (paths.isEmpty) return;
  await ref.read(queueControllerProvider).append(paths);
}

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
    final leads = ref.watch(languageLeadsProvider);
    if (albums.isEmpty) {
      return const Center(child: Text('Select an artist'));
    }
    return ListView.builder(
      itemCount: albums.length,
      itemExtent: bilingualRowExtent(context, 48),
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      itemBuilder: (context, index) {
        final album = albums[index];
        final isSelected = selected == album.releaseMbid;
        final year = album.originalYear ?? album.reissueYear ?? '';
        final entity = QueueEntityRef.album(album.releaseMbid);
        return LongPressDraggable<QueueEntityRef>(
          data: entity,
          feedback: Material(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(album.title),
            ),
          ),
          child: RowContextMenu(
            entity: entity,
            onAddToQueue: (e) => _enqueue(ref, e),
            onInfo: (_) => showInfoDialog(context,
                title: 'Album',
                fields: albumInfoFields(album),
                header: AlbumCover(releaseMbid: album.releaseMbid, size: 220)),
            onRefetch: (_) {
              final c = ref.read(enrichControllerProvider.notifier);
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(
                    content: Text('Re-fetching from MusicBrainz…')));
              c.enrichAlbum(album.releaseMbid);
            },
            onReadTags: (_) => runCatalogMutation(
              context,
              ref,
              action: () =>
                  ref.read(rereadAlbumTagsFnProvider)(album.releaseMbid),
              clearSelection: () =>
                  ref.read(selectedAlbumProvider.notifier).clear(),
              successMessage: 'Tags re-read',
              failureMessage: 'Failed to re-read tags',
            ),
            onSetReading: (_) async {
              final current = await ref
                  .read(releaseTitleOverrideFnProvider)(album.releaseMbid);
              if (!context.mounted) return;
              await showTitleOverrideDialog(
                context,
                label: album.title,
                current: current,
                onSubmit: (t, tr) =>
                    ref.read(setReleaseTitleOverrideFnProvider)(
                        album.releaseMbid, t, tr),
                onSaved: () {
                  ref.read(queueControllerProvider).refreshMetadata();
                  ref.invalidate(albumsProvider);
                  ref.invalidate(tracksProvider);
                },
              );
            },
            onRemove: (_) => runCatalogMutation(
              context,
              ref,
              action: () => ref.read(removeAlbumFnProvider)(album.releaseMbid),
              clearSelection: () =>
                  ref.read(selectedAlbumProvider.notifier).clear(),
              successMessage: 'Removed "${album.title}"',
              failureMessage: 'Failed to remove "${album.title}"',
            ),
            child: InkWell(
              key: ValueKey(album.releaseMbid),
              onTap: () {
                ref
                    .read(selectedAlbumProvider.notifier)
                    .select(album.releaseMbid);
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
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
