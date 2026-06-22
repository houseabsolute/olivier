import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/search.dart';
import 'package:olivier/widgets/bilingual_text.dart';

/// The dropdown overlay of grouped search results. Renders nothing when the
/// query is blank. Drops from the top-center, under the app-bar field.
class SearchResultsPanel extends ConsumerWidget {
  const SearchResultsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(searchQueryProvider).trim();
    if (query.isEmpty) return const SizedBox.shrink();
    final resultsAsync = ref.watch(searchResultsProvider);
    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(searchQueryProvider.notifier).clear(),
            child: const SizedBox.expand(),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 6, left: 8, right: 8),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 520, maxHeight: 420),
                child: Material(
                  elevation: 8,
                  surfaceTintColor: Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: resultsAsync.when(
                    // Keep showing the prior results while the next debounced
                    // query loads, so the list doesn't flash a spinner on every
                    // keystroke.
                    skipLoadingOnReload: true,
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Search error: $e'),
                    ),
                    data: (r) => _ResultsList(results: r),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsList extends ConsumerWidget {
  const _ResultsList({required this.results});
  final SearchResults results;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hits = flattenHits(results);
    if (hits.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No matches'),
      );
    }
    final leads = ref.watch(languageLeadsProvider);
    final highlighted = ref.watch(highlightedSearchIndexProvider);
    final scheme = Theme.of(context).colorScheme;

    final children = <Widget>[];
    SearchHit? prev;
    for (var i = 0; i < hits.length; i++) {
      final hit = hits[i];
      if (prev == null || hit.runtimeType != prev.runtimeType) {
        children.add(_header(
            context,
            switch (hit) {
              ArtistHit() => 'Artists',
              AlbumHit() => 'Albums',
              TrackHit() => 'Tracks',
            }));
      }
      children.add(_row(context, ref, hit, leads, i == highlighted, scheme));
      final lastOfKind =
          i == hits.length - 1 || hits[i + 1].runtimeType != hit.runtimeType;
      if (lastOfKind && _groupFull(hit, results)) {
        children.add(_footer(context));
      }
      prev = hit;
    }
    return ListView(
        shrinkWrap: true, padding: EdgeInsets.zero, children: children);
  }

  bool _groupFull(SearchHit h, SearchResults r) => switch (h) {
        ArtistHit() => r.artists.length >= kSearchGroupLimit,
        AlbumHit() => r.albums.length >= kSearchGroupLimit,
        TrackHit() => r.tracks.length >= kSearchGroupLimit,
      };

  Widget _footer(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
        child: Text('Refine search to narrow results',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                )),
      );

  Widget _header(BuildContext context, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Text(label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                )),
      );

  Widget _row(BuildContext context, WidgetRef ref, SearchHit hit,
      LanguageLeads leads, bool highlighted, ColorScheme scheme) {
    final (original, translit, translate, subtitle, icon) = switch (hit) {
      ArtistHit(:final artist) => (
          artist.nameOriginal ?? artist.name,
          artist.transliteration,
          null,
          null,
          Icons.person_outline,
        ),
      AlbumHit(:final album) => (
          album.title,
          album.titleTranslit,
          album.titleTranslate,
          album.albumArtist,
          Icons.album_outlined,
        ),
      TrackHit(:final track) => (
          track.title,
          track.titleTranslit,
          track.titleTranslate,
          track.albumArtist,
          Icons.music_note_outlined,
        ),
    };
    return InkWell(
      onTap: () => selectHit(ref, hit),
      child: Container(
        color: highlighted ? scheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: BilingualText(
                original: original,
                translit: translit,
                translate: translate,
                leads: leads,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
