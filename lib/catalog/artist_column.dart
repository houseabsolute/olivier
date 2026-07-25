import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/playlists/add_to_playlist_dialog.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/artist_reading_dialog.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/browse_drag_source.dart';
import 'package:olivier/widgets/context_menu.dart';

Future<void> _enqueue(WidgetRef ref, QueueEntityRef entity) async {
  final paths = await resolveEntityPaths(
    entity,
    ref.read(entityPathFnsProvider),
  );
  if (paths.isEmpty) return;
  await ref.read(queueControllerProvider).append(paths);
}

class ArtistColumn extends ConsumerWidget {
  const ArtistColumn({super.key, this.narrow = false});

  /// One-level-at-a-time layout: no queue panel on screen, so rows drop
  /// drag-to-queue and use long press for their context menu instead.
  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistsAsync = ref.watch(artistsProvider);
    return artistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (artists) => _ArtistList(narrow: narrow, artists: artists),
    );
  }
}

class _ArtistList extends ConsumerStatefulWidget {
  const _ArtistList({required this.artists, required this.narrow});
  final bool narrow;

  final List<Artist> artists;

  @override
  ConsumerState<_ArtistList> createState() => _ArtistListState();
}

class _ArtistListState extends ConsumerState<_ArtistList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSelected(String? selected) {
    if (selected == null) return;
    final index = widget.artists.indexWhere((a) => a.mbid == selected);
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
    final selected = ref.watch(selectedArtistProvider);
    final leads = ref.watch(languageLeadsProvider);
    if (widget.artists.isEmpty) {
      return const Center(child: Text('No artists — scan a folder first'));
    }
    ref.listen<String?>(
        selectedArtistProvider, (_, next) => _scrollToSelected(next));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToSelected(selected));
    return ListView.builder(
      controller: _scroll,
      itemCount: widget.artists.length,
      itemExtent: bilingualRowExtent(context, 48),
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      itemBuilder: (context, index) {
        final artist = widget.artists[index];
        final isSelected = selected == artist.mbid;
        final entity = QueueEntityRef.artist(artist.mbid);
        return BrowseDragSource(
          enabled: !widget.narrow,
          entity: entity,
          label: artist.nameOriginal ?? artist.name,
          child: RowContextMenu(
            longPressToOpen: widget.narrow,
            entity: entity,
            onAddToQueue: (e) => _enqueue(ref, e),
            onAddToPlaylist: (entity) =>
                showAddToPlaylistDialog(context, ref, entity),
            onRefetch: (_) {
              final c = ref.read(enrichControllerProvider.notifier);
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(
                    content: Text('Re-fetching from MusicBrainz…')));
              c.enrichArtist(artist.mbid);
            },
            onSetReading: (_) =>
                showArtistReadingDialog(context, ref, artist.mbid),
            child: InkWell(
              key: ValueKey(artist.mbid),
              onTap: () =>
                  ref.read(selectedArtistProvider.notifier).select(artist.mbid),
              child: Container(
                color: isSelected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: BilingualText(
                  original: artist.nameOriginal ?? artist.name,
                  translit: artist.transliteration,
                  translate: null, // names get a reading only (spec §6)
                  leads: leads,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
