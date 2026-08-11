import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/catalog_mutation.dart';
import 'package:olivier/playlists/add_to_playlist_dialog.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/list_selection.dart';
import 'package:olivier/state/capabilities.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/album_cover.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/browse_drag_source.dart';
import 'package:olivier/widgets/context_menu.dart';
import 'package:olivier/widgets/info_dialog.dart';
import 'package:olivier/widgets/title_override_dialog.dart';

/// Append every selected album's tracks, in list order. The selection always
/// contains the row the menu was opened on (see [RowSelection.ensureContains]),
/// so this covers the single-row case too.
Future<void> enqueueSelectedAlbums(WidgetRef ref, List<String> selected) async {
  final paths = await resolveEntitiesPaths(
    [for (final mbid in selected) QueueEntityRef.album(mbid)],
    ref.read(entityPathFnsProvider),
  );
  if (paths.isEmpty) return;
  await ref.read(queueControllerProvider).append(paths);
}

class AlbumColumn extends ConsumerWidget {
  const AlbumColumn({super.key, this.narrow = false});

  /// One-level-at-a-time layout: no queue panel on screen, so rows drop
  /// drag-to-queue and use long press for their context menu instead.
  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsProvider);
    return albumsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (albums) => _AlbumList(narrow: narrow, albums: albums),
    );
  }
}

class _AlbumList extends ConsumerStatefulWidget {
  const _AlbumList({required this.albums, required this.narrow});
  final bool narrow;

  final List<Album> albums;

  @override
  ConsumerState<_AlbumList> createState() => _AlbumListState();
}

class _AlbumListState extends ConsumerState<_AlbumList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSelected(String? selected) {
    if (selected == null) return;
    final index = widget.albums.indexWhere((a) => a.releaseMbid == selected);
    if (index < 0) return;
    final extent = bilingualRowExtent(context, 48);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final rowTop = index * extent;
      // Already fully visible: leave it. Only an off-screen row (e.g. a search
      // hit) scrolls in — ordinary in-view clicks must not yank the list.
      if (rowTop >= pos.pixels &&
          rowTop + extent <= pos.pixels + pos.viewportDimension) {
        return;
      }
      _scroll.jumpTo(rowTop.clamp(0.0, pos.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedAlbumProvider);
    final leads = ref.watch(languageLeadsProvider);
    // A synced-catalog device must not edit what the desktop owns.
    final canModify = ref.watch(canModifyCatalogProvider);
    final selection = SelectionBinding(
      ref: ref,
      provider: albumSelectionProvider,
      rowKeys: [for (final a in widget.albums) a.releaseMbid],
      selection: ref.watch(albumSelectionProvider),
      singular: 'album',
    );
    if (widget.albums.isEmpty) {
      return const Center(child: Text('Select an artist'));
    }
    ref.listen<String?>(
        selectedAlbumProvider, (_, next) => _scrollToSelected(next));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToSelected(selected));
    return ListView.builder(
      controller: _scroll,
      itemCount: widget.albums.length,
      itemExtent: bilingualRowExtent(context, 48),
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      itemBuilder: (context, index) {
        final album = widget.albums[index];
        // Highlighted either as the drilled-into album or as part of a
        // multi-row selection.
        final isSelected = selected == album.releaseMbid ||
            selection.contains(album.releaseMbid);
        final year = album.originalYear ?? album.reissueYear ?? '';
        final entity = QueueEntityRef.album(album.releaseMbid);
        return BrowseDragSource(
          enabled: !widget.narrow,
          entity: entity,
          label: album.title,
          child: RowContextMenu(
            longPressToOpen: widget.narrow,
            entity: entity,
            onOpenSelection: () => selection.openMenu(album.releaseMbid),
            onAddToQueue: (_) =>
                enqueueSelectedAlbums(ref, selection.selectedKeys),
            onAddToPlaylist: (entity) =>
                showAddToPlaylistDialog(context, ref, entity),
            onInfo: (_) => showInfoDialog(context,
                title: 'Album',
                fields: albumInfoFields(album),
                header: AlbumCover(releaseMbid: album.releaseMbid, size: 220)),
            onRefetch: !canModify
                ? null
                : (_) {
                    final c = ref.read(enrichControllerProvider.notifier);
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(const SnackBar(
                          content: Text('Re-fetching from MusicBrainz…')));
                    c.enrichAlbum(album.releaseMbid);
                  },
            onReadTags: !canModify
                ? null
                : (_) => runCatalogMutation(
                      context,
                      ref,
                      action: () => ref
                          .read(rereadAlbumTagsFnProvider)(album.releaseMbid),
                      clearSelection: () =>
                          ref.read(selectedAlbumProvider.notifier).clear(),
                      successMessage: 'Tags re-read',
                      failureMessage: 'Failed to re-read tags',
                    ),
            onSetReading: !canModify
                ? null
                : (_) async {
                    final current = await ref.read(
                        releaseTitleOverrideFnProvider)(album.releaseMbid);
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
            onRemove: !canModify
                ? null
                : (_) {
                    final mbids = selection.selectedKeys;
                    final what = mbids.length == 1
                        ? '"${album.title}"'
                        : '${mbids.length} albums';
                    runCatalogMutation(
                      context,
                      ref,
                      action: () async {
                        final remove = ref.read(removeAlbumFnProvider);
                        for (final mbid in mbids) {
                          await remove(mbid);
                        }
                      },
                      clearSelection: () {
                        ref.read(selectedAlbumProvider.notifier).clear();
                        selection.clear();
                      },
                      successMessage: 'Removed $what',
                      failureMessage: 'Failed to remove $what',
                      reconcileQueue: true,
                    );
                  },
            child: InkWell(
              key: ValueKey(album.releaseMbid),
              onTap: () {
                // A modified click only edits the selection; a plain one still
                // drills into the album as it always has.
                if (!selection.tap(album.releaseMbid)) return;
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
